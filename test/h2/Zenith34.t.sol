// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2MarketTest } from "./H2Market.t.sol";
import { IH2Market }  from "../../src/h2/IH2Market.sol";

/// Zenith #34 — expiry on a fresh primary sits behind the same convergence gate as every other
/// settlement path: a fresh fallback that disagrees by more than `maxDeviationPpm` blocks it.
contract Zenith34 is H2MarketTest {
    function _expire(uint256 id) internal returns (uint256 paid) {
        uint256 before = usdm.balanceOf(alice);
        h.expirePosition(id);
        paid = usdm.balanceOf(alice) - before;
    }

    /// Primary fresh at 50,000, fresh fallback at 45,000 (−10%, far past the 1 bp gate): a close
    /// would revert `DeviationGate`; so does expiry, until the feeds converge.
    function test_F34_freshPrimaryExpiryRespectsConvergenceGate() public {
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        uint256 col = h.positions(id).col;
        _adv(30 days + 1);
        _pushMark(50_000e18, 0, 0, 0);                                        // fresh primary
        fallbackFeed.setAnswer(45_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        vm.expectRevert(IH2Market.DeviationGate.selector);
        h.expirePosition(id);
        // Feeds converge ⇒ expiry settles at the mark (flat: entry 50,000, no close fee).
        fallbackFeed.setAnswer(50_000e8);
        assertEq(_expire(id), col, "settles at the fresh, agreeing mark");
        assertTrue(h.positions(id).closed);
    }

    /// A stale fallback is no anchor to disagree with (same as `onMark`): expiry proceeds.
    function test_F34_freshPrimaryExpiryIgnoresStaleFallback() public {
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        uint256 col = h.positions(id).col;
        fallbackFeed.setAnswer(45_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        _adv(30 days + 1);                                                    // fallback now stale
        _pushMark(50_000e18, 0, 0, 0);
        assertEq(_expire(id), col, "stale, disagreeing fallback does not gate expiry");
    }

    /// Zenith's scenario: primary STALE at 50,000, fresh fallback at 45,000. Expiry prices off the
    /// fallback (#15), so the long is settled at 44,910 and pays nothing — it does not escape the
    /// −10% move at the stale mark.
    function test_F34_stalePrimaryExpiryFollowsDivergentFreshFallback() public {
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);          // col 475
        _adv(30 days + 1);
        fallbackFeed.setAnswer(45_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        assertEq(_expire(id), 0, "settled at the fresh fallback: loss exceeds collateral");
        assertTrue(h.positions(id).closed);
    }
}
