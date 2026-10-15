// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2MarketTest } from "./H2Market.t.sol";
import { IH2Market }  from "../../src/h2/IH2Market.sol";

/// Zenith #24 — LP slippage bounds: deposit(…, minShares) and withdraw(…, minAssets).
contract Zenith24 is H2MarketTest {
    function test_F24_depositMinSharesBound() public {
        uint256 quote = 1_000e18;                  // 1:1 vault (5M pool / 5M shares) ⇒ 1,000 shares
        // A trader loss lands before the deposit: the pool grows, the share price rises.
        _openLong(alicePk, 4e18, 100, 50_000e18, 0);
        _adv(1); _pushMark(49_600e18, 0, 0, 0);
        _adv(1);
        IH2Market.Order memory c = _order(alicePk, true, false, 4e18, 0, 49_600e18, 200, 1);
        _pushOrder(49_600e18, c, _sign(alicePk, c), 0);
        vm.prank(bob);
        vm.expectRevert(IH2Market.SlippageExceeded.selector);
        h.deposit(mkt, 1_000e18, quote);           // fewer than the 1:1 quote would be minted
        vm.prank(bob);
        uint256 sh = h.deposit(mkt, 1_000e18, quote * 99 / 100); // 1% tolerance passes
        assertLt(sh, quote); assertGt(sh, quote * 99 / 100);
    }

    function test_F24_withdrawMinAssetsBoundRevertsBeforeBurning() public {
        uint256 cs = h.stakeOf(mkt, carl).shares;
        vm.prank(carl); h.requestUnstake(mkt, cs);
        _adv(TERM);
        // A trader win is paid before the withdrawal: the pool shrinks, the share price falls.
        _openLong(alicePk, 4e18, 100, 50_000e18, 0);
        _adv(1); _pushMark(50_400e18, 0, 0, 0);
        _adv(1);
        IH2Market.Order memory c = _order(alicePk, true, false, 4e18, 0, 50_400e18, 200, 1);
        c.deadline = uint64(_t + 1 hours);
        _pushOrder(50_400e18, c, _sign(alicePk, c), 0);
        uint256 pool = h.vaultOf(mkt).poolAssets;
        vm.prank(carl);
        vm.expectRevert(IH2Market.SlippageExceeded.selector);
        h.withdraw(mkt, 5_000_000e18);             // wants the pre-loss value
        assertEq(h.stakeOf(mkt, carl).shares, cs, "nothing burned");
        assertEq(h.stakeOf(mkt, carl).unstakeShares, cs, "request intact");
        vm.prank(carl);
        uint256 out = h.withdraw(mkt, pool - 1);
        assertApproxEqAbs(out, pool, 1);
    }

    function test_F24_plainEntrypointsUnchanged() public {
        vm.prank(bob); uint256 sh = h.deposit(mkt, 1_000e18);
        assertEq(sh, 1_000e18);
        vm.prank(bob); h.requestUnstake(mkt, sh);
        _adv(TERM); _pushMark(50_000e18, 0, 0, 0); // withdraw prices at a fresh mark
        vm.prank(bob); assertEq(h.withdraw(mkt), 1_000e18);
    }
}
