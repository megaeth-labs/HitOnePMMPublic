// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// The ONE place the mainnet launch configuration lives. DeployH2Mainnet.s.sol deploys exactly
// these values and CheckH2Rules.s.sol evaluates src/h2/DEPLOY_RULES.md against the same values.
// No env file is needed: the constants below ARE the MegaETH mainnet (4326) launch. Every getter
// still takes an env override (same names as before), which the rules-checker test uses.

import { Script }    from "forge-std/Script.sol";
import { IH2Market } from "../../src/h2/IH2Market.sol";

abstract contract H2MainnetParams is Script {
    // ---- launch configuration: MegaETH mainnet 4326, one BTC market ----------
    uint256 internal constant CHAIN_ID     = 4326;
    address internal constant USDM         = 0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7; // USDm (MegaUSD), 18 dec, settlement
    address internal constant WBTC         = 0x32090fB1399a31cC095e6341a6353b7c09ba84FB; // market token, identity only
    address internal constant REDSTONE_BTC = 0xf0DEbDAE819b354D076b0D162e399BE013A856d3; // BTC/USD fallback + reference, 8 dec
    address internal constant OPERATOR     = 0x159B0e603c58899F53a0633fc37F3167b6AB6F39; // pushes marks, receives the rake
    uint256 internal constant PRICE_TICK   = 1e18;     // $1
    uint256 internal constant SIZE_TICK    = 1e10;     // 1e-8 BTC
    uint256 internal constant SEED_USDM    = 1_000e18; // per market; >= maxOISkew x 10% move (#43)

    function _chainId()  internal view returns (uint256) { return vm.envOr("EXPECT_CHAIN_ID", CHAIN_ID); }
    function _usdm()     internal view returns (address) { return vm.envOr("USDM", USDM); }
    function _operator() internal view returns (address) { return vm.envOr("OPERATOR", OPERATOR); }
    function _tokens()     internal view returns (address[] memory) { return vm.envOr("MARKET_TOKENS", ",", _addrs(WBTC)); }
    function _fallbacks()  internal view returns (address[] memory) { return vm.envOr("FALLBACK_FEEDS", ",", _addrs(REDSTONE_BTC)); }
    function _refs()       internal view returns (address[] memory) { return vm.envOr("REF_FEEDS", ",", _fallbacks()); }
    function _priceTicks() internal view returns (uint256[] memory) { return vm.envOr("PRICE_TICKS", ",", _uints(PRICE_TICK)); }
    function _sizeTicks()  internal view returns (uint256[] memory) { return vm.envOr("SIZE_TICKS", ",", _uints(SIZE_TICK)); }

    function _addrs(address a) private pure returns (address[] memory out) { out = new address[](1); out[0] = a; }
    function _uints(uint256 v) private pure returns (uint256[] memory out) { out = new uint256[](1); out[0] = v; }

    // ---- feed-level ----------------------------------------------------------
    function _refBandPpm()  internal view returns (uint32)  { return uint32(vm.envOr("REF_BAND_PPM", uint256(10_000))); }
    function _refMaxStale() internal view returns (uint32)  { return uint32(vm.envOr("REF_MAX_STALE", uint256(21_600))); }
    function _feeRakePpm()  internal view returns (uint32)  { return uint32(vm.envOr("FEE_RAKE_PPM", uint256(150_000))); }
    function _maxRate()     internal view returns (uint64)  { return uint64(vm.envOr("MAX_RATE_PER_SEC", uint256(1_500_000_000_000_000))); }
    function _bootstrap()   internal view returns (uint256) { return vm.envOr("BOOTSTRAP_USDM", SEED_USDM); }

    // ---- builder registry (only read when a fresh registry is deployed) ------
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
            // #43 sizing: the pool is every trade's counterparty, so seed >= maxOISkew x 10% move.
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
