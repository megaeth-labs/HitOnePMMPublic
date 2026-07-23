// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test }          from "forge-std/Test.sol";
import { Vm }            from "forge-std/Vm.sol";
import { Ownable }       from "@openzeppelin/contracts/access/Ownable.sol";

import { HitOneMarket }  from "../../src/hitone/HitOneMarket.sol";
import { IHitOneMarket } from "../../src/hitone/IHitOneMarket.sol";
import { ParamCatalog }  from "../../src/common/ParamCatalog.sol";
import { MockERC20 }     from "../mocks/MockERC20.sol";
import { MockHighPrecisionTimestamp } from "../mocks/MockHighPrecisionTimestamp.sol";
import { MockAggregatorV3 } from "../mocks/MockAggregatorV3.sol";

contract HitOneMarketTest is Test {
    HitOneMarket internal h;
    MockERC20    internal usdm;

    address internal owner  = address(this);
    address internal maker  = makeAddr("maker");
    address internal maker2 = makeAddr("maker2");
    address internal funder = makeAddr("funder");
    address internal halter = makeAddr("halter");

    // Users sign orders with their keys.
    uint256 internal alicePk = 0xA11CE;
    address internal alice;
    uint256 internal bobPk = 0xB0B;
    address internal bob;

    address internal token;

    bytes32 internal DOMAIN_SEPARATOR;
    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "Order(address user,address maker,address token,bool isLong,bool isOpen,uint256 size,uint256 leverage,"
        "uint256 targetPrice,uint256 maxSlippageBps,uint64 deadline,uint256 channel,uint256 nonce)"
    );

    uint64 internal _t;
    function _adv(uint64 dt) internal { _t += dt; vm.warp(_t); }

    function _structural() internal pure returns (ParamCatalog.Structural memory) {
        return ParamCatalog.Structural({
            priceTick: 1e18, sizeTick: 1e10, notionalScale: 0,
            minLeverage: 100, maxLeverage: 1000,
            maxPositionDuration: 30 days,
            cutIntercept: 0, cutSlopeBps: 550, maxCutBps: 550
        });
    }
    function _defaultRisk() internal pure returns (ParamCatalog.Risk memory) {
        return ParamCatalog.Risk({
            openFeeBps: 0, linearScale: type(uint256).max, quadScale: type(uint256).max,
            maxPositionNotional: 0,
            maxOIGross: 0, maxOISkew: 0, maxDevBps: 0
        });
    }

    /// @notice Register a fresh maker: it sets its own risk, appoints `f` as funder, and (via `f`)
    /// funds its pool + pushes an initial mark. Used to stand up additional makers in tests.
    function _standUpMaker(address m, address f, uint256 poolAmt) internal {
        vm.prank(m);
        h.setRiskLimits(token, _defaultRisk());
        vm.prank(m);
        h.setMakerFunder(m, f);
        usdm.mint(f, poolAmt);
        vm.startPrank(f);
        usdm.approve(address(h), type(uint256).max);
        h.fundMakerPool(m, token, poolAmt);
        vm.stopPrank();
        vm.prank(m);
        h.setMark(token, 50_000e18);
    }

    function setUp() public {
        _t = 1_000_000;
        vm.warp(_t);

        alice = vm.addr(alicePk);
        bob   = vm.addr(bobPk);

        usdm = new MockERC20();
        h = new HitOneMarket(owner, address(usdm));

        // Owner curates the token (structural grid only).
        token = makeAddr("btc");
        h.setToken(token, _structural());

        // The halter is the only timelocked role.
        uint256 rh = h.queueSetHalter(halter, true);
        _t += uint64(h.roleChangeDelay() + 1);
        vm.warp(_t);
        h.executeRoleChange(rh);

        DOMAIN_SEPARATOR = _domainSep();

        // Fund wallets + grant allowance. Collateral is pulled from wallets on open.
        usdm.mint(alice, 1_000_000e18);
        usdm.mint(bob,   1_000_000e18);

        vm.prank(alice);
        usdm.approve(address(h), type(uint256).max);
        vm.prank(bob);
        usdm.approve(address(h), type(uint256).max);

        // The maker self-registers: sets its own risk, appoints `funder`, funds its pool, marks.
        _standUpMaker(maker, funder, 5_000_000e18);
    }

    // ---- EIP-712 helpers ----

    function _domainSep() internal view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("HitOneMarket")),
            keccak256(bytes("1")),
            block.chainid,
            address(h)
        ));
    }

    function _digest(IHitOneMarket.Order memory o) internal view returns (bytes32) {
        bytes32 sh = keccak256(abi.encode(
            ORDER_TYPEHASH,
            o.user, o.maker, o.token, o.isLong, o.isOpen, o.size, o.leverage,
            o.targetPrice, o.maxSlippageBps, o.deadline, o.channel, o.nonce
        ));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, sh));
    }

    function _sign(uint256 pk, IHitOneMarket.Order memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(o));
        return abi.encodePacked(r, s, v);
    }

    function _openOrder(
        address user, bool isLong, uint256 size, uint256 leverage,
        uint256 target, uint256 slipBps, uint256 nonce
    ) internal view returns (IHitOneMarket.Order memory) {
        return IHitOneMarket.Order({
            user: user, maker: maker, token: token, isLong: isLong, isOpen: true,
            size: size, leverage: leverage,
            targetPrice: target, maxSlippageBps: slipBps,
            deadline: uint64(block.timestamp + 1 hours),
            channel: 0, nonce: nonce
        });
    }

    function _closeOrder(
        address user, bool isLong, uint256 size,
        uint256 target, uint256 slipBps, uint256 nonce
    ) internal view returns (IHitOneMarket.Order memory) {
        return IHitOneMarket.Order({
            user: user, maker: maker, token: token, isLong: isLong, isOpen: false,
            size: size, leverage: 0,
            targetPrice: target, maxSlippageBps: slipBps,
            deadline: uint64(block.timestamp + 1 hours),
            channel: 0, nonce: nonce
        });
    }

    /// @notice Submit an open as the maker; size in 1e18 asset-wei, all prices in 1e18 USDM-wei.
    function _submitOpenLong(uint256 userPk, uint256 size, uint256 target, uint256 fillPrice, uint256 nonce)
        internal returns (uint256 id)
    {
        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(vm.addr(userPk), true, size, 100, target, 100, nonce);
        bytes memory sig = _sign(userPk, o);
        vm.prank(maker);
        id = h.openPosition(o, fillPrice, sig);
    }

    // ============================================================
    // Constructor + roles
    // ============================================================

    function test_constructorRejectsZeroUsdm() public {
        vm.expectRevert(IHitOneMarket.ZeroAddress.selector);
        new HitOneMarket(owner, address(0));
    }

    function test_permissionlessSelfRegistration() public {
        // No registration step: a brand-new address can run a book on a registered token by
        // setting its own risk, funding a pool, and marking. It then opens for a user.
        address maker3 = makeAddr("maker3");
        address funder3 = makeAddr("funder3");
        _standUpMaker(maker3, funder3, 1_000_000e18);

        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(bob, true, 1e18, 100, 50_000e18, 100, 0);
        o.maker = maker3;
        bytes memory sig = _sign(bobPk, o);
        vm.prank(maker3);
        uint256 id = h.openPosition(o, 50_000e18, sig);
        assertEq(h.positions(id).user, bob);
        assertEq(h.activePositionId(bob, maker3, token), id);
    }

    function test_openRejectsMakerMismatch() public {
        // The submitter must be the exact maker the user signed for.
        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(bob, true, 1e18, 100, 50_000e18, 100, 0);
        // o.maker == maker; a different address submitting reverts WrongMaker.
        bytes memory sig = _sign(bobPk, o);
        vm.prank(maker2);
        vm.expectRevert(IHitOneMarket.WrongMaker.selector);
        h.openPosition(o, 50_000e18, sig);
    }

    // ============================================================
    // Open
    // ============================================================

    function test_openRejectsNonMakerCaller() public {
        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(alice, true, 1e18, 100, 50_000e18, 100, 0);
        bytes memory sig = _sign(alicePk, o);
        // Submitter must be the exact maker named in the order (`maker`), so alice is rejected.
        vm.prank(alice);
        vm.expectRevert(IHitOneMarket.WrongMaker.selector);
        h.openPosition(o, 50_000e18, sig);
    }

    function test_openCreatesPositionAssignedToUser() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        IHitOneMarket.PositionView memory p = h.positions(id);
        assertEq(p.user, alice);
        assertEq(p.token, token);
        assertTrue(p.isLong);
        assertEq(p.size, 1e18);
        assertEq(h.activePositionId(alice, maker, token), id);
    }

    function test_openDebitsUser_notMaker() public {
        uint256 aliceBefore = usdm.balanceOf(alice);
        uint256 makerBefore = usdm.balanceOf(maker);
        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        assertEq(usdm.balanceOf(alice), aliceBefore - 500e18);
        assertEq(usdm.balanceOf(maker), makerBefore);
    }

    function test_openRejectsWrongAction() public {
        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(alice, true, 1e18, 100, 50_000e18, 100, 0);
        o.isOpen = false;  // mismatch
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.BadUserSig.selector);
        h.openPosition(o, 50_000e18, sig);
    }

    function test_openRejectsExpiredOrder() public {
        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(alice, true, 1e18, 100, 50_000e18, 100, 0);
        o.deadline = uint64(block.timestamp - 1);
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.OrderExpired.selector);
        h.openPosition(o, 50_000e18, sig);
    }

    function test_openRejectsBadUserSig() public {
        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(alice, true, 1e18, 100, 50_000e18, 100, 0);
        // Sign with bob's key instead of alice's — recovered signer != o.user.
        bytes memory sig = _sign(bobPk, o);
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.BadUserSig.selector);
        h.openPosition(o, 50_000e18, sig);
    }

    function test_openRejectsReusedNonce() public {
        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(bob, true, 1e18, 100, 50_000e18, 100, 0);
        // alice signs — but alice's nonce 0 already used, this is bob's nonce 0 which is independent.
        // So this should actually succeed for bob.
        // To test reused nonce: alice tries to use nonce 0 again.
        o = _openOrder(alice, true, 1e18, 100, 50_000e18, 100, 0);
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.NonceAlreadyUsed.selector);
        h.openPosition(o, 50_000e18, sig);
    }

    function test_openSlippageBandRespected() public {
        _adv(1);
        // Target = 50k, slippage = 100 bps (1%). Maker tries to fill at 51k → out of band.
        IHitOneMarket.Order memory o = _openOrder(alice, true, 1e18, 100, 50_000e18, 100, 0);
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.SlippageExceeded.selector);
        h.openPosition(o, 51_000e18, sig);
    }

    function test_openSlippageBandAcceptsWithinBand() public {
        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(alice, true, 1e18, 100, 50_000e18, 100, 0);
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        // 50_500 is 1% of 50_000 — exactly at the boundary, should pass.
        h.openPosition(o, 50_500e18, sig);
        assertGt(h.activePositionId(alice, maker, token), 0);
    }

    function test_openRejectsSecondActiveForSameUserToken() public {
        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(alice, true, 1e18, 100, 50_000e18, 100, 1);
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.PositionExists.selector);
        h.openPosition(o, 50_000e18, sig);
    }

    function test_openMakerFieldInEvent() public {
        // Indirectly verifies submitter via positions / activePositionId.
        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        assertGt(h.activePositionId(alice, maker, token), 0);
    }

    // ============================================================
    // Close
    // ============================================================

    function test_closeProfitableLong() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        id;

        _adv(1);
        IHitOneMarket.Order memory o = _closeOrder(alice, true, 1e18, 51_000e18, 100, 1);
        bytes memory sig = _sign(alicePk, o);

        uint256 balBefore = usdm.balanceOf(alice);
        vm.prank(maker);
        h.closePosition(o, 51_000e18, sig);
        uint256 balAfter = usdm.balanceOf(alice);

        // PnL ≈ $1000 on 100x position; 5.5% maker cut. Payout ≈ 500 + 945 = 1445.
        assertGt(balAfter - balBefore, 1400e18);
        assertLt(balAfter - balBefore, 1500e18);
    }

    function test_closeRejectsWrongAction() public {
        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _adv(1);
        IHitOneMarket.Order memory o = _closeOrder(alice, true, 1e18, 51_000e18, 100, 1);
        o.isOpen = true;  // mismatch
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.BadUserSig.selector);
        h.closePosition(o, 51_000e18, sig);
    }

    function test_closeRejectsSizeLargerThanPosition() public {
        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _adv(1);
        // Order's size exceeds the position's size — partial close can't grow it.
        IHitOneMarket.Order memory o = _closeOrder(alice, true, 2e18, 51_000e18, 100, 1);
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.BadUserSig.selector);
        h.closePosition(o, 51_000e18, sig);
    }

    function test_closeRejectsSlippageExceeded() public {
        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _adv(1);
        IHitOneMarket.Order memory o = _closeOrder(alice, true, 1e18, 51_000e18, 10, 1);  // 10 bps tolerance
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.SlippageExceeded.selector);
        h.closePosition(o, 52_000e18, sig);  // 2% off — exceeds 10 bps
    }

    function test_closeNoActivePosition() public {
        _adv(1);
        IHitOneMarket.Order memory o = _closeOrder(alice, true, 1e18, 50_000e18, 100, 0);
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.NoPosition.selector);
        h.closePosition(o, 50_000e18, sig);
    }

    function test_closeRetainsPositionRecord() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _adv(1);
        IHitOneMarket.Order memory o = _closeOrder(alice, true, 1e18, 51_000e18, 100, 1);
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        h.closePosition(o, 51_000e18, sig);

        IHitOneMarket.PositionView memory p = h.positions(id);
        assertEq(p.user, alice);
        assertEq(p.token, token);
        assertTrue(p.closed);
        assertEq(p.closePrice, 51_000e18);
    }

    function test_closeAllowsReopenAfter() public {
        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _adv(1);
        IHitOneMarket.Order memory o = _closeOrder(alice, true, 1e18, 51_000e18, 100, 1);
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        h.closePosition(o, 51_000e18, sig);

        uint256 id2 = _submitOpenLong(alicePk, 1e18, 51_000e18, 51_000e18, 2);
        assertEq(id2, 2);
    }

    // ============================================================
    // Liquidate
    // ============================================================

    function test_liquidateAtCurrentMark() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _adv(1);
        vm.prank(maker);
        h.setMark(token, 44_000e18);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(maker);
        h.liquidate(token, 0, ids);          // mark already posted; 0 => liquidate at current mark
        IHitOneMarket.PositionView memory p = h.positions(id);
        assertTrue(p.closed);
        assertEq(p.payoutReceived, 0);
        assertEq(h.activePositionId(alice, maker, token), 0);
    }

    function test_liquidateWithMarkPush() public {
        // Post the liquidating mark and wipe in a single call.
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _adv(1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(maker);
        h.liquidate(token, 44_000e18, ids);
        IHitOneMarket.PositionView memory p = h.positions(id);
        assertTrue(p.closed);
        assertEq(p.payoutReceived, 0);
        assertEq(h.activePositionId(alice, maker, token), 0);
        // the pushed mark stuck as the current mark
        assertEq(h.marketOf(maker, token).mark, 44_000e18);
    }

    function test_liquidateMarkPushNotLiquidatableReverts() public {
        // A non-zero mark still within the solvent range wipes nothing => NoneLiquidated,
        // and the whole tx (including the mark push) reverts.
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _adv(1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.NoneLiquidated.selector);
        h.liquidate(token, 50_500e18, ids);
        assertEq(h.marketOf(maker, token).mark, 50_000e18, "mark push rolled back with the revert");
    }

    function test_liquidateOnlyOwnBook() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        // A non-counterparty caller has the id skipped (p.maker != msg.sender) -> nothing wiped.
        vm.prank(alice);
        vm.expectRevert(IHitOneMarket.NoneLiquidated.selector);
        h.liquidate(token, 0, ids);
    }

    // ============================================================
    // Mark high-precision timestamp (MegaETH system contract)
    // ============================================================

    address internal constant HP_TIMESTAMP = 0x6342000000000000000000000000000000000002;
    bytes32 internal constant MARK_PUSHED_SIG =
        keccak256("MarkPushed(address,address,uint256,int256,uint16,bool,uint256)");

    function _lastMarkMicroTs(Vm.Log[] memory logs) internal pure returns (bool found, uint256 micro) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == MARK_PUSHED_SIG) {
                (, , , , micro) = abi.decode(logs[i].data, (uint256, int256, uint16, bool, uint256));
                found = true;
            }
        }
    }

    function test_markPushEmitsSystemContractTimestamp() public {
        // Etch the mock at the canonical system-contract address; slot 0 holds the µs value.
        vm.etch(HP_TIMESTAMP, address(new MockHighPrecisionTimestamp()).code);
        uint256 micros = 1_720_000_000_123_456;
        vm.store(HP_TIMESTAMP, bytes32(uint256(0)), bytes32(micros));

        _adv(1);
        vm.recordLogs();
        vm.prank(maker);
        h.setMark(token, 51_000e18);

        (bool found, uint256 micro) = _lastMarkMicroTs(vm.getRecordedLogs());
        assertTrue(found, "MarkPushed emitted");
        assertEq(micro, micros, "system-contract micro timestamp carried in event");
    }

    function test_markPushTimestampFallsBackWithoutSystemContract() public {
        // No code at the system-contract address -> fall back to block.timestamp * 1e6.
        _adv(1);
        vm.recordLogs();
        vm.prank(maker);
        h.setMark(token, 51_000e18);

        (bool found, uint256 micro) = _lastMarkMicroTs(vm.getRecordedLogs());
        assertTrue(found, "MarkPushed emitted");
        assertEq(micro, uint256(block.timestamp) * 1_000_000, "fallback micro timestamp");
    }

    function test_markPushSubSecondAllowedOnHpClock() public {
        // Liveness runs on the HP millisecond clock, so two marks can land in the same
        // block.timestamp second as long as the HP wall-clock advanced by >= 1ms.
        vm.etch(HP_TIMESTAMP, address(new MockHighPrecisionTimestamp()).code);
        _adv(1);
        uint256 base = uint256(block.timestamp) * 1_000_000;
        vm.store(HP_TIMESTAMP, bytes32(uint256(0)), bytes32(base));
        vm.prank(maker);
        h.setMark(token, 50_100e18);

        // Same second, +200ms on the HP clock → distinct slot, accepted.
        vm.store(HP_TIMESTAMP, bytes32(uint256(0)), bytes32(base + 200_000));
        vm.prank(maker);
        h.setMark(token, 50_200e18);
        assertEq(h.marketOf(maker, token).mark, 50_200e18, "sub-second mark accepted");

        // Same HP millisecond → rejected as a same-slot push.
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.MarkSameSlot.selector);
        h.setMark(token, 50_300e18);
    }

    // ============================================================
    // Expire
    // ============================================================

    function test_expireAfter30Days() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _adv(uint64(30 days + 1));
        h.expirePosition(id);
        assertTrue(h.positions(id).closed);
        assertEq(h.activePositionId(alice, maker, token), 0);
    }

    function test_expireRevertsBefore30Days() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        vm.expectRevert(IHitOneMarket.PositionDurationNotElapsed.selector);
        h.expirePosition(id);
    }

    // ============================================================
    // Halt
    // ============================================================

    function test_haltBlocksOpenAndClose() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        vm.prank(halter);
        h.halt();

        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(bob, true, 1e18, 100, 50_000e18, 100, 0);
        bytes memory sig = _sign(bobPk, o);
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.MarketHalted.selector);
        h.openPosition(o, 50_000e18, sig);

        IHitOneMarket.Order memory co = _closeOrder(alice, true, 1e18, 51_000e18, 100, 1);
        bytes memory csig = _sign(alicePk, co);
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.MarketHalted.selector);
        h.closePosition(co, 51_000e18, csig);

        id;
    }

    function test_haltAuthAndCooldown() public {
        // Only halters can halt — makers, funders, owner and randoms cannot.
        vm.prank(makeAddr("rando"));
        vm.expectRevert(IHitOneMarket.NotHalter.selector);
        h.halt();

        vm.prank(funder);
        vm.expectRevert(IHitOneMarket.NotHalter.selector);
        h.halt();

        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.NotHalter.selector);
        h.halt();

        // owner is likewise excluded from halt.
        vm.expectRevert(IHitOneMarket.NotHalter.selector);
        h.halt();

        vm.prank(halter);
        h.halt();
        assertTrue(h.halted());
        uint64 until = h.haltedUntil();
        assertEq(until, uint64(block.timestamp + h.HALT_COOLDOWN()));

        // unhalt is halter-only (owner excluded too), and blocked until the cooldown elapses.
        vm.expectRevert(IHitOneMarket.NotHalter.selector);
        h.unhalt();

        vm.prank(halter);
        vm.expectRevert(IHitOneMarket.HaltCooldownActive.selector);
        h.unhalt();

        // re-halting mid-window extends the cooldown.
        _adv(5 minutes);
        vm.prank(halter);
        h.halt();
        assertEq(h.haltedUntil(), uint64(block.timestamp + h.HALT_COOLDOWN()));

        // past the (extended) window, halter can lift it.
        vm.warp(h.haltedUntil());
        vm.prank(halter);
        h.unhalt();
        assertFalse(h.halted());
    }

    function test_multipleHaltersAndRevoke() public {
        address halter2 = makeAddr("halter2");
        uint256 id = h.queueSetHalter(halter2, true);
        vm.warp(block.timestamp + h.roleChangeDelay() + 1);
        h.executeRoleChange(id);
        assertTrue(h.isHalter(halter2));

        // a second halter can halt independently.
        vm.prank(halter2);
        h.halt();
        assertTrue(h.halted());

        // revoke the original halter via the timelock.
        uint256 id2 = h.queueSetHalter(halter, false);
        vm.warp(block.timestamp + h.roleChangeDelay() + 1);
        h.executeRoleChange(id2);
        assertFalse(h.isHalter(halter));

        // the revoked halter can no longer act.
        vm.prank(halter);
        vm.expectRevert(IHitOneMarket.NotHalter.selector);
        h.unhalt();

        // halter2 (still a halter) lifts it — the cooldown has long elapsed.
        vm.prank(halter2);
        h.unhalt();
        assertFalse(h.halted());
    }

    // ============================================================
    // Role timelock + withdrawal delay
    // ============================================================

    function test_defaultDelays() public view {
        assertEq(h.withdrawDelay(), 6 hours);
        assertEq(h.roleChangeDelay(), 12 hours);       // 2x withdrawDelay
        assertEq(h.WITHDRAW_DELAY_MIN(), 6 hours);
        assertEq(h.WITHDRAW_DELAY_MAX(), 48 hours);
    }

    function test_setWithdrawDelayBounds() public {
        vm.expectRevert(IHitOneMarket.BadWithdrawDelay.selector);
        h.setWithdrawDelay(6 hours - 1);
        vm.expectRevert(IHitOneMarket.BadWithdrawDelay.selector);
        h.setWithdrawDelay(48 hours + 1);

        h.setWithdrawDelay(24 hours);
        assertEq(h.withdrawDelay(), 24 hours);
        assertEq(h.roleChangeDelay(), 48 hours);        // role delay tracks 2x
    }

    function test_cancelRoleChange() public {
        uint256 id = h.queueSetHalter(maker2, true);
        h.cancelRoleChange(id);
        vm.warp(block.timestamp + h.roleChangeDelay() + 1);
        vm.expectRevert(IHitOneMarket.RoleChangeUnknown.selector);
        h.executeRoleChange(id);
        assertFalse(h.isHalter(maker2));
    }

    // ============================================================
    // Per-maker pool segregation + funder gating
    // ============================================================

    function test_lossSettlesOnlyAgainstOwnMakerPool() public {
        address funder2 = makeAddr("funder2");
        _standUpMaker(maker2, funder2, 5_000_000e18);

        uint256 pool1Before = h.collateral(maker,  token);
        uint256 pool2Before = h.collateral(maker2, token);

        // bob opens a long via maker2 (counterparty = maker2's pool).
        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(bob, true, 1e18, 100, 50_000e18, 100, 0);
        o.maker = maker2;
        vm.prank(maker2);
        h.openPosition(o, 50_000e18, _sign(bobPk, o));

        // Adverse-but-not-liquidating move ($400 loss < $500 collateral), then close.
        _adv(1);
        vm.prank(maker2);
        h.setMark(token, 49_600e18);
        _adv(1);
        IHitOneMarket.Order memory co = _closeOrder(bob, true, 1e18, 49_600e18, 100, 1);
        co.maker = maker2;
        vm.prank(maker2);
        h.closePosition(co, 49_600e18, _sign(bobPk, co));

        // maker's pool is untouched; maker2's pool absorbed the $400 loss.
        assertEq(h.collateral(maker, token), pool1Before, "maker pool leaked into a maker2 trade");
        assertEq(h.collateral(maker2, token) - pool2Before, 400e18, "loss must accrue to maker2 pool");
    }

    function test_increaseRejectsForeignMaker() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0); // opened by `maker`
        // A foreign maker (maker2) tries to grow alice's position with maker. The order names
        // `maker` as counterparty, so a maker2 submission reverts WrongMaker.
        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(alice, true, 1e18, 100, 50_000e18, 100, 1);
        vm.prank(maker2);
        vm.expectRevert(IHitOneMarket.WrongMaker.selector);
        h.increasePosition(o, 50_000e18, _sign(alicePk, o));
        id;
    }

    function test_fundMakerPoolOnlyMakerFunder() public {
        vm.prank(alice);
        usdm.approve(address(h), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(IHitOneMarket.NotFunder.selector);
        h.fundMakerPool(maker, token, 1e18);
    }

    function test_withdrawFunderGated_ownerCannotCancel() public {
        vm.prank(funder);
        uint256 id = h.queueWithdrawMakerPool(maker, token, 1_000e18, funder);

        // Owner (the test contract) cannot cancel — cancel is the pool funder's, so an
        // adversarial owner can't trap the exit.
        vm.expectRevert(IHitOneMarket.NotFunder.selector);
        h.cancelWithdrawMakerPool(id);

        vm.expectRevert(IHitOneMarket.WithdrawalNotReady.selector);
        h.executeWithdrawMakerPool(id);

        vm.warp(block.timestamp + h.withdrawDelay() + 1);
        uint256 balBefore = usdm.balanceOf(funder);
        h.executeWithdrawMakerPool(id);            // permissionless once ready
        assertEq(usdm.balanceOf(funder) - balBefore, 1_000e18);
    }

    function test_funderCanCancelOwnWithdrawal() public {
        vm.prank(funder);
        uint256 id = h.queueWithdrawMakerPool(maker, token, 1_000e18, funder);
        vm.prank(funder);
        h.cancelWithdrawMakerPool(id);
        (, , , , , bool exists) = h.pendingMakerPoolWithdrawal(id);
        assertFalse(exists);
    }

    /// @notice The core isolation property: one maker's marks cannot touch another maker's book.
    function test_makerMarksDoNotAffectOtherMakersBook() public {
        address funder2 = makeAddr("funder2");
        _standUpMaker(maker2, funder2, 5_000_000e18);

        // alice opens a long against `maker` at 50k.
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);

        // maker2 crashes ITS OWN mark far below alice's liq price. alice's position (counterparty
        // `maker`) must be untouched — mark/funding state is per-(maker, token).
        _adv(1);
        vm.prank(maker2);
        h.setMark(token, 40_000e18);
        assertEq(h.marketOf(maker,  token).mark, 50_000e18);
        assertEq(h.marketOf(maker2, token).mark, 40_000e18);

        // maker2 cannot liquidate alice's position (it's on maker's book -> skipped).
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(maker2);
        vm.expectRevert(IHitOneMarket.NoneLiquidated.selector);
        h.liquidate(token, 0, ids);

        // alice closes cleanly at 50k on maker's book despite maker2's crash.
        _submitCloseLong(alicePk, 1e18, 50_000e18, 50_000e18, 1);
        assertEq(h.activePositionId(alice, maker, token), 0, "alice closed cleanly");
    }

    /// @notice With no funder set, the maker is its own funder (single-key operation).
    function test_makerIsOwnFunderByDefault() public {
        address m = makeAddr("soloMaker");
        vm.prank(m);
        h.setRiskLimits(token, _defaultRisk());
        usdm.mint(m, 1_000e18);
        vm.startPrank(m);
        usdm.approve(address(h), type(uint256).max);
        h.fundMakerPool(m, token, 1_000e18);
        assertEq(h.collateral(m, token), 1_000e18);
        uint256 wid = h.queueWithdrawMakerPool(m, token, 1_000e18, m);
        vm.stopPrank();
        vm.warp(block.timestamp + h.withdrawDelay() + 1);
        h.executeWithdrawMakerPool(wid);
        assertEq(h.collateral(m, token), 0);
    }

    /// @notice Once a distinct funder is set, the maker (hot) key loses treasury power.
    function test_funderSetLocksOutMakerHotKey() public {
        // setUp already set makerFunder[maker] = funder.
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.NotFunder.selector);
        h.queueWithdrawMakerPool(maker, token, 1e18, maker);
    }

    // ============================================================
    // Oracle band (owner-set per token)
    // ============================================================

    function test_oracleBandOwnerSetAndEnforced() public {
        // Owner sets a 1% band vs a mock feed at $50k (8-dec), 6h staleness (push heartbeat).
        MockAggregatorV3 feed = new MockAggregatorV3(8, 50_000e8, block.timestamp);
        h.setOracle(token, address(feed), 8, 6 hours, 100);
        (address f, , , uint16 dev) = h.oracleOf(token);
        assertEq(f, address(feed));
        assertEq(dev, 100);

        // A mark within 1% is accepted.
        _adv(1);
        vm.prank(maker);
        h.setMark(token, 50_400e18);              // +0.8%

        // A mark outside 1% reverts — the band is enforced on the maker's own push.
        _adv(1);
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.MarkOutOfOracleBand.selector);
        h.setMark(token, 51_000e18);              // +2%

        // A feed older than maxStale (6h) reverts.
        feed.setUpdatedAt(block.timestamp - 7 hours);
        _adv(1);
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.OracleStale.selector);
        h.setMark(token, 50_100e18);
    }

    function test_setOracleRejectsBadBand() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8, 50_000e8, block.timestamp);
        vm.expectRevert(IHitOneMarket.BadOracleConfig.selector);
        h.setOracle(token, address(feed), 8, 10 minutes, 0);        // zero band
        vm.expectRevert(IHitOneMarket.BadOracleConfig.selector);
        h.setOracle(token, address(feed), 8, 10 minutes, 10_001);   // > 100%
        vm.expectRevert(IHitOneMarket.BadOracleConfig.selector);
        h.setOracle(token, address(feed), 8, 0, 100);               // zero staleness
    }

    // ============================================================
    // H-1 regression
    // ============================================================

    function test_H1_closeConservationWithFunding() public {
        _adv(1);
        vm.prank(maker);
        h.setMarkAndRate(token, 50_000e18, 1e13);

        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);

        uint256 userBefore  = usdm.balanceOf(alice);
        uint256 makerPoolBefore = h.collateral(maker, token);

        _adv(uint64(1 hours));
        IHitOneMarket.Order memory o = _closeOrder(alice, true, 1e18, 50_000e18, 100, 1);
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        h.closePosition(o, 50_000e18, sig);

        uint256 userAfter  = usdm.balanceOf(alice);
        uint256 makerPoolAfter = h.collateral(maker, token);
        assertEq((userAfter - userBefore) + (makerPoolAfter - makerPoolBefore), 500e18,
            "H-1: funding leaked from maker pool on close");
    }

    /// @notice The funding rate is a FRACTION of the mark, not an absolute amount: funding paid =
    /// rate/(100*2**63) * mark * dt * size. This pins the magnitude so a regression to a model that
    /// ignores the mark factor fails loudly.
    function test_fundingRateIsPercentageOfMark() public {
        _adv(1);
        vm.prank(maker);
        h.setMarkAndRate(token, 50_000e18, 1e13); // ≈ 1.08e-8/sec fraction (~0.0039%/hour)

        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);

        uint256 makerPoolBefore = h.collateral(maker, token);

        _adv(uint64(1 hours));
        IHitOneMarket.Order memory o = _closeOrder(alice, true, 1e18, 50_000e18, 100, 1);
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        h.closePosition(o, 50_000e18, sig);

        // 1 BTC long, flat mark, so PnL = 0 and the long's funding flows entirely to the pool.
        uint256 expected = uint256(1e13) * 50_000e18 * uint256(1 hours) / (uint256(100) << 63);
        assertApproxEqAbs(h.collateral(maker, token) - makerPoolBefore, expected, 1e16,
            "funding must equal rate x mark x dt (not rate x dt)");
        // Sanity: the mark factor makes this ~1.95 USDM; without it (rate x dt) it'd be ~3.9e-5.
        assertGt(expected, 1.9e18);
        assertLt(expected, 2e18);
    }

    // ============================================================
    // Partial close (size down) + increase (size up)
    // ============================================================

    function _submitIncreaseLong(uint256 userPk, uint256 size, uint256 target, uint256 fillPrice, uint256 nonce)
        internal returns (uint256 id)
    {
        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(vm.addr(userPk), true, size, 100, target, 100, nonce);
        bytes memory sig = _sign(userPk, o);
        vm.prank(maker);
        id = h.increasePosition(o, fillPrice, sig);
    }

    function _submitCloseLong(uint256 userPk, uint256 size, uint256 target, uint256 fillPrice, uint256 nonce)
        internal
    {
        _adv(1);
        IHitOneMarket.Order memory o = _closeOrder(vm.addr(userPk), true, size, target, 100, nonce);
        bytes memory sig = _sign(userPk, o);
        vm.prank(maker);
        h.closePosition(o, fillPrice, sig);
    }

    function test_partialCloseSettlesProRataAndShrinks() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);

        uint256 balBefore = usdm.balanceOf(alice);
        _submitCloseLong(alicePk, 5e17, 51_000e18, 51_000e18, 1);  // close half at +$1000
        uint256 balAfter = usdm.balanceOf(alice);

        // slice PnL = $500, maker cut 5.5% = 27.5, col portion = 250 -> payout 722.5
        assertEq(balAfter - balBefore, 722.5e18, "partial payout");

        IHitOneMarket.PositionView memory p = h.positions(id);
        assertEq(p.size, 5e17, "remaining size");
        assertEq(p.col, 250e18, "remaining col");
        assertEq(p.entryPrice, 50_000e18, "entry unchanged");
        assertEq(p.notionalAtOpen, 25_000e18, "remaining notional");
        assertFalse(p.closed, "still open");
        assertEq(h.activePositionId(alice, maker, token), id, "still active");
    }

    function test_partialCloseKeepsRiskProfile() public {
        // A pro-rata close preserves the liq price: entry + funding checkpoint unchanged, and
        // col/size scale together. (liqPrice itself is now computed off-chain.)
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        IHitOneMarket.PositionView memory a = h.positions(id);
        _submitCloseLong(alicePk, 5e17, 50_000e18, 50_000e18, 1);
        IHitOneMarket.PositionView memory b = h.positions(id);
        assertEq(b.entryPrice, a.entryPrice, "entry unchanged");
        assertEq(b.fundingCheckpoint, a.fundingCheckpoint, "funding checkpoint unchanged");
        assertEq(a.col * b.size, b.col * a.size, "col/size ratio (hence liq price) preserved");
    }

    function test_partialThenFullClose() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _submitCloseLong(alicePk, 5e17, 50_000e18, 50_000e18, 1);
        _submitCloseLong(alicePk, 5e17, 50_000e18, 50_000e18, 2);  // close the rest
        assertTrue(h.positions(id).closed, "fully closed");
        assertEq(h.activePositionId(alice, maker, token), 0, "slot freed");
    }

    function test_increaseBlendsEntryAndAddsCollateral() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);

        uint256 balBefore = usdm.balanceOf(alice);
        _submitIncreaseLong(alicePk, 1e18, 60_000e18, 60_000e18, 1);  // +1 unit at $60k
        uint256 balAfter = usdm.balanceOf(alice);

        // add notional $60k at 100x -> $600 collateral debited, no fee in defaults
        assertEq(balBefore - balAfter, 600e18, "added collateral debited");

        IHitOneMarket.PositionView memory p = h.positions(id);
        assertEq(p.size, 2e18, "size grew");
        assertEq(p.leverage, 100, "leverage maintained");
        assertEq(p.entryPrice, 55_000e18, "size-weighted blended entry");
        assertEq(p.col, 1100e18, "collateral summed");
        assertEq(p.notionalAtOpen, 110_000e18, "notional summed");
    }

    function test_increasePreservesUnrealizedPnl() public {
        // Opening 1@50k then increasing 1@60k and immediately closing at 60k should realize
        // only the old size's gain ($10k), proving the rollover wasn't marked-to-fill.
        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _submitIncreaseLong(alicePk, 1e18, 60_000e18, 60_000e18, 1);

        uint256 balBefore = usdm.balanceOf(alice);
        _submitCloseLong(alicePk, 2e18, 60_000e18, 60_000e18, 2);
        uint256 balAfter = usdm.balanceOf(alice);

        // effPnl = (60k-55k)*2 units = $10k; cut 5.5% = 550; payout = col 1100 + 10000 - 550
        assertEq(balAfter - balBefore, 10_550e18, "blend preserves unrealized PnL");
    }

    function test_increaseChargesFeeOnlyOnAddedSize() public {
        // openFeeBps = 50 (0.5%)
        ParamCatalog.Risk memory r = h.makerRiskOf(maker, token);
        r.openFeeBps = 50;
        vm.prank(maker);
        h.setRiskLimits(token, r);

        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        uint256 makerPoolBefore = h.collateral(maker, token);
        _submitIncreaseLong(alicePk, 1e18, 60_000e18, 60_000e18, 1);
        uint256 makerPoolAfter = h.collateral(maker, token);

        // fee only on the added $60k notional: 60_000 * 0.5% = 300
        assertEq(makerPoolAfter - makerPoolBefore, 300e18, "fee charged on added size only");
    }

    function test_increaseRejectsSideMismatch() public {
        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(alice, false, 1e18, 100, 50_000e18, 100, 1); // short
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.BadUserSig.selector);
        h.increasePosition(o, 50_000e18, sig);
    }

    function test_increaseRejectsLeverageMismatch() public {
        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(alice, true, 1e18, 200, 50_000e18, 100, 1); // 200x
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.BadUserSig.selector);
        h.increasePosition(o, 50_000e18, sig);
    }

    function test_increaseRejectsNoPosition() public {
        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(alice, true, 1e18, 100, 50_000e18, 100, 0);
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.NoPosition.selector);
        h.increasePosition(o, 50_000e18, sig);
    }

    // ============================================================
    // Winnings-cut ramp (per-token intercept + slope -> max)
    // ============================================================

    function _setCutRamp(uint256 intercept, uint256 slopeBps, uint256 maxBps) internal {
        // Cut params are token-level structural (owner-set). Re-register with the new ramp; the
        // maker's own risk + marks are unaffected.
        ParamCatalog.Structural memory s = _structural();
        s.cutIntercept = intercept;
        s.cutSlopeBps  = slopeBps;
        s.maxCutBps    = maxBps;
        h.setToken(token, s);
    }

    function test_cutZeroBelowIntercept() public {
        _setCutRamp(1000e18, 1, 550);
        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        uint256 before = usdm.balanceOf(alice);
        _submitCloseLong(alicePk, 1e18, 50_800e18, 50_800e18, 1);  // +$800 < $1000 intercept
        // no cut: payout = col $500 + profit $800
        assertEq(usdm.balanceOf(alice) - before, 1300e18);
    }

    function test_cutRampedBetweenInterceptAndMax() public {
        _setCutRamp(1000e18, 1, 550);
        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        uint256 before = usdm.balanceOf(alice);
        _submitCloseLong(alicePk, 1e18, 51_200e18, 51_200e18, 1);  // +$1200
        // excess $200 * 1bps/$ = 200bps; cut = 1200 * 2% = 24; payout = 500 + 1200 - 24
        assertEq(usdm.balanceOf(alice) - before, 1676e18);
    }

    function test_cutSaturatesAtMax() public {
        _setCutRamp(1000e18, 1, 550);
        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        uint256 before = usdm.balanceOf(alice);
        _submitCloseLong(alicePk, 1e18, 55_000e18, 55_000e18, 1);  // +$5000
        // excess $4000 -> 4000bps capped at 550; cut = 5000 * 5.5% = 275; payout = 500 + 5000 - 275
        assertEq(usdm.balanceOf(alice) - before, 5225e18);
    }

    // ============================================================
    // Integration — multi-actor end-to-end flows
    // ============================================================

    /// @notice Two makers, two users, full lifecycle across independent books; USDM is conserved
    /// (nothing minted mid-scenario), each book's funding stays local, and both books end flat.
    function test_integration_multiMakerLifecycleConservation() public {
        address funder2 = makeAddr("funder2");
        _standUpMaker(maker2, funder2, 5_000_000e18);

        // Snapshot total USDM across every actor + the contract (conserved from here on).
        address[5] memory actors = [alice, bob, funder, funder2, address(h)];
        uint256 totalBefore;
        for (uint256 i; i < actors.length; i++) totalBefore += usdm.balanceOf(actors[i]);

        // alice longs on maker's book; bob longs on maker2's book (separate counterparties).
        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _adv(1);
        IHitOneMarket.Order memory bo = _openOrder(bob, true, 1e18, 100, 50_000e18, 100, 0);
        bo.maker = maker2;
        vm.prank(maker2);
        h.openPosition(bo, 50_000e18, _sign(bobPk, bo));

        // maker turns on funding and time passes; maker2's book is unaffected.
        _adv(1);
        vm.prank(maker);
        h.setMarkAndRate(token, 50_000e18, 1e13);
        _adv(uint64(1 hours));

        // alice grows her position, then maker's mark rises and she exits in two slices.
        _submitIncreaseLong(alicePk, 1e18, 50_000e18, 50_000e18, 1);   // size now 2
        _adv(1);
        vm.prank(maker);
        h.setMark(token, 51_000e18);
        _submitCloseLong(alicePk, 1e18, 51_000e18, 51_000e18, 2);      // partial (1 of 2)
        _submitCloseLong(alicePk, 1e18, 51_000e18, 51_000e18, 3);      // remainder

        // bob exits flat on maker2's book.
        _adv(1);
        IHitOneMarket.Order memory bc = _closeOrder(bob, true, 1e18, 50_000e18, 100, 1);
        bc.maker = maker2;
        vm.prank(maker2);
        h.closePosition(bc, 50_000e18, _sign(bobPk, bc));

        uint256 totalAfter;
        for (uint256 i; i < actors.length; i++) totalAfter += usdm.balanceOf(actors[i]);
        assertEq(totalAfter, totalBefore, "USDM conserved across the full multi-maker lifecycle");

        // Both books flat; OI unwound on each.
        assertEq(h.activePositionId(alice, maker,  token), 0);
        assertEq(h.activePositionId(bob,   maker2, token), 0);
        assertEq(h.marketOf(maker,  token).openInterestLong, 0);
        assertEq(h.marketOf(maker2, token).openInterestLong, 0);
    }

    /// @notice Treasury end-to-end: maker appoints a cold funder, the hot maker key loses withdraw
    /// power, the cold funder rotates itself and exits via the timelock, and the owner can't cancel.
    function test_integration_funderRotationAndTimelockedExit() public {
        address cold  = makeAddr("coldFunder");
        address cold2 = makeAddr("coldFunder2");

        // setUp made `funder` the maker's funder. Rotate to a new cold key (only the funder may).
        vm.prank(maker);
        vm.expectRevert(IHitOneMarket.NotFunder.selector);   // hot maker key can't rotate once set
        h.setMakerFunder(maker, cold);
        vm.prank(funder);
        h.setMakerFunder(maker, cold);

        // Old funder is now powerless; the new cold key can rotate again.
        vm.prank(funder);
        vm.expectRevert(IHitOneMarket.NotFunder.selector);
        h.queueWithdrawMakerPool(maker, token, 1e18, funder);
        vm.prank(cold);
        h.setMakerFunder(maker, cold2);

        // cold2 queues a withdrawal; owner cannot cancel it; it executes after the delay.
        vm.prank(cold2);
        uint256 wid = h.queueWithdrawMakerPool(maker, token, 1_000_000e18, cold2);
        vm.expectRevert(IHitOneMarket.NotFunder.selector);   // owner (this) can't trap the exit
        h.cancelWithdrawMakerPool(wid);
        vm.expectRevert(IHitOneMarket.WithdrawalNotReady.selector);
        h.executeWithdrawMakerPool(wid);

        vm.warp(block.timestamp + h.withdrawDelay() + 1);
        h.executeWithdrawMakerPool(wid);
        assertEq(usdm.balanceOf(cold2), 1_000_000e18, "cold funder received the withdrawal");
        assertEq(h.collateral(maker, token), 4_000_000e18, "pool debited");
    }
}
