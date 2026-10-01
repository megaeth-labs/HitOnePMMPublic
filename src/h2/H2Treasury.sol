// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20 }    from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math }      from "@openzeppelin/contracts/utils/math/Math.sol";

import { H2Storage } from "./H2Storage.sol";

/// @title H2Treasury
/// @notice Per-market permissionless share vault (see TREASURY_DESIGN.md). Lenders deposit
/// USDM and receive shares; a share is worth `poolAssets / totalShares`. All trading P&L —
/// open/close fees, the winnings cut, trader losses, liquidation wipes, minus trader wins —
/// flows through `poolAssets`, so share price rises with the book's earnings and falls with
/// its losses. There is NO rate, NO cap, NO creator/treasurer role: nobody governs the
/// vault. The only compensation carve-out is the ORACLE RAKE — the feed operator takes a
/// frozen `rakePpm` cut of every pool gain (skimmed in `_credit`), claimable via `claimRake`.
///
/// Entry is immediate at NAV (a mid-block joiner mints against the up-to-the-instant price,
/// so it can never over-earn). Exit runs through a per-market cooldown (`unstakeSecs`):
/// `requestUnstake` starts the clock but the shares stay in the pool earning + bearing P&L,
/// and `withdraw` (after the clock) redeems at the CURRENT NAV — pure exit friction, no
/// timing dodge. A loss is simply a NAV markdown borne pro-rata by every share; there is no
/// haircut anywhere. A virtual-share offset (+1/+1) neutralizes the first-deposit inflation
/// attack on an empty vault.
abstract contract H2Treasury is H2Storage {
    using SafeERC20 for IERC20;

    // ============================================================
    // lender side
    // ============================================================

    /// @notice Lend `assets` into the market's vault, minting shares at the current NAV.
    function deposit(uint256 marketId, uint256 assets)
        external override nonReentrant returns (uint256 shares)
    {
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        if (assets == 0) revert ZeroAmount();
        if (assets > type(uint128).max) revert BadSize();
        // Deposits require a banded primary feed: an unbanded operator could fabricate marks
        // and drain the pool through one fake round trip or a retroactive walk-back wipe.
        if (_oracle.feedOf(_oracles[marketId].primaryFeedId).refFeed == address(0))
            revert UnbandedFeed();

        Vault storage v = _vault[marketId];
        // Mint at the MARKED-TO-MARKET NAV with a virtual offset:
        //   shares = assets · (totalShares+1)/(mtmValue+1).
        // mtmValue nets the open positions' unrealized PnL into the pool, so a depositor can't mint
        // outsized shares when the pool has unbooked gains (traders net-down). See `_mtmValue`.
        shares = Math.mulDiv(assets, v.totalShares + 1, _mtmValue(marketId) + 1);
        if (shares == 0) revert ZeroAmount();

        usdm.safeTransferFrom(msg.sender, address(this), assets);
        v.poolAssets    += uint128(assets);
        v.totalShares   += shares;
        _shares[marketId][msg.sender] += shares;

        emit Deposited(marketId, msg.sender, assets, shares);
    }

    /// @notice Start the withdrawal cooldown on `shares` (they keep earning through it).
    /// Re-requesting overwrites the prior request and resets the timer.
    function requestUnstake(uint256 marketId, uint256 shares) external override {
        if (shares == 0) revert ZeroAmount();
        if (_shares[marketId][msg.sender] < shares) revert InsufficientShares();
        uint64 unlockAt = uint64(block.timestamp) + _risk[marketId].unstakeSecs;
        _unstake[marketId][msg.sender] = Unstake({ shares: shares, unlockAt: unlockAt });
        emit UnstakeRequested(marketId, msg.sender, shares, unlockAt);
    }

    /// @notice Withdraw a matured unstake: burn the requested shares at the current NAV.
    function withdraw(uint256 marketId) external override nonReentrant returns (uint256 assets) {
        Unstake memory u = _unstake[marketId][msg.sender];
        if (u.shares == 0) revert NothingStaked();
        if (block.timestamp < u.unlockAt) revert CooldownActive();

        Vault storage v = _vault[marketId];
        uint256 held = _shares[marketId][msg.sender];
        // The request may exceed the balance if the holder can burn shares elsewhere — clamp.
        uint256 burn = u.shares > held ? held : u.shares;
        // Redeem at the MARKED-TO-MARKET NAV: assets = burn · (mtmValue+1)/(totalShares+1).
        // mtm < poolAssets when traders are net-up, so an exiter can't extract the stale overstated
        // value. When traders are net-DOWN, mtm > poolAssets: the share is worth more than the
        // liquid cash (the gains are still locked in unrealized trader losses, not yet in
        // poolAssets), so a full redemption can exceed what's payable — require it to fit the liquid
        // pool and let the LP wait for those positions to settle.
        assets = Math.mulDiv(burn, _mtmValue(marketId) + 1, v.totalShares + 1);
        if (assets > uint256(v.poolAssets)) revert InsufficientLiquidity();

        _shares[marketId][msg.sender] = held - burn;
        v.totalShares -= burn;
        v.poolAssets  -= uint128(assets);
        delete _unstake[marketId][msg.sender];

        emit Withdrawn(marketId, msg.sender, burn, assets);
        if (assets > 0) usdm.safeTransfer(msg.sender, assets);
    }

    /// @notice Claim the market's accrued rake to `to`. Only the primary feed's operator.
    function claimRake(uint256 marketId, address to) external override nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        if (msg.sender != _oracle.feedOf(_oracles[marketId].primaryFeedId).operator)
            revert NotFeedOperator();
        Vault storage v = _vault[marketId];
        uint256 amount = v.rakeOwed;
        if (amount == 0) revert ZeroAmount();
        v.rakeOwed = 0;
        emit RakeClaimed(marketId, to, amount);
        usdm.safeTransfer(to, amount);
    }

    // ============================================================
    // builder codes (eligibility gated by the per-market registry; see H2Markets._builderEligible)
    // ============================================================

    /// @notice Claim the caller's accrued builder fees (USDM) to `to`. Fees accrue in the market
    /// as orders are filled; the external registry only gated who was eligible to accrue them.
    function claimBuilderFees(address to) external override nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = builderOwed[msg.sender];
        if (amount == 0) revert ZeroAmount();
        builderOwed[msg.sender] = 0;
        emit BuilderFeesClaimed(msg.sender, to, amount);
        usdm.safeTransfer(to, amount);
    }

    // ============================================================
    // views
    // ============================================================

    function vaultOf(uint256 marketId) external view override returns (VaultView memory) {
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        Vault storage v = _vault[marketId];
        uint256 mtm = _mtmValue(marketId);
        return VaultView({
            totalShares:   v.totalShares,
            poolAssets:    v.poolAssets,
            mtmValue:      mtm,
            sharePrice:    Math.mulDiv(mtm + 1, WAD, v.totalShares + 1),
            rakeOwed:      v.rakeOwed,
            rakeRecipient: _oracle.feedOf(_oracles[marketId].primaryFeedId).operator,
            rakePpm:       v.rakePpm
        });
    }

    function stakeOf(uint256 marketId, address user) external view override returns (StakeView memory) {
        Unstake memory u = _unstake[marketId][user];
        return StakeView({
            shares:        _shares[marketId][user],
            unstakeShares: u.shares,
            unlockAt:      u.unlockAt
        });
    }

    function grossOpenNotional(uint256 marketId) external view override returns (uint256) {
        return openInterestLong[marketId] + openInterestShort[marketId];
    }

    // ============================================================
    // settlement hooks (position paths only)
    // ============================================================

    /// @dev Trading earnings enter the pool: open/close fees, trader losses, liquidation
    /// wipes, the winnings cut. The feed operator's rake is skimmed off the top (gross — the
    /// operator shares no losses); the remainder lifts share price for lenders.
    function _credit(uint256 marketId, uint256 amount) internal {
        Vault storage v = _vault[marketId];
        uint256 rake = amount * v.rakePpm / PPM;
        v.rakeOwed   += uint128(rake);
        v.poolAssets += uint128(amount - rake);
    }

    /// @dev `_credit` for an ORDER-DRIVEN fee/cut, splitting the builder's share out of the
    /// VAULT RESIDUAL: the oracle rake is skimmed FIRST (senior, untouched by the builder), then
    /// an ELIGIBLE builder takes `builderFeePpm` of what remains, and only the rest lifts share
    /// price. Eligibility is the per-market registry's call (`_builderEligible`); an ineligible/
    /// zero builder simply forfeits the share to the vault. Used for open fees, close fees, and
    /// the winnings cut (open crystallization + close/decrease).
    function _creditWithBuilder(
        uint256 marketId, uint256 amount, address builder, uint256 builderFeePpm,
        uint256 positionId, bool isOpenSide
    ) internal {
        Vault storage v = _vault[marketId];
        uint256 rake = amount * v.rakePpm / PPM;
        v.rakeOwed += uint128(rake);
        uint256 net = amount - rake;
        if (builderFeePpm != 0 && _builderEligible(marketId, builder)) {
            uint256 bCut = net * builderFeePpm / PPM;
            if (bCut > 0) {
                builderOwed[builder] += bCut;
                net -= bCut;
                emit BuilderFeeAccrued(marketId, builder, positionId, isOpenSide, bCut);
            }
        }
        v.poolAssets += uint128(net);
    }

    /// @dev A user win leaves the pool. Reverts `Insolvent` when the pool cannot cover it
    /// (opens are never solvency-gated). Losses are pure NAV markdown — no haircut.
    function _drainPool(uint256 marketId, uint256 amount) internal {
        Vault storage v = _vault[marketId];
        if (uint256(v.poolAssets) < amount) revert Insolvent();
        unchecked { v.poolAssets -= uint128(amount); }
    }
}
