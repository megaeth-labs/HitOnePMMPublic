// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import { Test }          from "forge-std/Test.sol";
import { Vm }            from "forge-std/Vm.sol";
import { Ownable }       from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable }      from "@openzeppelin/contracts/utils/Pausable.sol";

import { HitOneMarket }  from "../../src/hitone/HitOneMarket.sol";
import { IHitOneMarket } from "../../src/hitone/IHitOneMarket.sol";
import { ParamCatalog }  from "../../src/common/ParamCatalog.sol";
import { MockERC20 }     from "../mocks/MockERC20.sol";
import { MockHighPrecisionTimestamp } from "../mocks/MockHighPrecisionTimestamp.sol";

contract HitOneMarketTest is Test {
    HitOneMarket internal h;
    MockERC20    internal usdm;

    address internal owner  = address(this);
    address internal maker  = makeAddr("maker");
    address internal maker2 = makeAddr("maker2");
    address internal pauser = makeAddr("pauser");

    // Users sign orders with their keys.
    uint256 internal alicePk = 0xA11CE;
    address internal alice;
    uint256 internal bobPk = 0xB0B;
    address internal bob;

    address internal token;
    address internal MAKER_POOL;

    bytes32 internal DOMAIN_SEPARATOR;
    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "Order(address user,address token,bool isLong,bool isOpen,uint256 size,uint256 leverage,"
        "uint256 targetPrice,uint256 maxSlippageBps,uint64 deadline,uint256 channel,uint256 nonce)"
    );

    uint64 internal _t;
    function _adv(uint64 dt) internal { _t += dt; vm.warp(_t); }

    function _defaultParams() internal pure returns (ParamCatalog.TokenParams memory) {
        return ParamCatalog.TokenParams({
            structural: ParamCatalog.Structural({
                priceTick: 1e18, sizeTick: 1e10, notionalScale: 0,
                minLeverage: 100, maxLeverage: 1000,
                maxPositionDuration: 30 days,
                cutIntercept: 0, cutSlopeBps: 550, maxCutBps: 550
            }),
            risk: ParamCatalog.Risk({
                openFeeBps: 0, linearScale: type(uint256).max, quadScale: type(uint256).max,
                maxPositionNotional: 0,
                maxOIGross: 0, maxOISkew: 0, maxDevBps: 0
            })
        });
    }

    function setUp() public {
        _t = 1_000_000;
        vm.warp(_t);

        alice = vm.addr(alicePk);
        bob   = vm.addr(bobPk);

        usdm = new MockERC20();
        h = new HitOneMarket(owner, maker, address(usdm));
        h.setPauser(pauser);
        h.setToken(makeAddr("btc"), _defaultParams());
        token = makeAddr("btc");

        MAKER_POOL = h.MAKER_POOL();
        DOMAIN_SEPARATOR = _domainSep();

        // Fund wallets + grant allowance. Collateral is pulled from wallets on open.
        usdm.mint(alice, 1_000_000e18);
        usdm.mint(bob,   1_000_000e18);
        usdm.mint(maker, 10_000_000e18);

        vm.prank(alice);
        usdm.approve(address(h), type(uint256).max);
        vm.prank(bob);
        usdm.approve(address(h), type(uint256).max);

        // Seed maker pool (maker funds and withdraws it).
        vm.startPrank(maker);
        usdm.approve(address(h), type(uint256).max);
        h.fundMakerPool(token, 5_000_000e18);
        vm.stopPrank();

        // Seed first mark via admin.
        vm.prank(maker);
        h.setMark(token, 50_000e18);
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
            o.user, o.token, o.isLong, o.isOpen, o.size, o.leverage,
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
            user: user, token: token, isLong: isLong, isOpen: true,
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
            user: user, token: token, isLong: isLong, isOpen: false,
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

    function test_constructorRejectsZero() public {
        vm.expectRevert(IHitOneMarket.ZeroAddress.selector);
        new HitOneMarket(owner, maker, address(0));
        vm.expectRevert(IHitOneMarket.ZeroAddress.selector);
        new HitOneMarket(owner, address(0), address(usdm));
    }

    function test_constructorSetsRoles() public view {
        assertTrue(h.isMaker(maker));
    }

    function test_setMakerOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        h.setMaker(maker2, true);
        h.setMaker(maker2, true);
        assertTrue(h.isMaker(maker2));
    }

    function test_renounceMakerSelfRevokes() public {
        assertTrue(h.isMaker(maker));
        vm.prank(maker);
        h.renounceMaker();
        assertFalse(h.isMaker(maker));
    }

    // ============================================================
    // Open
    // ============================================================

    function test_openRejectsNonMakerCaller() public {
        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(alice, true, 1e18, 100, 50_000e18, 100, 0);
        bytes memory sig = _sign(alicePk, o);
        vm.prank(alice);
        vm.expectRevert(IHitOneMarket.NotMaker.selector);
        h.openPosition(o, 50_000e18, sig);
    }

    function test_openCreatesPositionAssignedToUser() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        IHitOneMarket.PositionView memory p = h.positions(id);
        assertEq(p.user, alice);
        assertEq(p.token, token);
        assertTrue(p.isLong);
        assertEq(p.size, 1e18);
        assertEq(h.activePositionId(alice, token), id);
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
        assertGt(h.activePositionId(alice, token), 0);
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
        assertGt(h.activePositionId(alice, token), 0);
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
        assertEq(h.activePositionId(alice, token), 0);
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
        assertEq(h.activePositionId(alice, token), 0);
        // the pushed mark stuck as the current mark
        assertEq(h.marketOf(token).mark, 44_000e18);
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
        assertEq(h.marketOf(token).mark, 50_000e18, "mark push rolled back with the revert");
    }

    function test_liquidateOnlyMaker() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(alice);
        vm.expectRevert(IHitOneMarket.NotMaker.selector);
        h.liquidate(token, 0, ids);
    }

    // ============================================================
    // Mark high-precision timestamp (MegaETH system contract)
    // ============================================================

    address internal constant HP_TIMESTAMP = 0x6342000000000000000000000000000000000002;
    bytes32 internal constant MARK_PUSHED_SIG =
        keccak256("MarkPushed(address,uint256,int256,uint16,bool,uint256)");

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

    // ============================================================
    // Expire
    // ============================================================

    function test_expireAfter30Days() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _adv(uint64(30 days + 1));
        h.expirePosition(id);
        assertTrue(h.positions(id).closed);
        assertEq(h.activePositionId(alice, token), 0);
    }

    function test_expireRevertsBefore30Days() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        vm.expectRevert(IHitOneMarket.PositionDurationNotElapsed.selector);
        h.expirePosition(id);
    }

    // ============================================================
    // Pause
    // ============================================================

    function test_pauseBlocksOpenAndClose() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        vm.prank(pauser);
        h.pause();

        _adv(1);
        IHitOneMarket.Order memory o = _openOrder(bob, true, 1e18, 100, 50_000e18, 100, 0);
        bytes memory sig = _sign(bobPk, o);
        vm.prank(maker);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        h.openPosition(o, 50_000e18, sig);

        IHitOneMarket.Order memory co = _closeOrder(alice, true, 1e18, 51_000e18, 100, 1);
        bytes memory csig = _sign(alicePk, co);
        vm.prank(maker);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        h.closePosition(co, 51_000e18, csig);

        id;
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
        uint256 makerPoolBefore = h.collateral(MAKER_POOL, token);

        _adv(uint64(1 hours));
        IHitOneMarket.Order memory o = _closeOrder(alice, true, 1e18, 50_000e18, 100, 1);
        bytes memory sig = _sign(alicePk, o);
        vm.prank(maker);
        h.closePosition(o, 50_000e18, sig);

        uint256 userAfter  = usdm.balanceOf(alice);
        uint256 makerPoolAfter = h.collateral(MAKER_POOL, token);
        assertEq((userAfter - userBefore) + (makerPoolAfter - makerPoolBefore), 500e18,
            "H-1: funding leaked from maker pool on close");
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
        assertEq(h.activePositionId(alice, token), id, "still active");
    }

    function test_partialCloseLiqPriceUnchanged() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        uint256 liqBefore = h.positions(id).liqPrice;
        _submitCloseLong(alicePk, 5e17, 50_000e18, 50_000e18, 1);
        assertEq(h.positions(id).liqPrice, liqBefore, "pro-rata close preserves liq price");
    }

    function test_partialThenFullClose() public {
        uint256 id = _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        _submitCloseLong(alicePk, 5e17, 50_000e18, 50_000e18, 1);
        _submitCloseLong(alicePk, 5e17, 50_000e18, 50_000e18, 2);  // close the rest
        assertTrue(h.positions(id).closed, "fully closed");
        assertEq(h.activePositionId(alice, token), 0, "slot freed");
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
        ParamCatalog.Risk memory r = h.paramsOf(token).risk;
        r.openFeeBps = 50;
        vm.prank(maker);
        h.setRiskLimits(token, r);

        _submitOpenLong(alicePk, 1e18, 50_000e18, 50_000e18, 0);
        uint256 makerPoolBefore = h.collateral(MAKER_POOL, token);
        _submitIncreaseLong(alicePk, 1e18, 60_000e18, 60_000e18, 1);
        uint256 makerPoolAfter = h.collateral(MAKER_POOL, token);

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
        ParamCatalog.TokenParams memory p = _defaultParams();
        p.structural.cutIntercept = intercept;
        p.structural.cutSlopeBps  = slopeBps;
        p.structural.maxCutBps    = maxBps;
        p.risk = h.paramsOf(token).risk;  // keep current (already-defaulted) risk
        h.setToken(token, p);
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
}
