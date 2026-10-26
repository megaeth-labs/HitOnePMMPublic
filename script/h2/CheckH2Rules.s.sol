// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Evaluates src/h2/DEPLOY_RULES.md against the parameters DeployH2Mainnet.s.sol would deploy
// with the current env. WARN-ONLY: it never reverts and sends nothing; the deployer reads the
// table. mainnet-deploy.sh runs it in the preflight. The rules are configuration policy the
// contracts cannot enforce; the deploy script itself stays policy-free.
//
//   source script/h2/mainnet.env
//   forge script script/h2/CheckH2Rules.s.sol --rpc-url $RPC_4326 -vv
//
// Needs the same per-market env as the deploy (FALLBACK_FEEDS, PRICE_TICKS, SIZE_TICKS, optional
// REF_FEEDS); USDM / MARKET_TOKENS are not required. Fallback decimals (rule 3) are read on chain,
// so point it at the target RPC.

import { console2 }        from "forge-std/Script.sol";
import { H2MainnetParams } from "./H2MainnetParams.sol";
import { IH2Market }       from "../../src/h2/IH2Market.sol";
import { IAggregatorV3 }   from "../../src/common/IAggregatorV3.sol";
import { FundingIndex }    from "../../src/common/FundingIndex.sol";
import { ParamCatalog }    from "../../src/common/ParamCatalog.sol";

