// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// The ONE place the mainnet market parameters are built. DeployH2Mainnet.s.sol creates markets
// from these helpers and CheckH2Rules.s.sol evaluates src/h2/DEPLOY_RULES.md against the same
// values, so the rules are checked against exactly what gets deployed. Env names and defaults are
// documented in DeployH2Mainnet.s.sol; the hard-coded values are the mainnet BTC parameters.

import { Script }    from "forge-std/Script.sol";
import { IH2Market } from "../../src/h2/IH2Market.sol";

abstract contract H2MainnetParams is Script {
    // ---- feed-level env ----------------------------------------------------
    function _refBandPpm()  internal view returns (uint32)  { return uint32(vm.envOr("REF_BAND_PPM", uint256(10_000))); }
    function _refMaxStale() internal view returns (uint32)  { return uint32(vm.envOr("REF_MAX_STALE", uint256(21_600))); }
    function _feeRakePpm()  internal view returns (uint32)  { return uint32(vm.envOr("FEE_RAKE_PPM", uint256(150_000))); }
    function _maxRate()     internal view returns (uint64)  { return uint64(vm.envOr("MAX_RATE_PER_SEC", uint256(1_500_000_000_000_000))); }
    function _bootstrap()   internal view returns (uint256) { return vm.envOr("BOOTSTRAP_USDM", uint256(0)); }

    // ---- builder registry env (only read when a fresh registry is deployed) ----
    function _stakeToken() internal view returns (address) { return vm.envOr("BUILDER_STAKE_TOKEN", address(0)); }
    function _minStake()   internal view returns (uint256) { return vm.envOr("BUILDER_MIN_STAKE", uint256(0.01 ether)); }

    // ---- market parameter structs ------------------------------------------
    function _fees() internal view returns (IH2Market.FeeParams memory) {
        return IH2Market.FeeParams({
            openFlatPpm: 50, openLinearScale: 0, openQuadScale: 0,
            closeFlatPpm: 50, closeLinearScale: 0, closeQuadScale: 0,
            cutInterceptPpm: 100_000, cutSlopePpm: 100_000, maxCutPpm: 55_000,
            maxBuilderFeePpm: uint32(vm.envOr("MAX_BUILDER_FEE_PPM", uint256(100_000)))
        });
    }

    function _spread() internal view returns (IH2Market.SpreadParams memory) {
        return IH2Market.SpreadParams({
            openVolK:   uint32(vm.envOr("SPREAD_OPEN_VOL_K",   uint256(0))),
            openSkewK:  uint32(vm.envOr("SPREAD_OPEN_SKEW_K",  uint256(0))),
            closeVolK:  uint32(vm.envOr("SPREAD_CLOSE_VOL_K",  uint256(0))),
            closeSkewK: uint32(vm.envOr("SPREAD_CLOSE_SKEW_K", uint256(0)))
        });
    }

    function _risk(uint256 priceTick, uint256 sizeTick) internal view returns (IH2Market.RiskParams memory) {
        return IH2Market.RiskParams({
            priceTick: uint128(priceTick), sizeTick: uint128(sizeTick),
            notionalScale: 0,
            minLeverage: 100, maxLeverage: 1000,
            maxPositionDuration: 30 days,
            // #43 sizing (2026-10-26): seed >= maxOISkew x 10% worst move -> 1,000 USDm covers 10k skew.
            maxPositionNotional: 10_000e18,
            maxOIGross: 40_000e18, maxOISkew: 10_000e18,
            liqWidthPpm: 0,
            fundingRateCapPerSec: _maxRate(),
            maxSpreadPpm: uint32(vm.envOr("MAX_SPREAD_PPM", uint256(5_000))),
            unstakeSecs: 7 days,
            staleSpreadK: 0,
            minAdjustGapBlocks: uint32(vm.envOr("MIN_ADJUST_GAP_BLOCKS", uint256(1)))
        });
    }

    function _oracleParams(uint64 feedId, address fallbackFeed, uint8 fbDec)
        internal view returns (IH2Market.OracleParams memory)
    {
        return IH2Market.OracleParams({
            primaryFeedId: feedId,
            primaryStaleSecs: uint32(vm.envOr("PRIMARY_STALE_SECS", uint256(300))),
            fallbackFeed: fallbackFeed,
            fallbackDecimals: fbDec,
            fallbackMaxAge: uint32(vm.envOr("FALLBACK_MAX_AGE", uint256(60))),
            fbOpenSpreadPpm: 2_000, fbCloseSpreadPpm: 2_000, fbLiqSpreadPpm: 1_000,
            maxDeviationPpm: uint32(vm.envOr("MAX_DEVIATION_PPM", uint256(10_000)))
        });
    }
}
