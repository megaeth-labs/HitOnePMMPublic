// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20 }    from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { H2Markets }  from "./H2Markets.sol";
import { H2Orders }   from "./H2Orders.sol";
import { H2Treasury } from "./H2Treasury.sol";
import { IH2Oracle }  from "./IH2Oracle.sol";
import { ParamCatalog } from "../common/ParamCatalog.sol";
import { MarkRing }     from "../common/MarkRing.sol";
import { FundingIndex } from "../common/FundingIndex.sol";

/// @title H2Positions
/// @notice Position lifecycle, priced entirely by the market's oracles.
///
/// The PRIMARY entry point is `onMark` — the oracle's pull callback, carrying one action
/// per call (the oracle isolates calls, so one failing order never unwinds the mark or its
/// siblings). Orders fill at the just-committed mark ± the feed's capped spread; the fee
/// curves are charged explicitly and folded, with the spread, into the user's signed band.
/// Liquidation batches walk the feed's ring against the widened threshold. The fallback
/// module provides the same operations against the fallback feed once the primary is
/// stale.
///
/// All money settles against the market's lending pool (see H2Treasury): fees, losses and
/// wipes enter via `_credit`, user wins drain via `_drainPool`. User collateral itself is
/// wallet-to-wallet.
abstract contract H2Positions is H2Markets, H2Orders, H2Treasury {
    using SafeERC20 for IERC20;

    // ============================================================
    // primary path — the oracle's pull callback
    // ============================================================

    function onMark(uint256 feedId, bytes calldata data) external override nonReentrant {
        if (msg.sender != address(_oracle)) revert NotOracle();
        (uint256 marketId, uint8 kind, bytes memory payload) =
            abi.decode(data, (uint256, uint8, bytes));
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        if (_oracles[marketId].primaryFeedId != feedId) revert FeedMismatch();

        // The feed was published in THIS transaction, immediately before this callback —
        // the freshest price that can exist. Convergence still applies: a fresh fallback
        // that disagrees blocks the action rather than letting either price win. The mark
        // is authoritative here, so a stale fallback is simply skipped (requireFallback=false).
        IH2Oracle.FeedView memory feed = _feed(marketId);
        _assertConvergence(marketId, feed.mark, false);

        if (kind == uint8(ActionKind.Order_)) {
            (Order memory order, bytes memory sig) = abi.decode(payload, (Order, bytes));
            if (order.marketId != marketId) revert FeedMismatch();
            _verifyAndConsumeOrder(order, sig);
            // The spread is DERIVED from the feed's vol/skew by the market's frozen coefficients
            // (per side/action), capped by the market's bound.
            uint256 spreadPpm = _derivedSpread(marketId, feed, order.isOpen, order.isLong);
            _routeOrder(order, _adverseFill(order, feed.mark, spreadPpm, _risk[marketId].priceTick), feed);
        } else {
            uint256[] memory ids = abi.decode(payload, (uint256[]));
            _liquidateBatch(marketId, feed, ids);
        }
    }

    /// @dev Fill = base ± spread, direction and tick-rounding both against the taker:
    /// a long pays up on open and receives down on close (`up = isLong == isOpen`).
    function _adverseFill(Order memory order, uint256 base1e18, uint256 spreadPpm, uint256 tick)
        internal pure returns (uint256)
    {
        uint256 spread = base1e18 * spreadPpm / PPM;
        bool up = (order.isLong == order.isOpen);
        return up ? _ceilToTick(base1e18 + spread, tick) : _floorToTick(base1e18 - spread, tick);
    }

    function _ceilToTick(uint256 x, uint256 tick) internal pure returns (uint256) {
        return ((x + tick - 1) / tick) * tick;
    }
    /// @dev Clamped to one tick rather than zero: a zero would revert `BadMark` exactly
    /// when exits matter. Protective versus reverting, not versus the true price; bounded
    /// by the user's signed band on fills.
    function _floorToTick(uint256 x, uint256 tick) internal pure returns (uint256) {
        uint256 f = (x / tick) * tick;
        return f == 0 ? tick : f;
    }

    /// @dev Open / increase / close from `isOpen` and the user's active position.
    function _routeOrder(Order memory order, uint256 fill1e18, IH2Oracle.FeedView memory feed)
        internal returns (uint256 id)
    {
        if (order.isOpen) {
            id = activePositionId[order.user][order.marketId] == 0
                ? _openPosition(order, fill1e18, feed)
                : _increasePosition(order, fill1e18, feed);
        } else {
            id = activePositionId[order.user][order.marketId];
            _closePosition(order, fill1e18, feed);
        }
    }

    // ============================================================
    // open / increase
    // ============================================================

    function _openPosition(Order memory order, uint256 fill1e18, IH2Oracle.FeedView memory feed)
        internal returns (uint256 id)
    {
        uint256 marketId = order.marketId;
        RiskParams storage r = _risk[marketId];
        FeeParams  storage f = _fees[marketId];
        if (order.size == 0 || order.leverage == 0) revert BadSize();
        if (activePositionId[order.user][marketId] != 0) revert PositionExists();

        uint128 fillUnits = _toPriceUnits(fill1e18, r.priceTick);
        uint128 sizeUnits = _toSizeUnits(order.size, r.sizeTick);
        uint256 notional  = _notional(fillUnits, sizeUnits, r.notionalScale);

        uint256 feePpm = ParamCatalog.sizeFeePpm(notional, _usdmDenom, f.openFlatPpm, f.openLinearScale, f.openQuadScale);
        _checkBandWithFee(fill1e18, order.targetPrice, order.maxSlippageBps, order.isLong, true, feePpm);

        uint256 collateral_ = notional / order.leverage;
        if (collateral_ == 0) revert BadSize();
        if (order.leverage < r.minLeverage || order.leverage > r.maxLeverage) revert BadLeverage();
        if (notional > r.maxPositionNotional) revert PositionNotionalCap();

        uint256 newLong  = openInterestLong[marketId];
        uint256 newShort = openInterestShort[marketId];
        if (order.isLong) newLong  += notional;
        else              newShort += notional;
        _checkOICaps(r, newLong, newShort);

        uint256 fee = (notional * feePpm) / PPM;
        uint256 collAfterFee = collateral_;
        if (fee > 0) {
            if (collAfterFee <= fee) revert Insolvent();
            unchecked { collAfterFee -= fee; }
        }

        id = ++nextPositionId;
        if (order.leverage > type(uint16).max) revert BadLeverage();
        if (collAfterFee > type(uint128).max) revert BadSize();
        if (notional > type(uint128).max) revert BadSize();

        // Fund collateral from the user's funded owed winnings first (claim-then-use, netted), then
        // pull only the remainder from the wallet — a position never opens on an unfunded IOU.
        uint256 drawn = _drawOwedForCollateral(marketId, order.user, collateral_);
        if (collateral_ > drawn) usdm.safeTransferFrom(order.user, address(this), collateral_ - drawn);
        // Open fee to the vault (post oracle-rake and any builder share); credited under the
        // now-known `id` so a builder accrual can name the position.
        if (fee > 0) _creditWithBuilder(marketId, fee, order.builder, order.builderFeePpm, id, true);

        // Flush the OI + active-position writes BEFORE the big struct literal so `newLong`/
        // `newShort` die first — keeps the stack in bounds under via-IR.
        openInterestLong[marketId]  = newLong;
        openInterestShort[marketId] = newShort;
        activePositionId[order.user][marketId] = id;

        int128 fundingNow = _indexNow(feed, order.isLong);
        _positions[id] = Position({
            user:              order.user,
            openTime:          uint64(block.timestamp),
            leverage:          uint16(order.leverage),
            isLong:            order.isLong,
            closed:            false,
            marketId:          uint64(marketId),
            closeTime:         0,
            openMs:            uint64(_microTimestamp() / 1000),
            // Fixed forever at first open: increases reset openTime (the walk-back floor)
            // but never extend expiry.
            expiresAt:         uint64(block.timestamp) + uint64(r.maxPositionDuration),
            entryPrice:        fillUnits,
            size:              sizeUnits,
            closePrice:        0,
            col:               uint128(collAfterFee),
            fundingCheckpoint: fundingNow,
            realizedPnl:       0,
            notionalAtOpen:    uint128(notional),
            makerCutPaid:      0,
            lastActionBlock:   uint64(block.number)
        });
        // MTM aggregates: this side gains a slice (size, entry·size, checkpoint·size).
        _openAggAdd(marketId, order.isLong, sizeUnits, fillUnits, fundingNow);

        emit PositionOpened(
            id, order.user, marketId, order.isLong, order.size,
            fill1e18, collAfterFee, uint64(block.timestamp), fundingNow
        );
    }

    function _increasePosition(Order memory order, uint256 fill1e18, IH2Oracle.FeedView memory feed)
        internal returns (uint256 id)
    {
        uint256 marketId = order.marketId;
        RiskParams storage r = _risk[marketId];
        FeeParams  storage f = _fees[marketId];
        if (order.size == 0 || order.leverage == 0) revert BadSize();

        id = activePositionId[order.user][marketId];
        if (id == 0) revert NoPosition();
        Position storage pos = _positions[id];
        // Adjustment delay: the size-fee curve is convex, so splitting an increase into chunks
        // within a short window would dodge its super-linear terms. `minAdjustGapBlocks` (frozen,
        // ≥ 1) sets the gap; together with the open fee on any added size it bounds the residual
        // basis-dilution of the winnings cut — a dilution pad must add real leveraged size, pay its
        // open fee, and sit out the gap before it can close.
        if (block.number < uint256(pos.lastActionBlock) + r.minAdjustGapBlocks) revert AdjustmentTooSoon();
        // No increase on an expired position: it would push the walk-back floor (openTime/openMs)
        // forward on a position that should only be settling.
        if (block.timestamp >= pos.expiresAt) revert IncreaseAfterExpiry();
        if (order.isLong   != pos.isLong)   revert BadUserSig();
        if (order.leverage != pos.leverage) revert BadUserSig();
        // An increase resets openTime/openMs — the walk-back floor — so it must not be
        // available to a position with a liquidation already recorded in the ring.
        {
            (bool liqFound,,) = _ringWalkForLiq(marketId, id, feed);
            if (liqFound) revert PositionLiquidatable();
        }

        uint128 fillUnits    = _toPriceUnits(fill1e18, r.priceTick);
        uint128 addSizeUnits = _toSizeUnits(order.size, r.sizeTick);
        uint256 addNotional  = _notional(fillUnits, addSizeUnits, r.notionalScale);
        uint256 addCollateral = addNotional / order.leverage;
        if (addCollateral == 0) revert BadSize();

        uint256 feePpm = ParamCatalog.sizeFeePpm(addNotional, _usdmDenom, f.openFlatPpm, f.openLinearScale, f.openQuadScale);
        _checkBandWithFee(fill1e18, order.targetPrice, order.maxSlippageBps, order.isLong, true, feePpm);

        uint256 totalNotional = uint256(pos.notionalAtOpen) + addNotional;
        if (totalNotional > r.maxPositionNotional) revert PositionNotionalCap();

        uint256 newLong  = openInterestLong[marketId];
        uint256 newShort = openInterestShort[marketId];
        if (order.isLong) newLong += addNotional; else newShort += addNotional;
        _checkOICaps(r, newLong, newShort);

        uint256 fee = (addNotional * feePpm) / PPM;
        uint256 addColAfterFee = addCollateral;
        if (fee > 0) {
            if (addColAfterFee <= fee) revert Insolvent();
            unchecked { addColAfterFee -= fee; }
        }

        // Draw funded owed winnings before the wallet pull (see `_openPosition`).
        uint256 drawn = _drawOwedForCollateral(marketId, order.user, addCollateral);
        if (addCollateral > drawn) usdm.safeTransferFrom(order.user, address(this), addCollateral - drawn);
        if (fee > 0) _creditWithBuilder(marketId, fee, order.builder, order.builderFeePpm, id, true);

        int128 fundingNow = _indexNow(feed, order.isLong);

        uint256 oldSize  = uint256(pos.size);
        uint256 oldEntry = uint256(pos.entryPrice);          // captured for the MTM aggregate delta
        int256  oldCheck = int256(pos.fundingCheckpoint);    // (before the blend overwrites them)
        uint256 newSize = oldSize + uint256(addSizeUnits);
        if (newSize >= UNITS_CAP)              revert BadSize();
        if (totalNotional > type(uint128).max) revert BadSize();

        // Size-weighted blend for EVERY increase (gain, loss or flat): the added size enters at the
        // fill and current funding, while the old size keeps its unrealized PnL and accrued funding
        // exactly. The winnings cut is charged ONLY at close/decrease, on realized effPnl — an
        // increase never crystallizes a cut, so it cannot be diluted or dust-chunked into evasion,
        // and it never drains the pool (opens stay solvency-ungated).
        uint256 newCol   = uint256(pos.col) + addColAfterFee;
        // Round the blended entry AGAINST the taker (ceil for a long — a higher entry is worse for a
        // long; floor for a short). Integer division must never favor the taker here, or an
        // underwater position could walk its entry one priceUnit toward the mark per increase and
        // erase its unrealized loss straight out of the pool.
        uint256 num      = uint256(pos.entryPrice) * oldSize + uint256(fillUnits) * uint256(addSizeUnits);
        uint256 newEntry = pos.isLong ? (num + newSize - 1) / newSize : num / newSize;
        int256  newCheckpoint =
            (int256(pos.fundingCheckpoint) * int256(oldSize) + int256(fundingNow) * int256(uint256(addSizeUnits)))
            / int256(newSize);
        if (newCol > type(uint128).max) revert BadSize();

        pos.entryPrice        = uint128(newEntry);
        pos.size              = uint128(newSize);
        pos.col               = uint128(newCol);
        pos.fundingCheckpoint = int128(newCheckpoint);
        // OI-consistent sum (open + this add); NOT rebased, so `_decreaseOI` on close unwinds
        // exactly what open/increase added.
        pos.notionalAtOpen    = uint128(totalNotional);
        // The blended entry only becomes valid now; the walk-back floor moves with it.
        pos.openTime          = uint64(block.timestamp);
        pos.openMs            = uint64(_microTimestamp() / 1000);
        pos.lastActionBlock   = uint64(block.number);

        // MTM aggregates: swap the OLD stored state for the NEW blended state (both against the
        // rounded values actually stored), so the aggregate delta is exactly add − old.
        _openAggSub(marketId, order.isLong, oldSize, oldEntry, oldCheck);
        _openAggAdd(marketId, order.isLong, newSize, newEntry, newCheckpoint);

        openInterestLong[marketId]  = newLong;
        openInterestShort[marketId] = newShort;

        emit PositionIncreased(
            id, marketId, order.size, fill1e18,
            _sizeOut(uint128(newSize), r.sizeTick),
            _priceOut(uint128(newEntry), r.priceTick),
            addColAfterFee, fee, int128(newCheckpoint)
        );
    }

    // ============================================================
    // close / expire
    // ============================================================

    function _closePosition(Order memory order, uint256 fill1e18, IH2Oracle.FeedView memory feed) internal {
        uint256 marketId = order.marketId;
        RiskParams storage r = _risk[marketId];

        uint256 id = activePositionId[order.user][marketId];
        if (id == 0) revert NoPosition();
        Position storage pos = _positions[id];
        // Adjustment delay (see _increasePosition): a partial close is an adjustment too, so
        // chunking a close within the gap cannot dodge the convex close-fee curve.
        if (block.number < uint256(pos.lastActionBlock) + r.minAdjustGapBlocks) revert AdjustmentTooSoon();
        // The signed side must match: the adverse-fill direction derives from it.
        if (order.isLong != pos.isLong) revert BadUserSig();
        uint128 closeSizeUnits = _toSizeUnits(order.size, r.sizeTick);
        if (closeSizeUnits > pos.size) revert BadUserSig();

        // Close-fee fold: the all-in exit price must sit inside the signed band.
        {
            FeeParams storage f = _fees[marketId];
            uint256 closeNotional = _notional(_toPriceUnits(fill1e18, r.priceTick), closeSizeUnits, r.notionalScale);
            uint256 feePpm = ParamCatalog.sizeFeePpm(closeNotional, _usdmDenom, f.closeFlatPpm, f.closeLinearScale, f.closeQuadScale);
            _checkBandWithFee(fill1e18, order.targetPrice, order.maxSlippageBps, order.isLong, false, feePpm);
        }

        (bool liqFound, uint128 markAtLiqUnits, uint16 ringStep) = _ringWalkForLiq(marketId, id, feed);
        if (liqFound) {
            _wipePosition(id, markAtLiqUnits, ringStep);
            return;
        }

        uint128 fillUnits = _toPriceUnits(fill1e18, r.priceTick);
        // A close/decrease pays its own order's builder — so a user can close via a different
        // builder than they opened with (never locked in).
        BuilderRef memory b = BuilderRef({ builder: order.builder, feePpm: order.builderFeePpm });
        if (closeSizeUnits == pos.size) {
            _settleClose(id, fillUnits, feed, true, b);
        } else {
            _settleDecrease(id, closeSizeUnits, fillUnits, feed, b);
        }
    }

    function expirePosition(uint256 id) external override nonReentrant {
        Position storage pos = _positions[id];
        if (pos.user == address(0)) revert PositionDoesNotExist();
        if (pos.closed) revert PositionAlreadyClosed();
        if (block.timestamp < pos.expiresAt) revert PositionDurationNotElapsed();
        uint256 marketId = pos.marketId;
        IH2Oracle.FeedView memory feed = _feed(marketId);
        // Never settle at an uninitialized mark; and under dual oracle failure this stale
        // mark IS the documented exit.
        if (feed.lastPushMs == 0) revert PrimaryNeverPushed();
        uint128 markUnits = uint128(feed.mark / _risk[marketId].priceTick);
        // Expiry is a forced event: no close fee, no order → no builder.
        uint256 payout_ = _settleClose(id, markUnits, feed, false, BuilderRef({ builder: address(0), feePpm: 0 }));
        emit PositionExpired(id, _priceOut(markUnits, _risk[marketId].priceTick), payout_);
    }

    function _settleClose(
        uint256 id, uint128 closeUnits, IH2Oracle.FeedView memory feed, bool chargeCloseFee, BuilderRef memory b
    )
        internal returns (uint256)
    {
        Position storage pos = _positions[id];
        uint256 marketId = pos.marketId;
        RiskParams storage r = _risk[marketId];

        int128 fundingNow = _indexNow(feed, pos.isLong);
        (int256 pnl, int256 fundingPaid, uint256 payoutPreFee, uint256 cut) =
            _settleSlice(pos, pos.size, uint256(pos.col), closeUnits, fundingNow, r, _fees[marketId]);

        uint256 closeFee = chargeCloseFee ? _closeFeeAmount(marketId, closeUnits, pos.size, payoutPreFee) : 0;
        // Settle against the pool: drains the win (partial-pay + enqueue owed when illiquid), books
        // the loss, routes the fees, and returns the payout to transfer now.
        uint256 payout = _applyTreasuryDelta(
            marketId, uint256(pos.col), pnl, fundingPaid, cut, closeFee, payoutPreFee, b, id, pos.user
        );
        _decreaseOI(marketId, pos.isLong, uint256(pos.notionalAtOpen));
        // MTM aggregates: the whole position leaves.
        _openAggSub(marketId, pos.isLong, pos.size, pos.entryPrice, pos.fundingCheckpoint);

        int256 effPnlNet = pnl - fundingPaid - int256(closeFee);
        pos.closed       = true;
        pos.closeTime    = uint64(block.timestamp);
        pos.closePrice   = closeUnits;
        pos.realizedPnl  = _toInt128Saturating(effPnlNet);
        pos.makerCutPaid = uint128(cut);
        activePositionId[pos.user][marketId] = 0;

        address user = pos.user;
        emit PositionClosed(id, marketId, _priceOut(closeUnits, r.priceTick), pnl, fundingPaid, cut, closeFee, payout);
        if (payout > 0) usdm.safeTransfer(user, payout);
        return payout;
    }

    function _settleDecrease(
        uint256 id, uint128 closeSizeUnits, uint128 closeUnits, IH2Oracle.FeedView memory feed, BuilderRef memory b
    )
        internal
    {
        Position storage pos = _positions[id];
        uint256 marketId = pos.marketId;
        RiskParams storage r = _risk[marketId];

        int128 fundingNow = _indexNow(feed, pos.isLong);
        uint256 colPortion = uint256(pos.col) * closeSizeUnits / pos.size;

        (int256 pnl, int256 fundingPaid, uint256 payoutPreFee, uint256 cut) =
            _settleSlice(pos, closeSizeUnits, colPortion, closeUnits, fundingNow, r, _fees[marketId]);

        uint256 closeFee = _closeFeeAmount(marketId, closeUnits, closeSizeUnits, payoutPreFee);
        uint256 payout = _applyTreasuryDelta(
            marketId, colPortion, pnl, fundingPaid, cut, closeFee, payoutPreFee, b, id, pos.user
        );

        uint256 notionalPortion = uint256(pos.notionalAtOpen) * closeSizeUnits / pos.size;
        _decreaseOI(marketId, pos.isLong, notionalPortion);

        // MTM aggregates: the closed portion leaves; the remainder keeps its entry/checkpoint.
        _openAggSub(marketId, pos.isLong, closeSizeUnits, pos.entryPrice, pos.fundingCheckpoint);

        pos.size           = pos.size - closeSizeUnits;
        pos.col            = uint128(uint256(pos.col) - colPortion);
        pos.notionalAtOpen = uint128(uint256(pos.notionalAtOpen) - notionalPortion);
        pos.lastActionBlock = uint64(block.number); // one adjustment per block

        address user = pos.user;
        emit PositionDecreased(
            id, marketId, _sizeOut(closeSizeUnits, r.sizeTick),
            _priceOut(closeUnits, r.priceTick), pnl, fundingPaid, cut, closeFee, payout,
            _sizeOut(pos.size, r.sizeTick)
        );
        if (payout > 0) usdm.safeTransfer(user, payout);
    }

    /// @dev The close-fee curve on the closed notional, bounded by the pre-fee payout (a fee can
    /// never exceed what is leaving). PURE amount — crediting is deferred to `_applyTreasuryDelta`
    /// so the partial-pay path can waive the share an illiquid pool never realizes.
    function _closeFeeAmount(uint256 marketId, uint128 closeUnits, uint128 closeSizeUnits, uint256 payoutPreFee)
        internal view returns (uint256 charged)
    {
        RiskParams storage r = _risk[marketId];
        FeeParams  storage f = _fees[marketId];
        uint256 closeNotional = _notional(closeUnits, closeSizeUnits, r.notionalScale);
        uint256 feePpm = ParamCatalog.sizeFeePpm(closeNotional, _usdmDenom, f.closeFlatPpm, f.closeLinearScale, f.closeQuadScale);
        uint256 fee = closeNotional * feePpm / PPM;
        charged = fee < payoutPreFee ? fee : payoutPreFee;
    }

    function _wipePosition(uint256 id, uint128 markAtLiqUnits, uint16 ringStep) internal {
        Position storage pos = _positions[id];
        uint256 marketId = pos.marketId;
        uint256 wiped = uint256(pos.col);
        _decreaseOI(marketId, pos.isLong, uint256(pos.notionalAtOpen));
        // MTM aggregates: the wiped position leaves.
        _openAggSub(marketId, pos.isLong, pos.size, pos.entryPrice, pos.fundingCheckpoint);
        _credit(marketId, wiped);
        pos.closed      = true;
        pos.closeTime   = uint64(block.timestamp);
        pos.closePrice  = markAtLiqUnits;
        pos.realizedPnl = _toInt128Saturating(-int256(wiped));
        activePositionId[pos.user][marketId] = 0;
        emit PositionLiquidated(id, _priceOut(markAtLiqUnits, _risk[marketId].priceTick), ringStep, wiped);
    }

    /// @dev Route a settlement's PnL through the lending pool and return the payout to transfer
    /// now. `payoutPreFee` is the slice's payout before the close fee (`_settleSlice`), so the net
    /// entitlement is `payoutPreFee − closeFee`.
    ///
    /// A LOSS credits the pool (capped at the slice collateral) and routes the close fee. A WIN
    /// drains the pool for the trader's gross win and routes the cut + close fee — but only to the
    /// extent the pool (RESERVING senior owed) can fund it:
    ///  - solvent (`avail ≥ win`): exact existing economics — drain the gross, route both fees;
    ///  - partial (`avail < win`, `win > fees`): pay what's liquid, charge only the fee the drain
    ///    realizes (the rest is WAIVED — no rake on cash the pool never funded), and enqueue the
    ///    shortfall as owed, senior to LPs and FIFO (see TREASURY_DESIGN.md);
    ///  - win fully eaten by fees (`win ≤ fees`): the pool GAINS from collateral, so there is never
    ///    a liquidity problem — book the gain, pay the net, no owed.
    function _applyTreasuryDelta(
        uint256 marketId, uint256 posCol, int256 pnl, int256 fundingPaid, uint256 cut,
        uint256 closeFee, uint256 payoutPreFee, BuilderRef memory b, uint256 positionId, address user
    )
        internal returns (uint256 payout)
    {
        int256 effPnl = pnl - fundingPaid;
        uint256 payoutNet = payoutPreFee - closeFee; // the trader's full net entitlement (≥ 0)
        if (effPnl > 0) {
            uint256 win   = uint256(effPnl);
            uint256 fees  = cut + closeFee;
            uint256 avail = _drainable(marketId);    // poolAssets − outstanding, floored at 0
            if (avail >= win) {
                _drainPool(marketId, win);
                // The cut + close fee are fees the builder shares in (isOpenSide = false: a close).
                if (cut > 0)      _creditWithBuilder(marketId, cut, b.builder, b.feePpm, positionId, false);
                if (closeFee > 0) _creditWithBuilder(marketId, closeFee, b.builder, b.feePpm, positionId, false);
                payout = payoutNet;
            } else if (win > fees) {
                _drainPool(marketId, avail);
                uint256 feesCharged = fees < avail ? fees : avail; // waive the part the drain can't back
                if (feesCharged > 0) _credit(marketId, feesCharged);
                payout = posCol + avail - feesCharged;             // ≥ posCol
                uint256 owed = payoutNet - payout;                 // > 0
                uint256 entryId = _enqueueOwed(marketId, user, owed);
                emit WinningsOwed(marketId, user, entryId, owed);
            } else {
                uint256 gain = fees - win;                         // = posCol − payoutNet; pool gains
                if (gain > 0) _credit(marketId, gain);
                payout = payoutNet;
            }
        } else {
            if (effPnl < 0) {
                uint256 loss = uint256(-effPnl);
                if (loss > posCol) loss = posCol;
                if (loss > 0) _credit(marketId, loss); // a loss is not a fee — no builder share
            }
            if (closeFee > 0) _creditWithBuilder(marketId, closeFee, b.builder, b.feePpm, positionId, false);
            payout = payoutNet;
        }
    }

    function _decreaseOI(uint256 marketId, bool isLong, uint256 notionalAtOpen) internal {
        if (isLong) {
            uint256 oi = openInterestLong[marketId];
            openInterestLong[marketId] = oi > notionalAtOpen ? oi - notionalAtOpen : 0;
        } else {
            uint256 oi = openInterestShort[marketId];
            openInterestShort[marketId] = oi > notionalAtOpen ? oi - notionalAtOpen : 0;
        }
    }

    function _checkOICaps(RiskParams storage r, uint256 newLong, uint256 newShort) internal view {
        uint256 gross = newLong + newShort;
        uint256 skew  = newLong > newShort ? newLong - newShort : newShort - newLong;
        if (gross > r.maxOIGross) revert OIGrossCap();
        if (skew  > r.maxOISkew)  revert OISkewCap();
    }

    function _toInt128Saturating(int256 x) internal pure returns (int128) {
        if (x > type(int128).max) return type(int128).max;
        if (x < type(int128).min) return type(int128).min;
        return int128(x);
    }

    /// @dev Settle PnL + funding for a `sizeUnits` slice carrying `col` collateral.
    function _settleSlice(
        Position storage pos,
        uint128 sizeUnits,
        uint256 col,
        uint128 fillUnits,
        int128 fundingNow,
        RiskParams storage r,
        FeeParams storage f
    ) internal view returns (int256 pnl, int256 fundingPaid, uint256 payout, uint256 cut)
    {
        int256 priceDiff = int256(uint256(fillUnits)) - int256(uint256(pos.entryPrice));
        if (!pos.isLong) priceDiff = -priceDiff;
        pnl = priceDiff * int256(uint256(sizeUnits)) * int256(uint256(r.notionalScale));

        // Own-side index (two-sided funding): positive delta means this side pays.
        int256 fundingDelta = int256(fundingNow) - int256(pos.fundingCheckpoint);
        fundingPaid = (fundingDelta * int256(uint256(sizeUnits) * r.sizeTick)) / int256(ParamCatalog.SCALE);

        int256 effPnl = pnl - fundingPaid;
        if (effPnl > 0) {
            cut = ParamCatalog.houseCut(uint256(effPnl), col, f.cutInterceptPpm, f.cutSlopePpm, f.maxCutPpm);
            payout = col + uint256(effPnl) - cut;
        } else {
            uint256 loss = uint256(-effPnl);
            payout = loss >= col ? 0 : col - loss;
        }
    }

    // ============================================================
    // liquidation
    // ============================================================

    function _liquidateBatch(uint256 marketId, IH2Oracle.FeedView memory feed, uint256[] memory ids) internal {
        uint256 wipedCount = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            Position storage pos = _positions[ids[i]];
            if (pos.user == address(0) || pos.closed || pos.marketId != marketId) continue;
            (bool liqFound, uint128 markAtLiqUnits, uint16 ringStep) = _ringWalkForLiq(marketId, ids[i], feed);
            if (!liqFound) continue;
            _wipePosition(ids[i], markAtLiqUnits, ringStep);
            wipedCount++;
        }
        if (wipedCount == 0) revert NoneLiquidated();
    }

    /// @dev Replay the feed's ring from now back to the position's open, testing the
    /// WIDENED liquidation threshold at each recorded mark. Skips entirely when the
    /// feed's last publication predates the position (fallback fills publish nothing) —
    /// compared on the HP clock, the same clock that governs staleness.
    function _ringWalkForLiq(uint256 marketId, uint256 id, IH2Oracle.FeedView memory feed)
        internal view returns (bool found, uint128 markAtLiqUnits, uint16 ringStep)
    {
        Position storage pos = _positions[id];
        if (pos.user == address(0) || pos.closed) return (false, 0, 0);
        if (feed.lastPushMs == 0) return (false, 0, 0);
        if (feed.lastPushMs < pos.openMs) return (false, 0, 0);
        RiskParams storage r = _risk[marketId];

        uint128 markAtK  = uint128(feed.mark / r.priceTick);
        bool    isLong   = pos.isLong;
        // Seed the index at the value COMMITTED at the last push (not `_indexNow`, which
        // extrapolates to `block.timestamp`): the current mark is as-of `lastPushMs`, so its
        // funding index must be too, or every step of the walk carries a constant
        // rate·mark·(now − lastPushMs) bias against the paying side.
        int128  indexAtK = isLong ? feed.fundingIndexLong : feed.fundingIndexShort;
        // The ring's ms clock — the SAME clock `openMs` was stamped on. The current mark is
        // post-open (guarded above), so the walk rewinds this exactly to exclude pre-open
        // marks; at production sub-second cadence a floored-seconds clock would not move and
        // would test history from before the position existed.
        uint64  msAtK    = feed.lastPushMs;
        // No rate history: the walk window is at most a few seconds (bounded by the most
        // recent sentinel), over which the rate is ~constant; rewind at the current side
        // rate. The real settlement is always exact.
        int64   rateSide = isLong ? feed.rateLong : feed.rateShort;
        uint256 feedId   = _oracles[marketId].primaryFeedId;

        if (_isLiquidatable(pos, markAtK, indexAtK, r)) return (true, markAtK, 0);

        uint256 head = feed.ringHead;
        uint256 available = head < MarkRing.RING_LEN ? head : MarkRing.RING_LEN;
        for (uint256 k = 1; k <= available; k++) {
            uint32 markE = _oracle.ringEntry(feedId, head - k);
            if (MarkRing.isSentinel(markE)) return (false, 0, 0);
            (int256 priceDelta, uint256 timeDeltaMs) = MarkRing.unpackEntry(markE);
            uint64 stepMs = uint64(timeDeltaMs * MarkRing.GAP_UNIT_MS);
            int256 prev = int256(uint256(markAtK)) - priceDelta;
            if (prev <= 0) return (false, 0, 0);
            // msAtK now names the timestamp of the mark we step back TO (the older `prev`).
            msAtK -= stepMs;
            // Step the index back over this segment at the OLDER mark (`prev`) — the mark actually
            // held during the interval, matching how `_push` integrated it forward.
            indexAtK = FundingIndex.stepBackPctMs(indexAtK, rateSide, uint256(prev) * r.priceTick, stepMs);
            markAtK = uint128(uint256(prev));
            // This mark predates the position; the ring is strictly older from here, so stop.
            if (msAtK < pos.openMs) return (false, 0, 0);
            if (_isLiquidatable(pos, markAtK, indexAtK, r)) return (true, markAtK, uint16(k));
        }
        return (false, 0, 0);
    }

    /// @dev The WIDENED threshold: liquidatable once equity (col + effPnl) is within the
    /// maintenance margin `liqWidthPpm × notional-at-mark` — an early trigger, so the full
    /// knockout lands before bankruptcy and the treasury keeps gap-risk margin. Width 0
    /// degenerates to the exact-bankruptcy test.
    function _isLiquidatable(
        Position storage pos,
        uint128 markUnits,
        int128 indexAtK,
        RiskParams storage r
    ) internal view returns (bool) {
        int256 fundingDelta = int256(indexAtK) - int256(pos.fundingCheckpoint);
        int256 fundingPaid = (fundingDelta * int256(uint256(pos.size) * r.sizeTick)) / int256(ParamCatalog.SCALE);
        int256 priceDiff = int256(uint256(markUnits)) - int256(uint256(pos.entryPrice));
        if (!pos.isLong) priceDiff = -priceDiff;
        int256 pnl = priceDiff * int256(uint256(pos.size)) * int256(uint256(r.notionalScale));
        int256 equity = int256(uint256(pos.col)) + pnl - fundingPaid;
        uint256 maint = _notional(markUnits, pos.size, r.notionalScale) * uint256(r.liqWidthPpm) / PPM;
        return equity <= int256(maint);
    }

    // ============================================================
    // views
    // ============================================================

    function positions(uint256 id) external view override returns (PositionView memory v) {
        Position storage pos = _positions[id];
        RiskParams storage r = _risk[pos.marketId];
        int256 effPnl_ = int256(pos.realizedPnl);
        uint256 payout_;
        if (pos.closed) {
            int256 net = int256(uint256(pos.col)) + effPnl_ - int256(uint256(pos.makerCutPaid));
            payout_ = net > 0 ? uint256(net) : 0;
        }
        v = PositionView({
            user:              pos.user,
            marketId:          pos.marketId,
            isLong:            pos.isLong,
            size:              _sizeOut(pos.size, r.sizeTick),
            leverage:          uint256(pos.leverage),
            entryPrice:        _priceOut(pos.entryPrice, r.priceTick),
            col:               uint256(pos.col),
            fundingCheckpoint: pos.fundingCheckpoint,
            openTime:          pos.openTime,
            expiresAt:         pos.expiresAt,
            notionalAtOpen:    uint256(pos.notionalAtOpen),
            closed:            pos.closed,
            closeTime:         pos.closeTime,
            closePrice:        _priceOut(pos.closePrice, r.priceTick),
            realizedPnl:       effPnl_,
            makerCutPaid:      uint256(pos.makerCutPaid),
            payoutReceived:    payout_
        });
    }
}
