// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2MarketTest } from "./H2Market.t.sol";
import { IH2Market }  from "../../src/h2/IH2Market.sol";

/// Zenith #25 — a matured unstake request is withdrawable for 2 days, then expires and must be re-requested.
contract Zenith25 is H2MarketTest {
    function test_F25_matureRequestExpiresAfterTwoDays() public {
        uint256 cs = h.stakeOf(mkt, carl).shares;
        vm.prank(carl); h.requestUnstake(mkt, cs);
        _adv(TERM + 2 days); _pushMark(50_000e18, 0, 0, 0); // last second of the window
        vm.prank(carl); uint256 out = h.withdraw(mkt);
        assertGt(out, 0, "withdrawable at the end of the window");
    }

    function test_F25_expiredRequestRevertsAndKeepsShares() public {
        uint256 cs = h.stakeOf(mkt, carl).shares;
        vm.prank(carl); h.requestUnstake(mkt, cs);
        _adv(TERM + 2 days + 1); _pushMark(50_000e18, 0, 0, 0);
        vm.prank(carl);
        vm.expectRevert(IH2Market.UnstakeExpired.selector);
        h.withdraw(mkt);
        assertEq(h.stakeOf(mkt, carl).shares, cs, "shares untouched");
        // Re-requesting restarts the cooldown; the standing option is gone.
        vm.prank(carl); h.requestUnstake(mkt, cs);
        vm.prank(carl);
        vm.expectRevert(IH2Market.CooldownActive.selector);
        h.withdraw(mkt);
        _adv(TERM); _pushMark(50_000e18, 0, 0, 0);
        vm.prank(carl); assertGt(h.withdraw(mkt), 0);
    }
}
