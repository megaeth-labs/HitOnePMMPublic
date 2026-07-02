// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import { HitOneStorage }     from "./HitOneStorage.sol";
import { ParamCatalog }      from "../common/ParamCatalog.sol";
import { IAggregatorV3 }     from "../common/IAggregatorV3.sol";
import { IHighPrecisionTimestamp } from "../common/IHighPrecisionTimestamp.sol";
import { MarkRing }          from "../common/MarkRing.sol";
import { FundingIndex }      from "../common/FundingIndex.sol";

/// @title HitOneMarks
/// @notice Mark + funding push logic and the mark-domain views.
abstract contract HitOneMarks is HitOneStorage {
    // ---- Mark + funding (admin) ----

    function setMark(address token, uint256 newMark) external override onlyMaker whenNotPaused {
        _pushMark(token, newMark, _markState[token].currentRatePct, false);
    }
    // newRate is a signed fixed-point funding FRACTION per second (real = newRate / (100 * 2**63)),
    // NOT a price-scaled amount. The int64 range inherently caps it at ±1%/sec, so no explicit
    // bound check is needed. See IHitOneMarket.setMarkAndRate for the full semantics.
    function setMarkAndRate(address token, uint256 newMark, int64 newRate) external override onlyMaker whenNotPaused {
        _pushMark(token, newMark, newRate, true);
    }

    /// @dev Project the committed funding index forward to now, folding the live funding rate into
    /// the live mark. `priceTick` converts `currentMark` (price units) back to 1e18 USDM-wei.
    function _indexNow(MarkState storage st, uint256 priceTick) internal view returns (int128) {
        return FundingIndex.effectiveAtPct(
            st.fundingIndex, st.currentRatePct, uint256(st.currentMark) * priceTick,
            st.lastPushAt, uint64(block.timestamp)
        );
    }

    function _pushMark(address token, uint256 newMark_1e18, int64 nextRate, bool isRateChange) internal {
        ParamCatalog.TokenParams storage cfg = _params[token];
        if (cfg.structural.priceTick == 0) revert UnknownToken();
        uint128 newMarkUnits = _toPriceUnits(newMark_1e18, cfg.structural.priceTick);

        _checkOracleBand(token, newMark_1e18, cfg.risk.maxDevBps);
        uint256 microTs = _microTimestamp();
        uint64 nowMs = uint64(microTs / 1000);

        MarkState storage st = _markState[token];
        if (st.lastPushAt == 0) {
            st.currentMark = newMarkUnits;
            st.lastPushAt  = uint64(block.timestamp);
            st.lastPushMs  = nowMs;
            st.currentRatePct = nextRate;
            emit MarkPushed(token, newMark_1e18, 0, 0, false, microTs);
            if (isRateChange) emit FundingRateChanged(token, 0, nextRate, uint64(block.timestamp));
            return;
        }

        // Liveness + ring gap run on the HP millisecond clock; funding stays second-based.
        uint64 elapsedMs = nowMs - st.lastPushMs;
        if (elapsedMs == 0) revert MarkSameSlot();

        int64 oldRate = st.currentRatePct;
        // Accrue the elapsed interval at the OLD rate and OLD mark (both still live here — the
        // mark is a step function held until this push overwrites it below).
        st.fundingIndex = _indexNow(st, cfg.structural.priceTick);

        int256 priceDelta;
        unchecked {
            priceDelta = int256(uint256(newMarkUnits)) - int256(uint256(st.currentMark));
        }

        uint64 head = st.ringHead;
        uint256 elapsedUnits = uint256(elapsedMs) / MarkRing.GAP_UNIT_MS;
        bool sentinel = elapsedUnits > MarkRing.GAP_MAX_UNITS;

        uint32 markEntry;
        if (sentinel) {
            markEntry = MarkRing.sentinelEntry();
            emit MarkPushed(token, newMark_1e18, priceDelta, 0, true, microTs);
        } else {
            markEntry = MarkRing.packEntry(priceDelta, elapsedUnits);
            emit MarkPushed(token, newMark_1e18, priceDelta, uint16(elapsedUnits), false, microTs);
        }
        MarkRing.writeMarkEntry(_markRing[token], head, markEntry);
        MarkRing.writeRateEntry(_rateRing[token], head, oldRate);

        st.ringHead    = head + 1;
        st.currentMark = newMarkUnits;
        st.lastPushAt  = uint64(block.timestamp);
        st.lastPushMs  = nowMs;

        if (isRateChange) {
            st.currentRatePct = nextRate;
            emit FundingRateChanged(token, oldRate, nextRate, uint64(block.timestamp));
        }
    }

    /// @dev Microsecond wall-clock from MegaETH's system contract, for off-chain validation of
    /// mark timing. Falls back to `block.timestamp × 1e6` if the system contract is absent (e.g.
    /// non-MegaETH chains or tests) so a mark push never bricks on the read.
    function _microTimestamp() internal view returns (uint256) {
        (bool ok, bytes memory ret) = HP_TIMESTAMP.staticcall(
            abi.encodeWithSelector(IHighPrecisionTimestamp.timestamp.selector)
        );
        if (ok && ret.length >= 32) return abi.decode(ret, (uint256));
        return uint256(block.timestamp) * 1_000_000;
    }

    function _checkOracleBand(address token, uint256 newMark_1e18, uint256 maxDevBps) internal view {
        OracleConfig storage oc = _oracleConfig[token];
        address feed = oc.feed;
        if (feed == address(0)) return;
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0)                                           revert OracleBadAnswer();
        if (block.timestamp > updatedAt + uint256(oc.maxStale))    revert OracleStale();
        uint256 oraclePx = uint256(answer) * (10 ** (18 - uint256(oc.decimals)));
        uint256 diff = newMark_1e18 > oraclePx ? newMark_1e18 - oraclePx : oraclePx - newMark_1e18;
        if (diff * ParamCatalog.BPS_DENOM > maxDevBps * oraclePx) revert MarkOutOfOracleBand();
    }

    // ---- Mark-domain views ----

    function marketOf(address token) external view override returns (MarketView memory) {
        MarkState storage st = _markState[token];
        return MarketView({
            mark:             _priceOut(st.currentMark, _params[token].structural.priceTick),
            fundingIndex:     st.fundingIndex,
            currentRatePct:      st.currentRatePct,
            ringHead:         st.ringHead,
            openInterestLong:  openInterestLong[token],
            openInterestShort: openInterestShort[token]
        });
    }
    function rateRingAt(address token, uint16 idx) external view override returns (int64) {
        return MarkRing.readRateEntry(_rateRing[token], idx);
    }

    function reconstructAt(address token, uint16 entries) external view override returns (
        uint256 markAtK, int128 fundingAtK, uint64 timeAtK
    ) {
        MarkState storage st = _markState[token];
        uint64 nowT = uint64(block.timestamp);
        if (st.lastPushAt == 0 || entries == 0) {
            return (
                _priceOut(st.currentMark, _params[token].structural.priceTick),
                _indexNow(st, _params[token].structural.priceTick),
                nowT
            );
        }
        return _reconstructWalk(token, entries);
    }

    function _reconstructWalk(address token, uint16 entries) internal view returns (
        uint256 markAtK_1e18, int128 fundingAtK, uint64 timeAtK
    ) {
        MarkState storage st = _markState[token];
        ParamCatalog.Structural storage s = _params[token].structural;
        uint256 markAtKUnits = uint256(st.currentMark);
        fundingAtK = _indexNow(st, s.priceTick);
        timeAtK    = uint64(block.timestamp);
        int64 ratePct = st.currentRatePct;

        uint256 head = st.ringHead;
        uint256 available = head < MarkRing.RING_LEN ? head : MarkRing.RING_LEN;
        uint256 limit = entries < available ? entries : available;
        for (uint256 k = 1; k <= limit; k++) {
            uint256 idx = head - k;
            uint32 me = MarkRing.readMarkEntry(_markRing[token], idx);
            if (MarkRing.isSentinel(me)) return (0, 0, 0);
            (int256 pDelta, uint256 td10) = MarkRing.unpackEntry(me);
            uint64 durationSec = uint64(td10 * MarkRing.GAP_UNIT_MS / 1000);
            // Step the index back over this segment at its fixed-point rate and the mark held during it.
            fundingAtK = FundingIndex.stepBackPct(fundingAtK, ratePct, markAtKUnits * s.priceTick, durationSec);
            timeAtK   -= durationSec;
            int256 prev = int256(markAtKUnits) - pDelta;
            if (prev <= 0) return (0, 0, 0);
            markAtKUnits = uint256(prev);
            ratePct = MarkRing.readRateEntry(_rateRing[token], idx);
        }
        markAtK_1e18 = markAtKUnits * s.priceTick;
    }
}
