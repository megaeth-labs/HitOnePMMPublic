// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20 }    from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math }      from "@openzeppelin/contracts/utils/math/Math.sol";

import { H2Storage } from "./H2Storage.sol";
import { IH2Oracle } from "./IH2Oracle.sol";

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
        // Mint at the LP NAV with a virtual offset: shares = assets · (totalShares+1)/(nav+1). The
        // NAV nets open positions' unrealized PnL into the pool, so a depositor can't mint outsized
        // shares when the pool has unbooked gains (traders net-down). If the primary feed is stale
        // it is priced off the FRESH fallback at the LP-adverse HIGH edge (fewer shares); both stale
        // reverts `NoFreshPrice`. See `_lpNav`.
        (uint256 nav, ) = _lpNav(marketId, false);
        shares = Math.mulDiv(assets, v.totalShares + 1, nav + 1);
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
        // Redeem at the LP NAV: assets = burn · (nav+1)/(totalShares+1). nav < poolAssets when
        // traders are net-up, so an exiter can't extract the stale overstated value. When traders are
        // net-DOWN, nav > poolAssets: the share is worth more than the liquid cash (the gains are
        // still locked in unrealized trader losses), so a full redemption can exceed what's payable —
        // require it to fit the liquid pool and let the LP wait for those positions to settle. If the
        // primary feed is stale the NAV is priced off the FRESH fallback at the LP-adverse LOW edge
        // (redeems less); both stale reverts `NoFreshPrice`. See `_lpNav`.
        (uint256 nav, ) = _lpNav(marketId, true);
        assets = Math.mulDiv(burn, nav + 1, v.totalShares + 1);
        // Owed winnings are senior: an LP can only pull the pool beyond what's reserved for them.
        uint256 reservable = uint256(v.poolAssets) > _outstanding(marketId)
            ? uint256(v.poolAssets) - _outstanding(marketId) : 0;
        if (assets > reservable) revert InsufficientLiquidity();

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
    // owed winnings (a winning close the pool couldn't fully pay; senior to LPs, FIFO)
    // ============================================================

    /// @notice Claim the currently-funded part of an owed entry (`entryId` for `marketId`). Only the
    /// entry's owner. Pays `min(fundable-up-to-this-entry, amount) − alreadyClaimed` and can be called
    /// repeatedly as the pool refills. `owedHead += amount` and `poolAssets -= amount` together keep
    /// the funded frontier unchanged, so a claim never unfunds another entry (no race, strict FIFO).
    function claimWinnings(uint256 marketId, uint256 entryId)
        external override nonReentrant returns (uint256 amount)
    {
        OwedEntry storage e = _owedQueue[marketId][entryId];
        if (e.user != msg.sender) revert NotOwed();
        amount = _entryClaimable(marketId, entryId);
        if (amount == 0) revert ZeroAmount();
        e.claimed += uint128(amount);
        owedHead[marketId] += amount;
        _vault[marketId].poolAssets -= uint128(amount);
        emit WinningsClaimed(marketId, msg.sender, entryId, amount);
        usdm.safeTransfer(msg.sender, amount);
    }

    /// @dev Draw up to `need` of `user`'s CLAIMABLE owed (FIFO-funded) to fund fresh collateral,
    /// moving real cash out of `poolAssets` into the position (and marking the owed claimed). This is
    /// exactly claim-then-use netted: unfunded owed contributes nothing, so a position can never be
    /// opened on an unfunded IOU. Bounded to `MAX_OWED_DRAW` of the user's entries; the caller pulls
    /// the remainder from the wallet. Returns the amount drawn.
    function _drawOwedForCollateral(uint256 marketId, address user, uint256 need)
        internal returns (uint256 drawn)
    {
        uint256[] storage ids = _userOwed[marketId][user];
        uint256 n = ids.length;
        uint256 iter = n < MAX_OWED_DRAW ? n : MAX_OWED_DRAW; // oldest entries first (lowest start ⇒ funded first)
        for (uint256 i = 0; i < iter && drawn < need; i++) {
            uint256 id = ids[i];
            uint256 c = _entryClaimable(marketId, id);
            if (c == 0) continue;
            uint256 use = (need - drawn) < c ? (need - drawn) : c;
            _owedQueue[marketId][id].claimed += uint128(use);
            owedHead[marketId] += use;
            _vault[marketId].poolAssets -= uint128(use);
            drawn += use;
        }
    }

    // ============================================================
    // views
    // ============================================================

    function vaultOf(uint256 marketId) external view override returns (VaultView memory) {
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        Vault storage v = _vault[marketId];
        // A non-reverting view: report the primary-mark MTM (and share price off it) regardless of
        // staleness, plus the `stale` flag so a UI can surface that live deposit/withdraw would price
        // off the fallback adverse band (`_lpNav`). It does not read the fallback here (a view must
        // not revert on both-stale).
        IH2Oracle.FeedView memory feed = _oracle.feedOf(_oracles[marketId].primaryFeedId);
        uint256 mtm = _mtmValueAtMark(marketId, feed, feed.mark);
        return VaultView({
            totalShares:   v.totalShares,
            poolAssets:    v.poolAssets,
            mtmValue:      mtm,
            sharePrice:    Math.mulDiv(mtm + 1, WAD, v.totalShares + 1),
            rakeOwed:      v.rakeOwed,
            rakeRecipient: feed.operator,
            rakePpm:       v.rakePpm,
            outstanding:   _outstanding(marketId),
            stale:         _primaryStale(marketId, feed)
        });
    }

    /// @notice A market's total unpaid owed winnings (senior to LPs).
    function owedOf(uint256 marketId) external view override returns (uint256) {
        return _outstanding(marketId);
    }

    /// @notice An owed entry's state + how much is claimable right now.
    function owedEntry(uint256 marketId, uint256 entryId)
        external view override
        returns (address user, uint256 amount, uint256 claimed, uint256 claimable)
    {
        OwedEntry storage e = _owedQueue[marketId][entryId];
        return (e.user, uint256(e.amount), uint256(e.claimed), _entryClaimable(marketId, entryId));
    }

    /// @notice The ids of a user's owed entries on a market (for UIs / claiming).
    function owedEntriesOf(uint256 marketId, address user) external view override returns (uint256[] memory) {
        return _userOwed[marketId][user];
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

    /// @dev Remove `amount` of liquid cash from the pool for a winning settlement. Callers cap
    /// `amount` at `_drainable` (poolAssets minus the senior owed reservation), paying only what's
    /// liquid and enqueuing any shortfall as owed — so a winner is never stranded by a revert. The
    /// `Insolvent` guard is a defensive backstop that the capped callers never trip.
    function _drainPool(uint256 marketId, uint256 amount) internal {
        Vault storage v = _vault[marketId];
        if (uint256(v.poolAssets) < amount) revert Insolvent();
        unchecked { v.poolAssets -= uint128(amount); }
    }
}
