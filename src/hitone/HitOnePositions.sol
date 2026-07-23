// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20 }            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { HitOneMarks }       from "./HitOneMarks.sol";
import { HitOneOrders }      from "./HitOneOrders.sol";
import { ParamCatalog }      from "../common/ParamCatalog.sol";
import { MarkRing }          from "../common/MarkRing.sol";
import { FundingIndex }      from "../common/FundingIndex.sol";

/// @title HitOnePositions
/// @notice Position lifecycle: open, increase, close, expire, settle and liquidate.
abstract contract HitOnePositions is HitOneMarks, HitOneOrders {
    using SafeERC20 for IERC20;

    // ---- Open ----

    function openPosition(Order calldata order, uint256 fillPrice, bytes calldata userSig)
        external override nonReentrant whenNotHalted whenNotPausedNew returns (uint256 id)
    {
        if (!order.isOpen) revert BadUserSig();
        _verifyAndConsumeOrder(order, userSig);
        _checkSlippageBand(fillPrice, order.targetPrice, order.maxSlippageBps);
        id = _openPosition(order, fillPrice);
    }

    function _openPosition(Order calldata order, uint256 fillPrice_1e18) internal returns (uint256 id) {
        ParamCatalog.Structural storage s = _params[order.token].structural;
        if (s.priceTick == 0) revert UnknownToken();
        ParamCatalog.Risk storage risk = _makerRisk[order.maker][order.token];
        if (order.size == 0 || order.leverage == 0) revert BadSize();
        if (activePositionId[order.user][order.maker][order.token] != 0) revert PositionExists();

        uint128 fillPriceUnits = _toPriceUnits(fillPrice_1e18, s.priceTick);
        uint128 sizeUnits      = _toSizeUnits(order.size, s.sizeTick);

        uint256 markNotional = _notional(fillPriceUnits, sizeUnits, s.notionalScale);
        uint256 collateral_  = markNotional / order.leverage;
        if (collateral_ == 0) revert BadSize();

        if (order.leverage < s.minLeverage || order.leverage > s.maxLeverage) revert BadLeverage();
        if (markNotional > risk.maxPositionNotional) revert PositionNotionalCap();

        uint256 newLong  = openInterestLong[order.maker][order.token];
        uint256 newShort = openInterestShort[order.maker][order.token];
        if (order.isLong) newLong  += markNotional;
        else              newShort += markNotional;
        {
            uint256 gross = newLong + newShort;
            uint256 skew  = newLong > newShort ? newLong - newShort : newShort - newLong;
            if (gross > risk.maxOIGross) revert OIGrossCap();
            if (skew  > risk.maxOISkew)  revert OISkewCap();
        }

        uint256 fee = (markNotional * risk.openFeeBps) / ParamCatalog.BPS_DENOM;
        uint256 collAfterFee = collateral_;
        if (fee > 0) {
            if (collAfterFee <= fee) revert Insolvent();
            unchecked { collAfterFee -= fee; }
        }

        usdm.safeTransferFrom(order.user, address(this), collateral_);
        if (fee > 0) collateral[order.maker][order.token] += fee;

        _pushMark(order.maker, order.token, fillPrice_1e18, _markState[order.maker][order.token].currentRatePct, false);

        int128 fundingNow = _indexNow(_markState[order.maker][order.token], s.priceTick);

        id = ++nextPositionId;
        if (order.leverage > type(uint16).max) revert BadLeverage();
        if (collAfterFee > type(uint128).max) revert BadSize();
        if (markNotional > type(uint128).max) revert BadSize();
        _positions[id] = Position({
            user:              order.user,
            openTime:          uint64(block.timestamp),
            leverage:          uint16(order.leverage),
            isLong:            order.isLong,
            closed:            false,
            token:             order.token,
            closeTime:         0,
            entryPrice:        fillPriceUnits,
            size:              sizeUnits,
            closePrice:        0,
            col:               uint128(collAfterFee),
            fundingCheckpoint: fundingNow,
            realizedPnl:       0,
            notionalAtOpen:    uint128(markNotional),
            makerCutPaid:      0,
            maker:             order.maker
        });
        activePositionId[order.user][order.maker][order.token] = id;
        openInterestLong[order.maker][order.token]  = newLong;
        openInterestShort[order.maker][order.token] = newShort;

        emit PositionOpened(
            id, order.user, order.token, order.maker, order.isLong, order.size,
            fillPrice_1e18, collAfterFee, uint64(block.timestamp), fundingNow
        );
    }

    // ---- Increase (size up) ----

    function increasePosition(Order calldata order, uint256 fillPrice, bytes calldata userSig)
        external override nonReentrant whenNotHalted whenNotPausedNew returns (uint256 id)
    {
        if (!order.isOpen) revert BadUserSig();
        _verifyAndConsumeOrder(order, userSig);
        _checkSlippageBand(fillPrice, order.targetPrice, order.maxSlippageBps);
        id = _increasePosition(order, fillPrice);
    }

    function _increasePosition(Order calldata order, uint256 fillPrice_1e18) internal returns (uint256 id) {
        ParamCatalog.Structural storage s = _params[order.token].structural;
        if (s.priceTick == 0) revert UnknownToken();
        ParamCatalog.Risk storage risk = _makerRisk[order.maker][order.token];
        if (order.size == 0 || order.leverage == 0) revert BadSize();

        id = activePositionId[order.user][order.maker][order.token];
        if (id == 0) revert NoPosition();
        Position storage p = _positions[id];
        if (order.isLong   != p.isLong)   revert BadUserSig();
        if (order.leverage != p.leverage) revert BadUserSig();
        // order.maker == msg.sender == p.maker (submitter is verified against order.maker, and the
        // position was keyed by (user, maker, token)), so the maker match is already guaranteed.

        uint128 fillPriceUnits = _toPriceUnits(fillPrice_1e18, s.priceTick);
        uint128 addSizeUnits   = _toSizeUnits(order.size, s.sizeTick);

        uint256 addNotional   = _notional(fillPriceUnits, addSizeUnits, s.notionalScale);
        uint256 addCollateral = addNotional / order.leverage;
        if (addCollateral == 0) revert BadSize();

        uint256 totalNotional = uint256(p.notionalAtOpen) + addNotional;
        if (totalNotional > risk.maxPositionNotional) revert PositionNotionalCap();

        uint256 newLong  = openInterestLong[order.maker][order.token];
        uint256 newShort = openInterestShort[order.maker][order.token];
        if (order.isLong) newLong += addNotional; else newShort += addNotional;
        {
            uint256 gross = newLong + newShort;
            uint256 skew  = newLong > newShort ? newLong - newShort : newShort - newLong;
            if (gross > risk.maxOIGross) revert OIGrossCap();
            if (skew  > risk.maxOISkew)  revert OISkewCap();
        }

        // open fee charged only on the added size
        uint256 fee = (addNotional * risk.openFeeBps) / ParamCatalog.BPS_DENOM;
        uint256 addColAfterFee = addCollateral;
        if (fee > 0) {
            if (addColAfterFee <= fee) revert Insolvent();
            unchecked { addColAfterFee -= fee; }
        }

        usdm.safeTransferFrom(order.user, address(this), addCollateral);
        if (fee > 0) collateral[order.maker][order.token] += fee;

        _pushMark(order.maker, order.token, fillPrice_1e18, _markState[order.maker][order.token].currentRatePct, false);
        int128 fundingNow = _indexNow(_markState[order.maker][order.token], s.priceTick);

        // Size-weighted blends preserve the old size's unrealized PnL and accrued funding
        // exactly, while the added size enters at fillPrice / current funding.
        uint256 oldSize = uint256(p.size);
        uint256 newSize = oldSize + uint256(addSizeUnits);
        if (newSize > UNITS_CAP) revert BadSize();
        uint256 newEntry = (uint256(p.entryPrice) * oldSize + uint256(fillPriceUnits) * uint256(addSizeUnits)) / newSize;
        int256  newCheckpoint =
            (int256(p.fundingCheckpoint) * int256(oldSize) + int256(fundingNow) * int256(uint256(addSizeUnits)))
            / int256(newSize);

        uint256 newCol = uint256(p.col) + addColAfterFee;
        if (newCol > type(uint128).max)        revert BadSize();
        if (totalNotional > type(uint128).max) revert BadSize();

        p.entryPrice        = uint128(newEntry);
        p.size              = uint128(newSize);
        p.col               = uint128(newCol);
        p.fundingCheckpoint = int128(newCheckpoint);
        p.notionalAtOpen    = uint128(totalNotional);
        // The blended entry only becomes valid now, so the liquidation walk-back must not
        // look at marks before this point (they applied to the smaller, lower-entry position).
        // Resetting openTime moves that floor; it also restarts the max-duration expiry clock.
        p.openTime          = uint64(block.timestamp);

        openInterestLong[order.maker][order.token]  = newLong;
        openInterestShort[order.maker][order.token] = newShort;

        emit PositionIncreased(
            id, order.maker, order.size, fillPrice_1e18,
            _sizeOut(uint128(newSize), s.sizeTick),
            _priceOut(uint128(newEntry), s.priceTick),
            addColAfterFee, fee, int128(newCheckpoint)
        );
    }

    // ---- Close ----

    function closePosition(Order calldata order, uint256 fillPrice, bytes calldata userSig)
        external override nonReentrant whenNotHalted
    {
        if (order.isOpen) revert BadUserSig();
        _verifyAndConsumeOrder(order, userSig);
        _checkSlippageBand(fillPrice, order.targetPrice, order.maxSlippageBps);

        ParamCatalog.TokenParams storage cfg = _params[order.token];
        uint256 id = activePositionId[order.user][order.maker][order.token];
        if (id == 0) revert NoPosition();

        Position storage p = _positions[id];
        // Order's size is the portion to close; it must not exceed the position.
        uint128 closeSizeUnits = _toSizeUnits(order.size, cfg.structural.sizeTick);
        if (closeSizeUnits > p.size) revert BadUserSig();

        _pushMark(order.maker, order.token, fillPrice, _markState[order.maker][order.token].currentRatePct, false);

        (bool liqFound, uint128 markAtLiqUnits, uint16 ringStep) = _ringWalkForLiq(order.maker, order.token, id);
        if (liqFound) {
            _wipePosition(id, markAtLiqUnits, ringStep);
            return;
        }

        uint128 fillPriceUnits = _toPriceUnits(fillPrice, cfg.structural.priceTick);
        if (closeSizeUnits == p.size) {
            _settleClose(id, fillPriceUnits);
        } else {
            _settleDecrease(id, closeSizeUnits, fillPriceUnits);
        }
    }

    function expirePosition(uint256 id) external override nonReentrant {
        Position storage p = _positions[id];
        if (p.user == address(0)) revert PositionDoesNotExist();
        if (p.closed) revert PositionAlreadyClosed();
        ParamCatalog.TokenParams storage cfg = _params[p.token];
        if (block.timestamp < p.openTime + cfg.structural.maxPositionDuration) revert PositionDurationNotElapsed();
        MarkState storage st = _markState[p.maker][p.token];
        uint256 payout_ = _settleClose(id, st.currentMark);
        uint256 closePrice_1e18 = _priceOut(st.currentMark, cfg.structural.priceTick);
        emit PositionExpired(id, closePrice_1e18, payout_);
    }

    function _settleClose(uint256 id, uint128 closePriceUnits) internal returns (uint256) {
        Position storage p = _positions[id];
        ParamCatalog.TokenParams storage cfg = _params[p.token];
        MarkState storage st = _markState[p.maker][p.token];

        int128 fundingNow = _indexNow(st, cfg.structural.priceTick);

        (int256 pnl, int256 fundingPaid, uint256 payout, uint256 makerCut) =
            _settle(p, closePriceUnits, fundingNow, cfg.structural);

        _applyMakerPoolDelta(p.maker, p.token, p.col, pnl, fundingPaid, makerCut);
        _decreaseOI(p.maker, p.token, p.isLong, uint256(p.notionalAtOpen));

        int256 effPnl = pnl - fundingPaid;
        p.closed       = true;
        p.closeTime    = uint64(block.timestamp);
        p.closePrice   = closePriceUnits;
        // store effPnl (net of funding). Fits int128 because magnitudes are bounded by
        // notional (which fits uint128).
        p.realizedPnl  = int128(effPnl);
        p.makerCutPaid = uint128(makerCut);
        activePositionId[p.user][p.maker][p.token] = 0;

        address user = p.user;
        uint256 closePrice_1e18 = _priceOut(closePriceUnits, cfg.structural.priceTick);
        emit PositionClosed(id, msg.sender, closePrice_1e18, pnl, fundingPaid, makerCut, payout);
        if (payout > 0) usdm.safeTransfer(user, payout);
        return payout;
    }

    /// @dev Partial (size-down) close: settle a pro-rata slice and leave the remainder open.
    function _settleDecrease(uint256 id, uint128 closeSizeUnits, uint128 closePriceUnits)
        internal
    {
        Position storage p = _positions[id];
        ParamCatalog.TokenParams storage cfg = _params[p.token];
        MarkState storage st = _markState[p.maker][p.token];

        int128 fundingNow = _indexNow(st, cfg.structural.priceTick);

        uint256 colPortion = uint256(p.col) * closeSizeUnits / p.size;

        (int256 pnl, int256 fundingPaid, uint256 payout, uint256 makerCut) =
            _settleSlice(p, closeSizeUnits, colPortion, closePriceUnits, fundingNow, cfg.structural);

        _applyMakerPoolDelta(p.maker, p.token, colPortion, pnl, fundingPaid, makerCut);

        uint256 notionalPortion = uint256(p.notionalAtOpen) * closeSizeUnits / p.size;
        _decreaseOI(p.maker, p.token, p.isLong, notionalPortion);

        // shrink the position; entry, funding checkpoint and leverage are unchanged
        p.size           = p.size - closeSizeUnits;
        p.col            = uint128(uint256(p.col) - colPortion);
        p.notionalAtOpen = uint128(uint256(p.notionalAtOpen) - notionalPortion);

        address user = p.user;
        uint256 closePrice_1e18 = _priceOut(closePriceUnits, cfg.structural.priceTick);
        emit PositionDecreased(
            id, msg.sender, _sizeOut(closeSizeUnits, cfg.structural.sizeTick),
            closePrice_1e18, pnl, fundingPaid, makerCut, payout,
            _sizeOut(p.size, cfg.structural.sizeTick)
        );
        if (payout > 0) usdm.safeTransfer(user, payout);
    }

    function _wipePosition(uint256 id, uint128 markAtLiqUnits, uint16 ringStep) internal {
        Position storage p = _positions[id];
        uint256 wiped = uint256(p.col);
        _decreaseOI(p.maker, p.token, p.isLong, uint256(p.notionalAtOpen));
        collateral[p.maker][p.token] += wiped;
        p.closed       = true;
        p.closeTime    = uint64(block.timestamp);
        p.closePrice   = markAtLiqUnits;
        p.realizedPnl  = -int128(int256(wiped));
        activePositionId[p.user][p.maker][p.token] = 0;
        uint256 mark_1e18 = _priceOut(markAtLiqUnits, _params[p.token].structural.priceTick);
        emit PositionLiquidated(id, mark_1e18, ringStep, wiped);
    }

    function _applyMakerPoolDelta(address maker, address token, uint256 posCol, int256 pnl, int256 fundingPaid, uint256 makerCut) internal {
        int256 effPnl = pnl - fundingPaid;
        uint256 makerPoolBal = collateral[maker][token];
        if (effPnl > 0) {
            uint256 win = uint256(effPnl);
            if (makerPoolBal < win) revert Insolvent();
            unchecked { collateral[maker][token] = makerPoolBal - win + makerCut; }
        } else {
            uint256 loss = uint256(-effPnl);
            if (loss > posCol) loss = posCol;
            collateral[maker][token] += loss;
        }
    }

    function _decreaseOI(address maker, address token, bool isLong, uint256 notionalAtOpen) internal {
        if (isLong) {
            uint256 oi = openInterestLong[maker][token];
            openInterestLong[maker][token] = oi > notionalAtOpen ? oi - notionalAtOpen : 0;
        } else {
            uint256 oi = openInterestShort[maker][token];
            openInterestShort[maker][token] = oi > notionalAtOpen ? oi - notionalAtOpen : 0;
        }
    }

    function _settle(
        Position storage p,
        uint128 fillPriceUnits,
        int128 fundingNow,
        ParamCatalog.Structural storage s
    ) internal view returns (int256 pnl, int256 fundingPaid, uint256 payout, uint256 makerCut)
    {
        return _settleSlice(p, p.size, uint256(p.col), fillPriceUnits, fundingNow, s);
    }

    /// @dev Settle PnL + funding for an arbitrary `sizeUnits` slice carrying `col` collateral.
    /// With `sizeUnits == p.size` and `col == p.col` this is a full close.
    function _settleSlice(
        Position storage p,
        uint128 sizeUnits,
        uint256 col,
        uint128 fillPriceUnits,
        int128 fundingNow,
        ParamCatalog.Structural storage s
    ) internal view returns (int256 pnl, int256 fundingPaid, uint256 payout, uint256 makerCut)
    {
        int256 priceDiff = int256(uint256(fillPriceUnits)) - int256(uint256(p.entryPrice));
        if (!p.isLong) priceDiff = -priceDiff;
        pnl = priceDiff * int256(uint256(sizeUnits)) * int256(s.notionalScale);

        int256 fundingDelta = int256(fundingNow) - int256(p.fundingCheckpoint);
        if (!p.isLong) fundingDelta = -fundingDelta;
        // fundingDelta is the funding index change, denominated in the 1e18 price scale (the index
        // integrates fraction/sec × mark). Multiplying by size (asset units) gives price-scaled USDM;
        // ÷ SCALE cancels the 1e18 price scale to land in USDM-wei.
        fundingPaid = (fundingDelta * int256(uint256(sizeUnits) * s.sizeTick)) / int256(ParamCatalog.SCALE);

        int256 effPnl = pnl - fundingPaid;
        if (effPnl > 0) {
            makerCut = ParamCatalog.houseCut(
                uint256(effPnl), s.cutIntercept, s.cutSlopeBps, s.maxCutBps, _usdmDenom
            );
            payout = col + uint256(effPnl) - makerCut;
        } else {
            uint256 loss = uint256(-effPnl);
            payout = loss >= col ? 0 : col - loss;
        }
    }

    // ---- Liquidate ----

    /// @notice Liquidate positions on the caller's OWN book. `newMark` (if nonzero) is pushed to
    /// (msg.sender, token) first. Only positions whose counterparty is msg.sender are considered.
    function liquidate(address token, uint256 newMark, uint256[] calldata positionIds)
        external override nonReentrant whenNotHalted
    {
        if (newMark != 0) {
            _pushMark(msg.sender, token, newMark, _markState[msg.sender][token].currentRatePct, false);
        }
        uint256 wipedCount = 0;
        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 id = positionIds[i];
            Position storage p = _positions[id];
            if (p.user == address(0) || p.closed || p.token != token || p.maker != msg.sender) continue;
            (bool liqFound, uint128 markAtLiqUnits, uint16 ringStep) = _ringWalkForLiq(msg.sender, token, id);
            if (!liqFound) continue;
            _wipePosition(id, markAtLiqUnits, ringStep);
            wipedCount++;
        }
        if (wipedCount == 0) revert NoneLiquidated();
    }

    function _ringWalkForLiq(address maker, address token, uint256 id)
        internal view returns (bool found, uint128 markAtLiqUnits, uint16 ringStep)
    {
        Position storage p = _positions[id];
        if (p.user == address(0) || p.closed) return (false, 0, 0);
        MarkState storage st = _markState[maker][token];
        if (st.lastPushAt == 0) return (false, 0, 0);
        ParamCatalog.TokenParams storage cfg = _params[token];

        uint128 markAtK  = st.currentMark;
        uint256 priceTick = cfg.structural.priceTick;
        int128  indexAtK = _indexNow(st, priceTick);
        uint64  timeAtK  = uint64(block.timestamp);
        int64   ratePct  = st.currentRatePct;

        if (_isLiquidatable(p, markAtK, indexAtK, cfg.structural.sizeTick, cfg.structural.notionalScale))
            return (true, markAtK, 0);

        uint256 head = st.ringHead;
        uint256 available = head < MarkRing.RING_LEN ? head : MarkRing.RING_LEN;
        for (uint256 k = 1; k <= available; k++) {
            uint256 idx = head - k;
            uint32 markE = MarkRing.readMarkEntry(_markRing[maker][token], idx);
            if (MarkRing.isSentinel(markE)) return (false, 0, 0);
            (int256 priceDelta, uint256 timeDelta10) = MarkRing.unpackEntry(markE);
            uint64 durationSec = uint64(timeDelta10 * MarkRing.GAP_UNIT_MS / 1000);
            // Step the index back at this segment's fixed-point rate and the mark held during it.
            indexAtK = FundingIndex.stepBackPct(indexAtK, ratePct, uint256(markAtK) * priceTick, durationSec);
            timeAtK  -= durationSec;
            int256 prev = int256(uint256(markAtK)) - priceDelta;
            if (prev <= 0) return (false, 0, 0);
            markAtK = uint128(uint256(prev));
            if (timeAtK >= p.openTime &&
                _isLiquidatable(p, markAtK, indexAtK, cfg.structural.sizeTick, cfg.structural.notionalScale)) {
                return (true, markAtK, uint16(k));
            }
            ratePct = MarkRing.readRateEntry(_rateRing[maker][token], idx);
        }
        return (false, 0, 0);
    }

    function _isLiquidatable(
        Position storage p,
        uint128 markUnits,
        int128 indexAtK,
        uint256 sizeTick,
        uint256 notionalScale
    ) internal view returns (bool) {
        int256 fundingDelta = int256(indexAtK) - int256(p.fundingCheckpoint);
        if (!p.isLong) fundingDelta = -fundingDelta;
        // ÷ SCALE cancels the 1e18 price scale carried by the funding index; result is USDM-wei.
        int256 fundingPaid = (fundingDelta * int256(uint256(p.size) * sizeTick)) / int256(ParamCatalog.SCALE);
        int256 priceDiff = int256(uint256(markUnits)) - int256(uint256(p.entryPrice));
        if (!p.isLong) priceDiff = -priceDiff;
        int256 pnl = priceDiff * int256(uint256(p.size)) * int256(notionalScale);
        int256 effPnl = pnl - fundingPaid;
        if (effPnl >= 0) return false;
        return uint256(-effPnl) >= p.col;
    }

    // ---- Views ----

    /// @notice Return a position with its live risk. `realizedPnl` is the *effective* PnL (net
    /// of funding); the gross PnL / funding split is recoverable from the `PositionClosed` event.
    /// `payoutReceived` is derived: `max(0, col + realizedPnl - makerCutPaid)`. `fundingOwed` and
    /// `liqPrice` are live (computed at the current mark) and read 0 once the position is closed.
    function positions(uint256 id) external view override returns (PositionView memory v) {
        Position storage p = _positions[id];
        ParamCatalog.Structural storage s = _params[p.token].structural;
        int256 effPnl_ = int256(p.realizedPnl);
        uint256 payout_;
        if (p.closed) {
            int256 net = int256(uint256(p.col)) + effPnl_ - int256(uint256(p.makerCutPaid));
            payout_ = net > 0 ? uint256(net) : 0;
        }
        v = PositionView({
            user:              p.user,
            token:             p.token,
            isLong:            p.isLong,
            size:              _sizeOut(p.size, s.sizeTick),
            leverage:          uint256(p.leverage),
            entryPrice:        _priceOut(p.entryPrice, s.priceTick),
            col:               uint256(p.col),
            fundingCheckpoint: p.fundingCheckpoint,
            openTime:          p.openTime,
            notionalAtOpen:    uint256(p.notionalAtOpen),
            closed:            p.closed,
            closeTime:         p.closeTime,
            closePrice:        _priceOut(p.closePrice, s.priceTick),
            realizedPnl:       effPnl_,
            makerCutPaid:      uint256(p.makerCutPaid),
            payoutReceived:    payout_,
            fundingOwed:       _fundingOwed(p, s),
            liqPrice:          _liqPrice(p, s)
        });
    }

    function _fundingOwed(Position storage p, ParamCatalog.Structural storage s) internal view returns (int256) {
        if (p.user == address(0) || p.closed) return 0;
        MarkState storage st = _markState[p.maker][p.token];
        int128 indexNow = _indexNow(st, s.priceTick);
        int256 delta = int256(indexNow) - int256(p.fundingCheckpoint);
        if (!p.isLong) delta = -delta;
        // ÷ SCALE cancels the 1e18 price scale carried by the funding index; result is USDM-wei.
        return (delta * int256(uint256(p.size) * s.sizeTick)) / int256(ParamCatalog.SCALE);
    }

    function _liqPrice(Position storage p, ParamCatalog.Structural storage s) internal view returns (uint256) {
        if (p.user == address(0) || p.closed) return 0;
        int256 fundingPaid = _fundingOwed(p, s);
        int256 denom = int256(uint256(p.size)) * int256(s.notionalScale);
        if (denom == 0) return 0;
        int256 delta = (int256(uint256(p.col)) + fundingPaid) / denom;
        int256 thresholdUnits = p.isLong
            ? int256(uint256(p.entryPrice)) - delta
            : int256(uint256(p.entryPrice)) + delta;
        if (thresholdUnits < 0) return 0;
        return uint256(thresholdUnits) * s.priceTick;
    }
}
