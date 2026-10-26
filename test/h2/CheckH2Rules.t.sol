// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";

import { CheckH2Rules }     from "../../script/h2/CheckH2Rules.s.sol";
import { MockAggregatorV3 } from "../mocks/MockAggregatorV3.sol";

/// @notice The warn-only rules checker must pass the mainnet configuration clean and flag each
/// rule when its input breaks, without ever reverting. A silent checker is worse than none.
///
/// ONE test function on purpose: the checker reads the process env (`vm.setEnv` is global and
/// forge runs tests in parallel), so the scenarios run back to back and each one starts from the
/// mainnet env.
contract CheckH2RulesTest is Test {
    address internal feed;

    /// The mainnet.env.example values, minus anything the checker does not read.
    function _mainnetEnv() internal {
        vm.setEnv("FALLBACK_FEEDS", vm.toString(feed));
        vm.setEnv("PRICE_TICKS", "1000000000000000000");
        vm.setEnv("SIZE_TICKS", "10000000000");
        vm.setEnv("REF_FEEDS", vm.toString(feed));
        vm.setEnv("REF_BAND_PPM", "10000");
        vm.setEnv("REF_MAX_STALE", "21600");
        vm.setEnv("MAX_DEVIATION_PPM", "10000");
        vm.setEnv("PRIMARY_STALE_SECS", "300");
        vm.setEnv("MIN_ADJUST_GAP_BLOCKS", "1");
        vm.setEnv("BOOTSTRAP_USDM", "100000000000000000000000");
        vm.setEnv("BUILDER_STAKE_TOKEN", "0x0000000000000000000000000000000000000000");
        // BUILDER_REGISTRY stays unset (fresh registry); env vars cannot be unset from here, so
        // the scenarios that set it run last.
    }

    function _run() internal returns (uint256 passed, uint256 warned) {
        return new CheckH2Rules().run();
    }

    function _warns(string memory label, uint256 expected) internal {
        (, uint256 warned) = _run();
        assertEq(warned, expected, label);
        _mainnetEnv();
    }

    function test_rulesCheckerFlagsEachBreakAndPassesMainnet() public {
        feed = address(new MockAggregatorV3(8, 80_000e8, block.timestamp));
        _mainnetEnv();

        (uint256 passed, uint256 warned) = _run();
        assertEq(warned, 0, "mainnet config warns");
        assertEq(passed, 14, "every check counted");

        // Rule 1: band vs gate, same feed, band on, finite staleness.
        vm.setEnv("REF_BAND_PPM", "20000");                                   // 2% band vs 1% gate
        _warns("rule 1: band wider than gate", 1);
        vm.setEnv("REF_FEEDS", vm.toString(address(new MockAggregatorV3(8, 80_000e8, block.timestamp))));
        _warns("rule 1: different reference feed", 1);
        vm.setEnv("REF_BAND_PPM", "1000000");                                 // 100%: off (and > gate)
        vm.setEnv("REF_MAX_STALE", "4294967295");                             // never stale
        _warns("rule 1: band off + never stale", 3);

        // Rule 2: unseeded vault.
        vm.setEnv("BOOTSTRAP_USDM", "0");
        _warns("rule 2: unseeded vault", 1);

        // Rule 3: fallback decimals, and a feed with no code warns instead of reverting.
        address wide = address(new MockAggregatorV3(18, 80_000e18, block.timestamp));
        vm.setEnv("FALLBACK_FEEDS", vm.toString(wide)); vm.setEnv("REF_FEEDS", vm.toString(wide));
        _warns("rule 3: 18-decimal fallback", 1);
        vm.setEnv("FALLBACK_FEEDS", "0x00000000000000000000000000000000000000ff");
        vm.setEnv("REF_FEEDS", "0x00000000000000000000000000000000000000ff");
        _warns("rule 3: feed without code", 1);

        // Rule 6: 300 s at 1.5e15/s is 488 ppm against a 950 ppm budget; 600 s (976 ppm) is over.
        vm.setEnv("PRIMARY_STALE_SECS", "600");
        _warns("rule 6: funding budget blown", 1);
        vm.setEnv("MIN_ADJUST_GAP_BLOCKS", "2");
        _warns("rule 6: adjustment gap > 1", 1);

        // Rule 4: ERC-20 stake or a reused registry need a manual check; disabled passes.
        vm.setEnv("BUILDER_STAKE_TOKEN", "0x00000000000000000000000000000000000000aa");
        _warns("rule 4: ERC-20 stake", 1);
        vm.setEnv("BUILDER_REGISTRY", "0x00000000000000000000000000000000000000bb");
        _warns("rule 4: reused registry", 1);
        vm.setEnv("BUILDER_REGISTRY", "0x0000000000000000000000000000000000000000");
        _warns("rule 4: builder codes disabled", 0);
    }

    function test_rule6_reportsTheMainnetNumbers() public pure {
        // Fixed point for the reference deployment quoted in DEPLOY_RULES.md: 488 ppm vs 950 ppm.
        uint256 scale = uint256(int256(100) << 63);
        uint256 fundingPpm = (uint256(1_500_000_000_000_000) * 300 * 1_000_000 + scale - 1) / scale; // ceil
        uint256 budgetPpm = uint256(1_000_000) / 1000 - 50 - 0; // 1/maxLev − open fee − width
        assertEq(fundingPpm, 488);
        assertEq(budgetPpm, 950);
    }
}