contract CheckH2Rules is H2MainnetParams {
    uint256 internal constant PPM = 1_000_000;

    uint256 internal _passed;
    uint256 internal _warned;

    function run() external returns (uint256 passed, uint256 warned) {
        address[] memory fallbacks  = vm.envAddress("FALLBACK_FEEDS", ",");
        uint256[] memory priceTicks = vm.envUint("PRICE_TICKS", ",");
        uint256[] memory sizeTicks  = vm.envUint("SIZE_TICKS", ",");
        address[] memory refs       = vm.envOr("REF_FEEDS", ",", fallbacks);
        uint256 n = fallbacks.length;
        console2.log("Deployment rules (src/h2/DEPLOY_RULES.md), warn-only");
        _check(priceTicks.length == n && sizeTicks.length == n && refs.length == n,
            "env: per-market lists have equal length");

        IH2Market.FeeParams memory fees = _fees();

        for (uint256 i = 0; i < n; i++) {
            // The deploy pins the fallback's decimals from the feed; without code there is no feed.
            uint8 fbDec = 0;
            bool hasCode = fallbacks[i].code.length > 0;
            if (hasCode) fbDec = IAggregatorV3(fallbacks[i]).decimals();
            IH2Market.RiskParams   memory risk = _risk(priceTicks[i], sizeTicks[i]);
            IH2Market.OracleParams memory op   = _oracleParams(uint64(i + 1), fallbacks[i], fbDec);

            console2.log("market", i + 1, "fallback", fallbacks[i]);
            _rule1(refs[i], fallbacks[i], op.maxDeviationPpm);
            _check(hasCode, "rule 3: fallback feed has code at this RPC");
            if (hasCode) _checkV(fbDec <= 12, "rule 3: fallback decimals <= 12", fbDec);
            _rule6(fees, risk, op);
            _checkV(risk.liqWidthPpm <= op.fbCloseSpreadPpm - op.fbLiqSpreadPpm,
                "rule 7: liqWidthPpm <= fbCloseSpreadPpm - fbLiqSpreadPpm", risk.liqWidthPpm);
            _rule9(risk);
        }

        console2.log("vault / registry / fees");
        _checkV(_bootstrap() > 0, "rule 2: BOOTSTRAP_USDM > 0 (seed every vault at creation)", _bootstrap());
        _rule4();
        _check(uint256(fees.cutSlopePpm) * fees.cutInterceptPpm <= PPM * (PPM - 2 * uint256(fees.maxCutPpm)),
            "rule 5: cutSlopePpm * cutInterceptPpm <= 1e6 * (1e6 - 2 * maxCutPpm)");
        _check(fees.openLinearScale == 0 && fees.openQuadScale == 0
            && fees.closeLinearScale == 0 && fees.closeQuadScale == 0,
            "rule 8: size-scaling fee terms are all 0 (flat curves)");

        console2.log("rules: passed", _passed, "warned", _warned);
        if (_warned > 0) console2.log("WARN: read the flagged rules in src/h2/DEPLOY_RULES.md before broadcasting");
        return (_passed, _warned);
    }

    /// Rule 1 (#35, #44): band <= deviation gate, same feed, band and staleness meaningful.
    function _rule1(address ref, address fallbackFeed, uint32 maxDeviationPpm) internal {
        uint32 band = _refBandPpm();
        uint32 stale = _refMaxStale();
        _checkV(band <= maxDeviationPpm, "rule 1: REF_BAND_PPM <= MAX_DEVIATION_PPM", band);
        _check(ref == fallbackFeed, "rule 1: REF_FEEDS == FALLBACK_FEEDS");
        _checkV(band < PPM, "rule 1: reference band is on (REF_BAND_PPM < 100%)", band);
        _checkV(stale < type(uint32).max && stale <= 1 days,
            "rule 1: REF_MAX_STALE finite and <= 1 day", stale);
    }

    /// Rule 4 (#10): native stake, or an ERC-20 the deployer has vetted (not checkable here).
    function _rule4() internal {
        address existing = vm.envOr("BUILDER_REGISTRY", address(type(uint160).max));
        if (existing == address(0)) { _check(true, "rule 4: builder codes disabled"); return; }
        if (existing != address(type(uint160).max)) {
            _check(false, "rule 4: reusing BUILDER_REGISTRY, verify its stake token by hand");
            return;
        }
        address stake = _stakeToken();
        if (stake == address(0)) _check(true, "rule 4: builder stake is native ETH");
        else _check(false, "rule 4: ERC-20 stake token, confirm no transfer fee / rebasing");
    }

    /// Rule 6 (#12): funding over the stale window vs post-fee collateral at max leverage.
    function _rule6(IH2Market.FeeParams memory fees, IH2Market.RiskParams memory risk,
        IH2Market.OracleParams memory op) internal
    {
        uint256 scale = uint256(FundingIndex.PCT_SCALE);
        uint256 fundingPpm = (uint256(risk.fundingRateCapPerSec) * op.primaryStaleSecs * PPM + scale - 1) / scale; // ceil
        uint256 grossPpm = PPM / risk.maxLeverage;
        // Flat curves (rule 8) make the open fee at any notional the flat rate.
        uint256 budget = grossPpm > fees.openFlatPpm + risk.liqWidthPpm
            ? grossPpm - fees.openFlatPpm - risk.liqWidthPpm : 0;
        _checkVV(fundingPpm <= budget, "rule 6: funding over PRIMARY_STALE_SECS (ppm) <= post-fee collateral (ppm)",
            fundingPpm, budget);
        _checkV(risk.minAdjustGapBlocks == 1, "rule 6: MIN_ADJUST_GAP_BLOCKS == 1", risk.minAdjustGapBlocks);
    }

    /// Rule 9 (#20) is the order builder's; print the bound the desk must hold.
    function _rule9(IH2Market.RiskParams memory risk) internal view {
        uint256 bps = 10_000 / risk.maxLeverage;
        uint256 widthBps = risk.liqWidthPpm / 100;
        console2.log("  NOTE rule 9: order builders keep maxSlippageBps <", bps > widthBps ? bps - widthBps : 0);
    }

    function _check(bool ok, string memory what) internal {
        if (ok) { _passed++; console2.log("  PASS", what); }
        else    { _warned++; console2.log("  WARN", what); }
    }
    function _checkV(bool ok, string memory what, uint256 value) internal {
        if (ok) { _passed++; console2.log("  PASS", what, value); }
        else    { _warned++; console2.log("  WARN", what, value); }
    }
    function _checkVV(bool ok, string memory what, uint256 a, uint256 b) internal {
        if (ok) { _passed++; console2.log("  PASS", what, a, b); }
        else    { _warned++; console2.log("  WARN", what, a, b); }
    }
}
