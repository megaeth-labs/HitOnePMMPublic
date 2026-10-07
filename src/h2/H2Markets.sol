// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2Storage }    from "./H2Storage.sol";
import { IH2Oracle }    from "./IH2Oracle.sol";
import { ParamCatalog } from "../common/ParamCatalog.sol";
import { IAggregatorV3 } from "../common/IAggregatorV3.sol";
import { FundingIndex } from "../common/FundingIndex.sol";

/// @title H2Markets
/// @notice Market creation (the only "admin" the exchange has), parameter validation, and
/// the oracle-reading helpers every execution path shares.
abstract contract H2Markets is H2Storage {
    // ---- Market creation ----

    /// @notice Permissionless. `msg.sender` is recorded as the market's creator (identity
    /// only — the treasury is a role-less share vault); every parameter is validated once and
    /// then frozen. Changing anything means creating a successor market and letting this run off.
    function createMarket(
        address token,
        FeeParams calldata fees_,
        RiskParams calldata risk_,
        OracleParams calldata oracles_,
        SpreadParams calldata spread_,
        address builderRegistry
    ) external override returns (uint256 marketId) {
        if (token == address(0)) revert BadMarketParams();
        FeeParams memory f = fees_;
        RiskParams memory r = risk_;
        OracleParams memory o = oracles_;
        SpreadParams memory sp = spread_;

        // ---- fees ----
        if (f.openFlatPpm  > ParamCatalog.MAX_FEE_PPM ||
            f.closeFlatPpm > ParamCatalog.MAX_FEE_PPM) revert BadMarketParams();
        if (f.openLinearScale  > PPM || f.openQuadScale  > PPM ||
            f.closeLinearScale > PPM || f.closeQuadScale > PPM) revert BadMarketParams();
        if (f.maxCutPpm > ParamCatalog.MAX_HOUSE_CUT_PPM) revert BadMarketParams();
        if (f.maxBuilderFeePpm > 500_000) revert BadMarketParams(); // builder share cap ≤ 50%

        // ---- spread parameterization (vol/skew → derived spread) ----
        // Bound the coefficients so the derived-spread intermediate can't be absurd; the
        // per-fill cap (maxSpreadPpm) clamps the result regardless. All-zero (incl. zero close
        // coefficients for zero close spread) is a valid, supported config.
        if (sp.openVolK > 1e9 || sp.openSkewK > 1e9 ||
            sp.closeVolK > 1e9 || sp.closeSkewK > 1e9) revert BadMarketParams();
        // maxSpreadPpm == 0 clamps the derived spread to 0 on every fill; reject a market that
        // pairs it with nonzero coefficients (a silent no-op the creator surely didn't intend).
        if (r.maxSpreadPpm == 0 &&
            (sp.openVolK != 0 || sp.openSkewK != 0 || sp.closeVolK != 0 || sp.closeSkewK != 0))
            revert BadMarketParams();

        // ---- risk ----
        if (r.priceTick == 0 || r.sizeTick == 0) revert BadMarketParams();
        uint256 product = uint256(r.priceTick) * uint256(r.sizeTick);
        if (product < _usdmDenom || product % _usdmDenom != 0) revert BadMarketParams();
        uint256 scale = product / _usdmDenom;
        if (scale > type(uint128).max) revert BadMarketParams();
        r.notionalScale = uint128(scale);
        if (r.minLeverage < ParamCatalog.MIN_LEVERAGE_FLOOR ||
            r.maxLeverage > ParamCatalog.MAX_LEVERAGE_CEIL ||
            r.minLeverage > r.maxLeverage) revert BadMarketParams();
        if (r.maxPositionDuration < ParamCatalog.MIN_DURATION_FLOOR ||
            r.maxPositionDuration > ParamCatalog.MAX_DURATION_CEIL) revert BadMarketParams();
        if (r.maxPositionNotional == 0) revert BadMarketParams(); // opens have no solvency gate
        if (r.maxOIGross == 0) r.maxOIGross = type(uint128).max;
        if (r.maxOISkew == 0)  r.maxOISkew  = type(uint128).max;
        if (r.liqWidthPpm > 100_000) revert BadMarketParams(); // early-trigger width ≤ 10%
        if (r.unstakeSecs > 30 days) revert BadMarketParams(); // 0 = no cooldown; ≤ 30 d
        // staleSpreadK is ppm per √ms; at the sentinel gap (√4095 ≈ 64) the bound below
        // keeps the max self-service spread ≤ ~20% (64 × 3125 ≈ 200_000 ppm). 0 disables
        // executeAtMark for the market.
        if (r.staleSpreadK > 3_125) revert BadMarketParams();
        // ≥ 1: at least a one-block gap between adjustments to a position (0 would let a position be
        // opened and adjusted in the same block, re-opening the size-fee chunking dodge).
        if (r.minAdjustGapBlocks == 0 || r.minAdjustGapBlocks > 1_000_000) revert BadMarketParams();

        // ---- oracles ----
        IH2Oracle.FeedView memory feed = _oracle.feedOf(o.primaryFeedId); // reverts UnknownFeed
        // The ring is recorded in the feed's tick; the walk-back replays it in the
        // market's units, so the two must be identical.
        if (feed.priceTick != r.priceTick) revert BadMarketParams();
        if (o.fallbackFeed == address(0)) revert BadMarketParams();
        if (o.fallbackDecimals > 18) revert BadMarketParams();
        // Decimals scale the fallback price to 1e18; a caller-supplied value that disagrees with
        // the aggregator would misprice every fallback fill and skew the deviation gate, so pin
        // it to the feed's own `decimals()` rather than trust the argument.
        if (IAggregatorV3(o.fallbackFeed).decimals() != o.fallbackDecimals) revert BadMarketParams();
        if (o.primaryStaleSecs == 0 || o.primaryStaleSecs > 1 days) revert BadMarketParams();
        if (o.fallbackMaxAge == 0 || o.fallbackMaxAge > 1 hours) revert BadMarketParams();
        if (o.fbOpenSpreadPpm > 200_000 || o.fbCloseSpreadPpm > 200_000) revert BadMarketParams();
        if (o.fbLiqSpreadPpm > o.fbCloseSpreadPpm) revert BadMarketParams();
        if (o.maxDeviationPpm == 0 || o.maxDeviationPpm > 200_000) revert BadMarketParams();
        if (r.maxSpreadPpm > 200_000) revert BadMarketParams();

        // No anti-sandwich fee-floor: extracting the 2·maxDeviationPpm round-trip gap requires the
        // operator to park marks at opposite gate edges, i.e. a compromised/dishonest feed — which
        // can already do far worse (arbitrary marks, forced liquidations). An honest operator's mark
        // tracks truth, so the gap is ~0. The design trusts the feed operator; the deviation gate
        // stays as a staleness/sanity check, not as protection against the operator itself.

        // The coupled funding ceiling: funding accrued during the window users cannot
        // exit without the operator can never eat more than half of worst-case
        // collateral. The rate bound is the FEED's frozen cap (enforced at push — indices
        // integrate history, so no consumption-time cap could undo an accrual), and the
        // market's own cap field must dominate it.
        if (r.fundingRateCapPerSec == 0 || feed.maxRatePerSec > r.fundingRateCapPerSec)
            revert BadMarketParams();
        if (uint256(r.fundingRateCapPerSec) * uint256(o.primaryStaleSecs) * uint256(r.maxLeverage) * 2
            > uint256(FundingIndex.PCT_SCALE)) revert BadMarketParams();

        marketId = ++nextMarketId;
        if (marketId > type(uint64).max) revert BadMarketParams(); // Position packs it uint64
        _fees[marketId]      = f;
        _risk[marketId]      = r;
        _oracles[marketId]   = o;
        _spread[marketId]    = sp;
        _creatorOf[marketId] = msg.sender;
        _tokenOf[marketId]   = token;
        // Builder registry is an external, swappable eligibility oracle — the market never
        // validates it (0 = builder codes disabled); `_builderEligible` reads it behind a try/catch.
        _builderRegistry[marketId] = builderRegistry;
        // Cache the primary feed's rake — the operator's frozen cut of this market's earnings.
        _vault[marketId].rakePpm = uint32(feed.feeRakePpm);
        emit MarketCreated(marketId, msg.sender, token, f, r, o);
    }

    // ---- views ----

    function creatorOf(uint256 marketId) external view override returns (address) {
        return _creatorOf[marketId];
    }
    function feeParamsOf(uint256 marketId) external view override returns (FeeParams memory) {
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        return _fees[marketId];
    }
    function riskParamsOf(uint256 marketId) external view override returns (RiskParams memory) {
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        return _risk[marketId];
    }
    function oracleParamsOf(uint256 marketId) external view override returns (OracleParams memory) {
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        return _oracles[marketId];
    }
    function spreadParamsOf(uint256 marketId) external view override returns (SpreadParams memory) {
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        return _spread[marketId];
    }

    function builderRegistryOf(uint256 marketId) external view override returns (address) {
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        return _builderRegistry[marketId];
    }
    function marketOf(uint256 marketId) external view override returns (MarketView memory) {
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        IH2Oracle.FeedView memory feed = _oracle.feedOf(_oracles[marketId].primaryFeedId);
        return MarketView({
            creator:           _creatorOf[marketId],
            token:             _tokenOf[marketId],
            primaryFeedId:     _oracles[marketId].primaryFeedId,
            mark:              feed.mark,
            lastPushMs:        feed.lastPushMs,
            openInterestLong:  openInterestLong[marketId],
            openInterestShort: openInterestShort[marketId]
        });
    }

    // ---- oracle-reading helpers ----

    function _feed(uint256 marketId) internal view returns (IH2Oracle.FeedView memory) {
        return _oracle.feedOf(_oracles[marketId].primaryFeedId);
    }

    /// @dev The market's derived spread (PPM) for one side/action, from the feed's published
    /// vol/skew and the market's frozen coefficients, capped at `maxSpreadPpm`. Zero close
    /// coefficients ⇒ zero close spread (the winnings rake prices closes instead).
    function _derivedSpread(uint256 marketId, IH2Oracle.FeedView memory feed, bool isOpen, bool isLong)
        internal view returns (uint256)
    {
        SpreadParams storage sp = _spread[marketId];
        (uint32 volK, uint32 skewK) = isOpen ? (sp.openVolK, sp.openSkewK) : (sp.closeVolK, sp.closeSkewK);
        // Skew keys off the taker's fill direction, not the position side: `up` is true when the
        // taker is buying (opening a long or closing a short), so skew>0 charges buyers more.
        bool up = (isLong == isOpen);
        return ParamCatalog.derivedSpread(feed.vol, feed.skew, volK, skewK, up, _risk[marketId].maxSpreadPpm);
    }

    /// @dev One side's funding index projected to now, computed locally from a FeedView
    /// (saves a second oracle call on paths that already fetched the feed).
    function _indexNow(IH2Oracle.FeedView memory feed, bool isLong) internal view returns (int128) {
        return FundingIndex.effectiveAtPctMs(
            isLong ? feed.fundingIndexLong : feed.fundingIndexShort,
            isLong ? feed.rateLong : feed.rateShort,
            feed.mark,
            feed.lastPushMs, uint64(_microTimestamp() / 1000)
        );
    }

    /// @dev THE CONVERGENCE CHECK: require the primary mark and the fallback to agree
    /// within `maxDeviationPpm` — a fresh fallback that disagrees blocks the action rather
    /// than letting either price win. Publications are ungated (the oracle doesn't know
    /// markets exist), so the ring stays alive through a gated window and the walk-back can
    /// catch in-window crossings once the gate lifts.
    ///
    /// The two callers differ only in how they treat a STALE fallback:
    ///  - `requireFallback == false` (operator-attached `onMark`, authoritative fresh mark):
    ///    a stale fallback is simply no anchor to disagree with, so the check passes.
    ///  - `requireFallback == true` (self-service against a STALE mark): the mark is only
    ///    trustworthy if the fresh fallback vouches for it, so a missing anchor is fatal.
    function _assertConvergence(uint256 marketId, uint256 primaryMark1e18, bool requireFallback)
        internal view
    {
        OracleParams storage o = _oracles[marketId];
        (uint256 fb, bool fresh) = _fallbackRead(o);
        if (!fresh) {
            if (requireFallback) revert OracleTooOld();
            return;
        }
        uint256 diff = primaryMark1e18 > fb ? primaryMark1e18 - fb : fb - primaryMark1e18;
        if (diff * PPM > uint256(o.maxDeviationPpm) * fb) revert DeviationGate();
    }

}
