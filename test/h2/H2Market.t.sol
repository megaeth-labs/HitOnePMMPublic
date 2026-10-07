// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test, Vm } from "forge-std/Test.sol";

import { H2Market }  from "../../src/h2/H2Market.sol";
import { H2Oracle }  from "../../src/h2/H2Oracle.sol";
import { IH2Market } from "../../src/h2/IH2Market.sol";
import { IH2Oracle } from "../../src/h2/IH2Oracle.sol";
import { BuilderRegistry }  from "../../src/h2/BuilderRegistry.sol";
import { IBuilderRegistry } from "../../src/h2/IBuilderRegistry.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockAggregatorV3 } from "../mocks/MockAggregatorV3.sol";

contract H2MarketTest is Test {
    H2MarketHarness internal h;
    H2Oracle  internal oracle;
    BuilderRegistry internal reg;       // per-market builder eligibility (native-ETH stake)
    MockERC20 internal usdm;
    MockAggregatorV3 internal ref;      // primary feed's reference band
    MockAggregatorV3 internal fallbackFeed;

    address internal op     = makeAddr("operator"); // feed operator + market creator
    address internal keeper = makeAddr("keeper");
    address internal carl   = makeAddr("carl");     // funder

    uint256 internal alicePk = 0xA11CE;
    address internal alice;
    uint256 internal bobPk = 0xB0B;
    address internal bob;

    address internal token;
    uint256 internal feedId;
    uint256 internal mkt;

    uint64  internal constant RATE_CAP = 1_500_000_000_000_000;
    uint32  internal constant RAKE_PPM = 150_000; // 15% oracle rake // passes coupled ceiling
    uint256 internal constant TERM = 30 days;

    bytes32 internal DOMAIN_SEPARATOR;
    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "Order(address user,uint256 marketId,bool isLong,bool isOpen,uint256 size,uint256 leverage,"
        "uint256 targetPrice,uint256 maxSlippageBps,uint64 deadline,uint256 channel,uint256 nonce,"
        "address builder,uint256 builderFeePpm)"
    );

    uint256 internal constant MIN_BUILDER_STAKE = 1e18;

    uint256 internal _t;
    // Advancing time also advances the block number: a position may be adjusted at most once per
    // block (SameBlockAction), so consecutive open/adjust/close steps must land in distinct blocks
    // — which is what happens on-chain as wall-clock time passes.
    function _adv(uint256 dt) internal { _t += dt; vm.warp(_t); vm.roll(block.number + 1); }

    /// @dev Back a market's share vault with `amount` of USDM from carl (the sole LP).
    function _seedTreasury(uint256 marketId, uint256 amount) internal {
        usdm.mint(carl, amount);
        vm.startPrank(carl);
        usdm.approve(address(h), type(uint256).max);
        h.deposit(marketId, amount);
        vm.stopPrank();
    }

    /// @dev A flat open+close round trip that banks fees into the vault (via `_credit`).
    function _roundTrip() internal {
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(1);
        IH2Market.Order memory c = _order(alicePk, true, false, 1e18, 0, 49_800e18, 200, 1);
        _pushOrder(50_000e18, c, _sign(alicePk, c), 0);
        require(h.positions(id).closed, "round trip did not close");
    }

    function _fees() internal pure returns (IH2Market.FeeParams memory) {
        return IH2Market.FeeParams({
            openFlatPpm: 500, openLinearScale: 0, openQuadScale: 0,   // 5 bps open
            closeFlatPpm: 500, closeLinearScale: 0, closeQuadScale: 0, // 5 bps close (> 100ppm dev)
            cutInterceptPpm: 100_000, cutSlopePpm: 100_000, maxCutPpm: 55_000,
            maxBuilderFeePpm: 100_000 // builders may take ≤ 10% of fees+cut
        });
    }

    /// @dev Default: no derived spread (zero coefficients). Spread tests use `_spreadK`.
    function _spread() internal pure returns (IH2Market.SpreadParams memory) {
        return IH2Market.SpreadParams({ openVolK: 0, openSkewK: 0, closeVolK: 0, closeSkewK: 0 });
    }
    function _spreadK(uint32 openVolK, uint32 openSkewK, uint32 closeVolK, uint32 closeSkewK)
        internal pure returns (IH2Market.SpreadParams memory)
    {
        return IH2Market.SpreadParams({
            openVolK: openVolK, openSkewK: openSkewK, closeVolK: closeVolK, closeSkewK: closeSkewK
        });
    }
    function _risk(uint32 liqWidthPpm) internal pure returns (IH2Market.RiskParams memory) {
        return IH2Market.RiskParams({
            priceTick: 1e18, sizeTick: 1e10, notionalScale: 0,
            minLeverage: 100, maxLeverage: 1000,
            maxPositionDuration: 30 days,
            maxPositionNotional: 200_000e18,
            maxOIGross: 0, maxOISkew: 0,
            liqWidthPpm: liqWidthPpm,
            fundingRateCapPerSec: RATE_CAP,
            maxSpreadPpm: 5_000, // ≤ 0.5% operator spread
            unstakeSecs: uint32(TERM),
            staleSpreadK: 6, // ppm per √ms ≈ 2σ for BTC (≈356 ppm at the 4s sentinel)
            minAdjustGapBlocks: 1
        });
    }
    function _oracleParams() internal view returns (IH2Market.OracleParams memory) {
        return IH2Market.OracleParams({
            primaryFeedId: uint64(feedId),
            primaryStaleSecs: 300,
            fallbackFeed: address(fallbackFeed),
            fallbackDecimals: 8,
            fallbackMaxAge: 60,
            fbOpenSpreadPpm: 2_000, fbCloseSpreadPpm: 2_000, fbLiqSpreadPpm: 1_000,
            maxDeviationPpm: 100 // 1 bp; open+close flat = 1000 ppm ≥ this
        });
    }

    function setUp() public {
        _t = 1_786_986_000;
        vm.warp(_t);
        alice = vm.addr(alicePk);
        bob   = vm.addr(bobPk);

        usdm  = new MockERC20();
        oracle = new H2Oracle();
        ref = new MockAggregatorV3(8, 50_000e8, block.timestamp);
        fallbackFeed = new MockAggregatorV3(8, 50_000e8, block.timestamp);
        h = new H2MarketHarness(address(usdm), address(oracle));
        reg = new BuilderRegistry(address(0), MIN_BUILDER_STAKE); // native-ETH stake
        token = makeAddr("btc");

        vm.prank(op);
        feedId = oracle.createFeed(op, 1e18, RATE_CAP, RAKE_PPM, address(ref), 8, 100_000, 1 hours);

        vm.prank(op);
        // Open-side vol + skew coefficients so a pushed vol/skew produces a derived spread (closes
        // stay 0). volK=2000 ⇒ at vol=10_000 (1%) the base open spread is 2000 ppm; skewK=1000 ⇒
        // at skew=10_000 (1%) the asymmetry is ±1000 ppm. Every other test pushes vol=skew=0, so
        // their derived spread is 0 regardless.
        mkt = h.createMarket(token, _fees(), _risk(0), _oracleParams(), _spreadK(2_000, 1_000, 0, 0), address(reg));

        // Open deposits, back the pool with lender capital; publish an initial mark.
        _seedTreasury(mkt, 5_000_000e18);
        _pushMark(50_000e18, 0, 0, 0);

        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("H2Market")),
            keccak256(bytes("1")),
            block.chainid,
            address(h)
        ));

        usdm.mint(alice, 1_000_000e18);
        usdm.mint(bob,   1_000_000e18);
        vm.prank(alice); usdm.approve(address(h), type(uint256).max);
        vm.prank(bob);   usdm.approve(address(h), type(uint256).max);
    }

    // ---- helpers ----

    function _refresh(uint256 px1e18) internal {
        ref.setAnswer(int256(px1e18 / 1e10));
        ref.setUpdatedAt(block.timestamp);
        fallbackFeed.setAnswer(int256(px1e18 / 1e10));
        fallbackFeed.setUpdatedAt(block.timestamp);
    }

    /// @dev Plain operator mark push (no orders).
    function _pushMark(uint256 mark, int64 rl, int64 rs, uint32 vol, int32 skew) internal {
        _refresh(mark);
        IH2Oracle.Call[] memory none = new IH2Oracle.Call[](0);
        vm.prank(op);
        oracle.pushWithParams(feedId, mark, rl, rs, vol, skew, none);
    }

    function _sign(uint256 pk, IH2Market.Order memory o) internal view returns (bytes memory) {
        bytes32 sh = keccak256(abi.encode(
            ORDER_TYPEHASH, o.user, o.marketId, o.isLong, o.isOpen, o.size, o.leverage,
            o.targetPrice, o.maxSlippageBps, o.deadline, o.channel, o.nonce, o.builder, o.builderFeePpm));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, sh)));
        return abi.encodePacked(r, s, v);
    }

    function _order(uint256 pk, bool isLong, bool isOpen, uint256 size, uint256 lev,
                    uint256 target, uint256 slip, uint256 nonce)
        internal view returns (IH2Market.Order memory)
    {
        return _orderB(pk, isLong, isOpen, size, lev, target, slip, nonce, address(0), 0);
    }

    /// @dev Order with an explicit builder + rate (defaults route through `_order`).
    function _orderB(uint256 pk, bool isLong, bool isOpen, uint256 size, uint256 lev,
                     uint256 target, uint256 slip, uint256 nonce, address builder, uint256 builderFeePpm)
        internal view returns (IH2Market.Order memory)
    {
        return IH2Market.Order({
            user: vm.addr(pk), marketId: mkt, isLong: isLong, isOpen: isOpen,
            size: size, leverage: lev, targetPrice: target, maxSlippageBps: slip,
            deadline: uint64(block.timestamp + 1 hours), channel: 0, nonce: nonce,
            builder: builder, builderFeePpm: builderFeePpm
        });
    }

    /// @dev Operator commits a mark and attaches one order — the primary pull path.
    function _pushOrder(uint256 mark, IH2Market.Order memory o, bytes memory sig, uint32 vol, int32 skew)
        internal
    {
        _refresh(mark);
        bytes memory payload = abi.encode(o, sig);
        bytes memory data = abi.encode(mkt, uint8(IH2Market.ActionKind.Order_), payload);
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h), data: data });
        vm.prank(op);
        oracle.pushWithParams(feedId, mark, 0, 0, vol, skew, calls);
    }

    // Skew-defaulting overloads: existing call sites pass a single `vol` (the old spread slot);
    // with the default market's zero spread coefficients the derived spread is 0 regardless.
    function _pushMark(uint256 mark, int64 rl, int64 rs, uint32 vol) internal {
        _pushMark(mark, rl, rs, vol, int32(0));
    }
    function _pushOrder(uint256 mark, IH2Market.Order memory o, bytes memory sig, uint32 vol) internal {
        _pushOrder(mark, o, sig, vol, int32(0));
    }

    function _pushLiquidate(uint256 mark, uint256[] memory ids) internal {
        _refresh(mark);
        bytes memory data = abi.encode(mkt, uint8(IH2Market.ActionKind.Liquidate), abi.encode(ids));
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h), data: data });
        vm.prank(op);
        oracle.pushAndCall(feedId, mark, calls);
    }

    function _openLong(uint256 pk, uint256 size, uint256 lev, uint256 mark, uint256 nonce)
        internal returns (uint256 id)
    {
        _adv(1);
        IH2Market.Order memory o = _order(pk, true, true, size, lev, mark, 200, nonce);
        _pushOrder(mark, o, _sign(pk, o), 0);
        id = h.activePositionId(vm.addr(pk), mkt);
    }

    // ============================================================
    // market creation + validation
    // ============================================================

    function test_createMarketFreezesAndDerives() public view {
        IH2Market.RiskParams memory r = h.riskParamsOf(mkt);
        assertEq(r.notionalScale, 1e10);
        assertEq(uint256(r.maxOIGross), type(uint128).max);
        assertEq(h.creatorOf(mkt), op);
        assertEq(h.marketOf(mkt).mark, 50_000e18);
    }

    function test_createRejectsTickMismatch() public {
        IH2Market.RiskParams memory r = _risk(0);
        r.priceTick = 1e17; // feed tick is 1e18
        vm.prank(op);
        vm.expectRevert(IH2Market.BadMarketParams.selector);
        h.createMarket(token, _fees(), r, _oracleParams(), _spread(), address(reg));
    }

    // ============================================================
    // primary path: open / close with formulaic fills
    // ============================================================

    function test_openViaPullPathAppliesSpreadAndFee() public {
        _adv(1);
        // Operator publishes vol = 10_000 (1%); the market's openVolK=2000 derives a 2000 ppm
        // (0.2%) open spread. Long open pays up: 50_000 × 1.002 = 50_100.
        IH2Market.Order memory o = _order(alicePk, true, true, 1e18, 100, 50_200e18, 200, 0);
        _pushOrder(50_000e18, o, _sign(alicePk, o), uint32(10_000));
        uint256 id = h.activePositionId(alice, mkt);
        assertEq(h.positions(id).entryPrice, 50_100e18);
        // collateral = 500e18 notional/lev minus 5bps open fee on 50_100 notional.
        assertApproxEqAbs(h.positions(id).col, 501e18 - (uint256(50_100e18) * 500 / 1_000_000), 1e12);
    }

    function test_onMarkOnlyFromOracle() public {
        _adv(1);
        IH2Market.Order memory o = _order(alicePk, true, true, 1e18, 100, 50_000e18, 200, 0);
        bytes memory data = abi.encode(mkt, uint8(IH2Market.ActionKind.Order_), abi.encode(o, _sign(alicePk, o)));
        vm.prank(op); // not the oracle
        vm.expectRevert(IH2Market.NotOracle.selector);
        h.onMark(feedId, data);
    }

    function test_openCloseRoundTrip() public {
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        uint256 balBefore = usdm.balanceOf(alice);
        // Close at a higher mark; long close receives down 0.2%? spread 0 here.
        _adv(1);
        IH2Market.Order memory o = _order(alicePk, true, false, 1e18, 0, 50_500e18, 200, 1);
        _pushOrder(50_500e18, o, _sign(alicePk, o), 0);
        assertTrue(h.positions(id).closed);
        assertGt(usdm.balanceOf(alice), balBefore); // profited
        assertEq(h.activePositionId(alice, mkt), 0);
    }

    function test_closeRejectsFlippedSide() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(1);
        IH2Market.Order memory o = _order(alicePk, false, false, 1e18, 0, 50_000e18, 200, 1);
        bytes memory sig = _sign(alicePk, o);
        _refresh(50_000e18);
        bytes memory data = abi.encode(mkt, uint8(IH2Market.ActionKind.Order_), abi.encode(o, sig));
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h), data: data });
        vm.prank(op);
        // The callback reverts BadUserSig internally, isolated as CallFailed — the mark commits.
        vm.expectEmit(true, false, false, false);
        emit IH2Oracle.CallFailed(feedId, 0, address(h));
        oracle.pushAndCall(feedId, 50_000e18, calls);
        assertFalse(h.positions(h.activePositionId(alice, mkt)).closed);
    }

    // ============================================================
    // deviation gate
    // ============================================================

    function test_deviationGateBlocksOnDisagreement() public {
        _adv(1);
        IH2Market.Order memory o = _order(alicePk, true, true, 1e18, 100, 50_200e18, 200, 0);
        bytes memory sig = _sign(alicePk, o);
        // Primary 50_000, fallback 50_100 → 20 bp apart > 1 bp gate.
        ref.setAnswer(50_000e8); ref.setUpdatedAt(block.timestamp);
        fallbackFeed.setAnswer(50_100e8); fallbackFeed.setUpdatedAt(block.timestamp);
        bytes memory data = abi.encode(mkt, uint8(IH2Market.ActionKind.Order_), abi.encode(o, sig));
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h), data: data });
        vm.prank(op);
        vm.expectEmit(true, false, false, false);
        emit IH2Oracle.CallFailed(feedId, 0, address(h)); // DeviationGate inside, isolated
        oracle.pushAndCall(feedId, 50_000e18, calls);
        assertEq(h.activePositionId(alice, mkt), 0);
    }

    function test_marksRecordDuringGatedWindow() public {
        // A disagreeing fallback blocks actions but must NOT block publication.
        _adv(1);
        fallbackFeed.setAnswer(51_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        ref.setAnswer(50_000e8); ref.setUpdatedAt(block.timestamp);
        vm.prank(op);
        oracle.push(feedId, 50_000e18); // succeeds — the ring stays alive
        assertEq(oracle.feedOf(feedId).mark, 50_000e18);
    }

    // ============================================================
    // liquidation: widened threshold + walk-back
    // ============================================================

    function test_liqWidthTriggersEarly() public {
        // Market with a 1% maintenance width.
        vm.prank(op);
        uint256 wmkt = h.createMarket(token, _fees(), _risk(10_000), _oracleParams(), _spread(), address(reg));
        _seedTreasury(wmkt, 1_000_000e18);
        _adv(1);
        _pushMark(50_000e18, 0, 0, 0);

        // open a 1000x long on wmkt (col ~50e18 on 50_000 notional)
        _adv(1);
        IH2Market.Order memory o = IH2Market.Order({
            user: alice, marketId: wmkt, isLong: true, isOpen: true, size: 1e18, leverage: 1000,
            targetPrice: 50_100e18, maxSlippageBps: 200, deadline: uint64(block.timestamp + 1 hours),
            channel: 0, nonce: 0, builder: address(0), builderFeePpm: 0 });
        bytes memory sig = _sign(alicePk, o);
        _refresh(50_000e18);
        bytes memory data = abi.encode(wmkt, uint8(IH2Market.ActionKind.Order_), abi.encode(o, sig));
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h), data: data });
        vm.prank(op); oracle.pushAndCall(feedId, 50_000e18, calls);
        uint256 id = h.activePositionId(alice, wmkt);
        assertFalse(h.positions(id).closed);

        // A dip that leaves the position solvent but inside the 1% maintenance width wipes it.
        _adv(1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        _refresh(49_951e18);
        bytes memory ld = abi.encode(wmkt, uint8(IH2Market.ActionKind.Liquidate), abi.encode(ids));
        IH2Oracle.Call[] memory lc = new IH2Oracle.Call[](1);
        lc[0] = IH2Oracle.Call({ target: address(h), data: ld });
        vm.prank(op); oracle.pushAndCall(feedId, 49_951e18, lc);
        assertTrue(h.positions(id).closed);
    }

    function test_expireForceCloses() public {
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(30 days + 1);
        _pushMark(50_000e18, 0, 0, 0); // keep the feed fresh
        vm.prank(keeper);
        h.expirePosition(id);
        assertTrue(h.positions(id).closed);
    }

    // ============================================================
    // fallback path
    // ============================================================

    // ============================================================
    // self-service: executeAtMark
    // ============================================================

    function test_executeAtMarkOpensAgainstStaleMark() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0); // seed nothing special; just advance clock
        // Bob self-service opens 2s after the last mark, no operator involvement.
        _adv(2);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o = _order(bobPk, true, true, 1e18, 100, 50_100e18, 200, 0);
        vm.prank(keeper);
        uint256 id = h.executeAtMark(o, _sign(bobPk, o));
        assertEq(h.positions(id).user, bob);
        // entry = mark 50_000 up by (feed spread 0 + staleSpread 6·√2000ms≈268 ppm) → ~50_013,
        // ceil-to-tick ($1) → 50_014.
        assertGe(h.positions(id).entryPrice, 50_013e18);
        assertLe(h.positions(id).entryPrice, 50_015e18);
    }

    function test_executeAtMarkRejectsWhenMarkTooStale() public {
        _adv(5); // last mark now 5s old > 4.095s sentinel gap
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o = _order(alicePk, true, true, 1e18, 100, 50_200e18, 200, 0);
        vm.expectRevert(IH2Market.MarkTooStale.selector);
        h.executeAtMark(o, _sign(alicePk, o));
    }

    function test_executeAtMarkRejectsWhenFallbackStale() public {
        _adv(2);
        // primary mark 2s old (usable) but fallback not refreshed → no anchor.
        fallbackFeed.setUpdatedAt(block.timestamp - 100);
        IH2Market.Order memory o = _order(alicePk, true, true, 1e18, 100, 50_200e18, 200, 0);
        vm.expectRevert(IH2Market.OracleTooOld.selector);
        h.executeAtMark(o, _sign(alicePk, o));
    }

    function test_executeAtMarkRejectsOnDeviation() public {
        _adv(2);
        // fresh fallback but far from the stale primary mark → gate.
        fallbackFeed.setAnswer(51_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o = _order(alicePk, true, true, 1e18, 100, 50_200e18, 200, 0);
        vm.expectRevert(IH2Market.DeviationGate.selector);
        h.executeAtMark(o, _sign(alicePk, o));
    }

    function test_executeAtMarkDisabledWhenKZero() public {
        IH2Market.RiskParams memory r = _risk(0);
        r.staleSpreadK = 0;
        vm.prank(op);
        uint256 dmkt = h.createMarket(token, _fees(), r, _oracleParams(), _spread(), address(reg));
        _seedTreasury(dmkt, 1_000_000e18);
        _adv(1);
        _refresh(50_000e18);
        vm.prank(op);
        oracle.push(feedId, 50_000e18);
        _adv(2);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o = IH2Market.Order({
            user: alice, marketId: dmkt, isLong: true, isOpen: true, size: 1e18, leverage: 100,
            targetPrice: 50_200e18, maxSlippageBps: 200, deadline: uint64(block.timestamp + 1 hours),
            channel: 0, nonce: 0, builder: address(0), builderFeePpm: 0 });
        vm.expectRevert(IH2Market.SelfServiceDisabled.selector);
        h.executeAtMark(o, _sign(alicePk, o));
    }

    function test_staleSpreadGrowsWithAge() public {
        // Bob opens at 1s, Alice-equivalent (via bob nonce) can't reuse; use two markets or
        // compare entry prices at two ages on fresh positions in fresh markets.
        _adv(1);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o1 = _order(bobPk, true, true, 1e18, 100, 50_100e18, 200, 0);
        vm.prank(keeper);
        uint256 id1 = h.executeAtMark(o1, _sign(bobPk, o1));
        uint256 e1 = h.positions(id1).entryPrice;

        // A second market, mark refreshed, then aged 4s (near the sentinel) → larger spread.
        vm.prank(op);
        uint256 m2 = h.createMarket(token, _fees(), _risk(0), _oracleParams(), _spread(), address(reg));
        _seedTreasury(m2, 1_000_000e18);
        _adv(1); _refresh(50_000e18); vm.prank(op); oracle.push(feedId, 50_000e18);
        _adv(4);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o2 = IH2Market.Order({
            user: alice, marketId: m2, isLong: true, isOpen: true, size: 1e18, leverage: 100,
            targetPrice: 50_300e18, maxSlippageBps: 200, deadline: uint64(block.timestamp + 1 hours),
            channel: 0, nonce: 0, builder: address(0), builderFeePpm: 0 });
        vm.prank(keeper);
        uint256 id2 = h.executeAtMark(o2, _sign(alicePk, o2));
        // 4s old pays a strictly wider spread than 1s old → higher entry.
        assertGt(h.positions(id2).entryPrice, e1);
    }

    function test_fallbackArmsWhenPrimaryStale() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        assertFalse(h.fallbackArmed(mkt));
        _adv(301); // primary now stale
        assertTrue(h.fallbackArmed(mkt));
    }

    function test_fallbackCloseWorksWhenPrimaryDark() public {
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(301);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o = _order(alicePk, true, false, 1e18, 0, 49_800e18, 200, 1);
        vm.prank(keeper);
        h.executeAtFallback(o, _sign(alicePk, o));
        assertTrue(h.positions(id).closed);
    }

    function test_fallbackRejectsWhenPrimaryFresh() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(1);
        _refresh(50_000e18);
        IH2Market.Order memory o = _order(alicePk, true, false, 1e18, 0, 49_800e18, 200, 1);
        vm.expectRevert(IH2Market.FallbackNotArmed.selector);
        h.executeAtFallback(o, _sign(alicePk, o));
    }

    // ============================================================
    // treasury — permissionless share vault
    // ============================================================

    function test_depositRequiresBandedFeed() public {
        vm.prank(op);
        uint256 ufeed = oracle.createFeed(op, 1e18, RATE_CAP, RAKE_PPM, address(0), 0, 0, 0);
        IH2Market.OracleParams memory op_ = _oracleParams();
        op_.primaryFeedId = uint64(ufeed);
        vm.prank(op);
        uint256 umkt = h.createMarket(token, _fees(), _risk(0), op_, _spread(), address(reg));
        usdm.mint(carl, 100e18);
        vm.startPrank(carl);
        usdm.approve(address(h), type(uint256).max);
        vm.expectRevert(IH2Market.UnbandedFeed.selector);
        h.deposit(umkt, 100e18);
        vm.stopPrank();
    }

    function test_depositMintsSharesAtNav() public {
        // setUp deposited 5M from carl at NAV 1. A second equal deposit mints equal shares.
        IH2Market.VaultView memory v0 = h.vaultOf(mkt);
        usdm.mint(carl, 5_000_000e18);
        vm.prank(carl);
        uint256 sh = h.deposit(mkt, 5_000_000e18);
        IH2Market.VaultView memory v = h.vaultOf(mkt);
        assertEq(v.poolAssets, v0.poolAssets + 5_000_000e18, "pool grew by deposit");
        assertEq(sh, 5_000_000e18, "NAV 1 => shares == assets");
        assertEq(v.totalShares, v0.totalShares + sh);
        assertEq(v.rakePpm, RAKE_PPM, "rake cached from feed");
        assertEq(v.rakeRecipient, op, "rake recipient = feed operator");
    }

    // ---- walk-back time floor under sub-second (production) mark cadence ----

    function _mockHp(uint256 micros) internal {
        vm.mockCall(
            0x6342000000000000000000000000000000000002,
            abi.encodeWithSignature("timestamp()"),
            abi.encode(micros)
        );
    }

    /// @dev Operator mark push on an arbitrary feed at a mocked µs clock, ref pinned = mark.
    function _pushAtFeed(uint256 fid, uint256 micros, uint256 mark) internal {
        _mockHp(micros);
        ref.setAnswer(int256(mark / 1e10));
        ref.setUpdatedAt(block.timestamp);
        vm.prank(op);
        oracle.push(fid, mark);
    }

    /// @dev Regression for the ring-walk time floor: with marks pushed sub-second apart (the
    /// MegaETH regime), the walk must still rewind its clock exactly and NOT test marks that
    /// predate the position. A pre-open dip must not wipe a position that never once breached
    /// after it opened.
    function test_walkBackExcludesPreOpenMarksUnderSubSecondCadence() public {
        vm.prank(op);
        uint256 fid = oracle.createFeed(op, 1e18, RATE_CAP, RAKE_PPM, address(ref), 8, 100_000, 1 hours);
        IH2Market.OracleParams memory op_ = _oracleParams();
        op_.primaryFeedId = uint64(fid);
        vm.prank(op);
        uint256 m = h.createMarket(token, _fees(), _risk(0), op_, _spread(), address(reg));
        _seedTreasury(m, 1_000_000e18);

        // µs clock, 100 ms apart; block.timestamp never advances.
        uint256 b = (_t + 1) * 1_000_000;
        _pushAtFeed(fid, b,           50_000e18); // first push: initializes, no ring entry
        _pushAtFeed(fid, b + 100_000, 49_000e18); // PRE-OPEN dip: a 100x long @50k is bust here
        _pushAtFeed(fid, b + 200_000, 50_000e18); // recover

        // Open a 100x long @ 50_000 AFTER the dip — never liquidatable at any post-open mark.
        _mockHp(b + 300_000);
        ref.setAnswer(50_000e8); ref.setUpdatedAt(block.timestamp);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o = IH2Market.Order({
            user: alice, marketId: m, isLong: true, isOpen: true, size: 1e18, leverage: 100,
            targetPrice: 50_100e18, maxSlippageBps: 200, deadline: uint64(block.timestamp + 1 hours),
            channel: 0, nonce: 0, builder: address(0), builderFeePpm: 0 });
        {
            bytes memory data = abi.encode(m, uint8(IH2Market.ActionKind.Order_), abi.encode(o, _sign(alicePk, o)));
            IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
            calls[0] = IH2Oracle.Call({ target: address(h), data: data });
            vm.prank(op); oracle.pushAndCall(fid, 50_000e18, calls);
        }
        uint256 id = h.activePositionId(alice, m);
        assertFalse(h.positions(id).closed);

        // Fresh mark @ 50_000 carrying a liquidation batch. The pre-open dip must be excluded,
        // so nothing liquidates: the batch reverts internally (NoneLiquidated → CallFailed) and
        // the position stays open.
        _mockHp(b + 400_000);
        ref.setAnswer(50_000e8); ref.setUpdatedAt(block.timestamp);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        {
            bytes memory data = abi.encode(m, uint8(IH2Market.ActionKind.Liquidate), abi.encode(ids));
            IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
            calls[0] = IH2Oracle.Call({ target: address(h), data: data });
            vm.prank(op); oracle.pushAndCall(fid, 50_000e18, calls);
        }
        assertFalse(h.positions(id).closed, "pre-open dip must not wipe the position");
    }

    /// @dev Companion: a genuine POST-open breach in the ring still liquidates (the fix must
    /// not over-correct into never liquidating from history).
    function test_walkBackStillLiquidatesPostOpenBreach() public {
        vm.prank(op);
        uint256 fid = oracle.createFeed(op, 1e18, RATE_CAP, RAKE_PPM, address(ref), 8, 100_000, 1 hours);
        IH2Market.OracleParams memory op_ = _oracleParams();
        op_.primaryFeedId = uint64(fid);
        vm.prank(op);
        uint256 m = h.createMarket(token, _fees(), _risk(0), op_, _spread(), address(reg));
        _seedTreasury(m, 1_000_000e18);

        uint256 b = (_t + 1) * 1_000_000;
        _pushAtFeed(fid, b, 50_000e18);

        // Open a 100x long @ 50_000.
        _mockHp(b + 100_000);
        ref.setAnswer(50_000e8); ref.setUpdatedAt(block.timestamp);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o = IH2Market.Order({
            user: alice, marketId: m, isLong: true, isOpen: true, size: 1e18, leverage: 100,
            targetPrice: 50_100e18, maxSlippageBps: 200, deadline: uint64(block.timestamp + 1 hours),
            channel: 0, nonce: 0, builder: address(0), builderFeePpm: 0 });
        {
            bytes memory data = abi.encode(m, uint8(IH2Market.ActionKind.Order_), abi.encode(o, _sign(alicePk, o)));
            IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
            calls[0] = IH2Oracle.Call({ target: address(h), data: data });
            vm.prank(op); oracle.pushAndCall(fid, 50_000e18, calls);
        }
        uint256 id = h.activePositionId(alice, m);

        // POST-open dip to 49_000 (bust), then recover — a keeper walks the ring back to it.
        _pushAtFeed(fid, b + 200_000, 49_000e18);
        _pushAtFeed(fid, b + 300_000, 50_000e18);

        _mockHp(b + 400_000);
        ref.setAnswer(50_000e8); ref.setUpdatedAt(block.timestamp);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        {
            bytes memory data = abi.encode(m, uint8(IH2Market.ActionKind.Liquidate), abi.encode(ids));
            IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
            calls[0] = IH2Oracle.Call({ target: address(h), data: data });
            vm.prank(op); oracle.pushAndCall(fid, 50_000e18, calls);
        }
        assertTrue(h.positions(id).closed, "post-open breach must still liquidate");
    }

    function test_firstDepositVirtualOffsetSanity() public {
        // A fresh market: first deposit mints shares == assets, share price is exactly 1e18.
        vm.prank(op);
        uint256 m = h.createMarket(token, _fees(), _risk(0), _oracleParams(), _spread(), address(reg));
        usdm.mint(carl, 1_000e18);
        vm.prank(carl);
        uint256 sh = h.deposit(m, 1_000e18);
        IH2Market.VaultView memory v = h.vaultOf(m);
        assertEq(sh, 1_000e18, "first deposit: shares == assets");
        assertEq(v.totalShares, 1_000e18);
        assertEq(v.poolAssets, 1_000e18);
        assertEq(v.sharePrice, 1e18, "NAV exactly 1.0");
    }

    function test_requestUnstakeRejectsOverBalance() public {
        uint256 shares = h.stakeOf(mkt, carl).shares;
        vm.prank(carl);
        vm.expectRevert(IH2Market.InsufficientShares.selector);
        h.requestUnstake(mkt, shares + 1);
    }

    function test_unstakeCooldownThenWithdrawAtNav() public {
        uint256 shares = h.stakeOf(mkt, carl).shares;
        vm.prank(carl);
        h.requestUnstake(mkt, shares);
        IH2Market.StakeView memory st = h.stakeOf(mkt, carl);
        assertEq(st.unstakeShares, shares);
        assertEq(st.unlockAt, uint64(block.timestamp) + uint32(TERM));

        // Cooldown not elapsed ⇒ withdraw reverts.
        vm.prank(carl);
        vm.expectRevert(IH2Market.CooldownActive.selector);
        h.withdraw(mkt);

        _adv(TERM);
        _pushMark(50_000e18, 0, 0, 0); // operator keeps the feed fresh through the cooldown
        uint256 bal0 = usdm.balanceOf(carl);
        vm.prank(carl);
        uint256 got = h.withdraw(mkt);
        assertEq(usdm.balanceOf(carl) - bal0, got, "paid out");
        assertApproxEqAbs(got, 5_000_000e18, 1, "~ full NAV back, no PnL");
        assertEq(h.stakeOf(mkt, carl).shares, 0, "shares burned");
    }

    function test_unstakingSharesKeepEarningThroughCooldown() public {
        uint256 shares = h.stakeOf(mkt, carl).shares;
        vm.prank(carl);
        h.requestUnstake(mkt, shares);
        // A round trip lands DURING the cooldown; the unstaking shares still capture the fees.
        _roundTrip();
        _adv(TERM);
        _pushMark(50_000e18, 0, 0, 0); // operator keeps the feed fresh through the cooldown
        vm.prank(carl);
        uint256 got = h.withdraw(mkt);
        assertGt(got, 5_000_000e18, "cooldown shares earned the interim fees - no dodge");
    }

    function test_lossMarksDownNavNoHaircut() public {
        // Alice longs, the mark rises, she closes in profit — the pool pays her, NAV drops.
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(1);
        IH2Market.Order memory c = _order(alicePk, true, false, 1e18, 0, 50_500e18, 200, 1);
        _pushOrder(51_000e18, c, _sign(alicePk, c), 0);
        assertTrue(h.positions(id).closed);

        IH2Market.VaultView memory v = h.vaultOf(mkt);
        assertLt(v.poolAssets, 5_000_000e18, "pool paid the winner");

        uint256 shares = h.stakeOf(mkt, carl).shares;
        vm.prank(carl);
        h.requestUnstake(mkt, shares);
        _adv(TERM);
        _pushMark(51_000e18, 0, 0, 0); // operator keeps the feed fresh through the cooldown
        uint256 bal0 = usdm.balanceOf(carl);
        vm.prank(carl);
        uint256 got = h.withdraw(mkt);
        assertEq(usdm.balanceOf(carl) - bal0, got);
        assertLt(got, 5_000_000e18, "LP bore the loss via NAV markdown, in full (no haircut)");
        assertApproxEqAbs(got, v.poolAssets, 1, "redeemed the whole pool");
    }

    function test_rakeSkimsGrossAndOperatorClaims() public {
        IH2Market.VaultView memory v0 = h.vaultOf(mkt);
        assertEq(v0.rakeOwed, 0);
        _roundTrip(); // banks fees: 15% to rake, 85% to the pool

        IH2Market.VaultView memory v = h.vaultOf(mkt);
        assertGt(v.rakeOwed, 0, "rake accrued");
        // rake:poolGrowth == 15:85 (per-credit rounding aside).
        uint256 poolGrowth = v.poolAssets - v0.poolAssets;
        assertApproxEqRel(v.rakeOwed * 850_000, poolGrowth * 150_000, 1e12, "15/85 split");

        // Non-operator cannot claim.
        vm.prank(carl);
        vm.expectRevert(IH2Market.NotFeedOperator.selector);
        h.claimRake(mkt, carl);

        // Operator claims the full accrued rake.
        uint256 bal0 = usdm.balanceOf(op);
        vm.prank(op);
        h.claimRake(mkt, op);
        assertEq(usdm.balanceOf(op) - bal0, v.rakeOwed, "claimed full rake");
        assertEq(h.vaultOf(mkt).rakeOwed, 0, "rake zeroed");
    }

        function test_cancelNonceRetiresOrder() public {
        vm.prank(alice);
        h.cancelNonce(0, 7);
        _adv(1);
        IH2Market.Order memory o = _order(alicePk, true, true, 1e18, 100, 50_000e18, 200, 7);
        bytes memory sig = _sign(alicePk, o);
        _refresh(50_000e18);
        bytes memory data = abi.encode(mkt, uint8(IH2Market.ActionKind.Order_), abi.encode(o, sig));
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h), data: data });
        vm.prank(op);
        vm.expectEmit(true, false, false, false);
        emit IH2Oracle.CallFailed(feedId, 0, address(h)); // NonceAlreadyUsed, isolated
        oracle.pushAndCall(feedId, 50_000e18, calls);
        assertEq(h.activePositionId(alice, mkt), 0);
    }

    function test_grossOpenNotionalIsPerMarket() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        assertEq(h.grossOpenNotional(mkt), 50_000e18);
    }

    // ============================================================
    // audit fixes
    // ============================================================

    /// FIX 1 (HIGH: cut-evasion): the winnings cut is charged ONLY at close — an increase never
    /// crystallizes it, never drains the pool, and charges no cut. This kills the dust-increase
    /// dodge (chunk a gain into sub-intercept crystallizations at 0 cut) that a crystallize-on-
    /// increase opened, and restores the "opens are never solvency-gated" invariant (MED-4).
    function test_increaseNeverChargesCutOrDrainsPool() public {
        uint256 id = _openLong(bobPk, 1e18, 100, 50_000e18, 0);
        IH2Market.VaultView memory v0 = h.vaultOf(mkt);
        // Increase while deep in profit (mark 55k).
        _adv(1);
        IH2Market.Order memory inc = _order(bobPk, true, true, 1e18, 100, 55_500e18, 200, 1);
        _pushOrder(55_000e18, inc, _sign(bobPk, inc), 0);
        assertEq(h.positions(id).makerCutPaid, 0, "increase charges no winnings cut");
        // No drain: poolAssets only ever grows here (the open fee inflows), never falls.
        assertGe(h.vaultOf(mkt).poolAssets, v0.poolAssets, "increase never drains the pool (MED-4)");
        uint256 e = h.positions(id).entryPrice;
        assertGt(e, 50_000e18); assertLt(e, 55_000e18); // entry BLENDED, not rebased to the fill
        // The winnings cut is taken at CLOSE.
        _adv(1);
        IH2Market.Order memory c = _order(bobPk, true, false, 2e18, 0, 54_500e18, 500, 2);
        _pushOrder(55_000e18, c, _sign(bobPk, c), 0);
        assertTrue(h.positions(id).closed);
        assertGt(h.positions(id).makerCutPaid, 0, "the winnings cut is charged at close");
        assertEq(h.grossOpenNotional(mkt), 0, "OI back to zero");
    }

    /// FIX 1 (negative): increasing a LOSING position is not crystallized — the size-weighted
    /// blend preserves the unrealized loss, and no cut is taken (nothing to tax).
    function test_increaseDoesNotCrystallizeALoss() public {
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        assertEq(h.positions(id).makerCutPaid, 0);
        _adv(1);
        IH2Market.Order memory inc = _order(alicePk, true, true, 1e18, 100, 49_900e18, 200, 1);
        _pushOrder(49_800e18, inc, _sign(alicePk, inc), 0); // dip: solvent at 100x, not liquidatable
        assertEq(h.positions(id).makerCutPaid, 0, "a loss is not crystallized");
        uint256 e = h.positions(id).entryPrice;
        assertGt(e, 49_800e18, "entry blended, not rebased to the fill");
        assertLt(e, 50_000e18);
        // OI unwinds cleanly on full close afterwards.
        _adv(1);
        IH2Market.Order memory c = _order(alicePk, true, false, 2e18, 0, 49_000e18, 500, 2);
        _pushOrder(49_800e18, c, _sign(alicePk, c), 0);
        assertTrue(h.positions(id).closed);
        assertEq(h.grossOpenNotional(mkt), 0, "OI back to zero");
    }

    /// FIX 2: a position may be adjusted at most once per block — a same-block second adjustment
    /// reverts SameBlockAction (so the convex size-fee curve can't be dodged by chunking within a
    /// block); the identical action succeeds a block later.
    function test_sameBlockAdjustmentReverts() public {
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0); // opened this block; mark+fallback fresh
        IH2Market.Order memory inc = _order(alicePk, true, true, 1e18, 100, 50_200e18, 200, 1);
        vm.prank(keeper);
        vm.expectRevert(IH2Market.AdjustmentTooSoon.selector);
        h.executeAtMark(inc, _sign(alicePk, inc));

        _adv(1); // next block, time passes
        _refresh(50_000e18);
        vm.prank(keeper);
        uint256 id2 = h.executeAtMark(inc, _sign(alicePk, inc));
        assertEq(id2, id);
        assertEq(h.positions(id).size, 2e18, "the increase lands a block later");
    }

    /// FIX 3: the market must not trust a caller-supplied fallback-decimals that disagrees with
    /// the aggregator's own `decimals()`.
    function test_createMarketRejectsMismatchedFallbackDecimals() public {
        IH2Market.OracleParams memory o = _oracleParams(); // fallback aggregator is 8 decimals
        o.fallbackDecimals = 6;
        vm.prank(op);
        vm.expectRevert(IH2Market.BadMarketParams.selector);
        h.createMarket(token, _fees(), _risk(0), o, _spread(), address(reg));
    }

    // ============================================================
    // builder codes
    // ============================================================

    function _registerBuilder(address b) internal {
        vm.deal(b, MIN_BUILDER_STAKE);
        vm.prank(b);
        reg.register{ value: MIN_BUILDER_STAKE }();
    }

    function test_registerBuilderBelowMinReverts() public {
        address b = makeAddr("builder");
        vm.deal(b, MIN_BUILDER_STAKE);
        vm.prank(b);
        vm.expectRevert(BuilderRegistry.StakeTooLow.selector);
        reg.register{ value: MIN_BUILDER_STAKE - 1 }();
        assertFalse(reg.isBuilder(b));
    }

    /// A registered builder earns its per-order rate on the OPEN fee and the CLOSE fee + winnings
    /// cut. The oracle rake is senior (unchanged); the builder's share comes out of the vault residual.
    function test_builderAccruesOnOpenAndClose() public {
        address builder = makeAddr("builder");
        _registerBuilder(builder);
        assertTrue(reg.isBuilder(builder));

        IH2Market.VaultView memory v0 = h.vaultOf(mkt);
        _adv(1);
        IH2Market.Order memory o = _orderB(alicePk, true, true, 1e18, 100, 50_200e18, 200, 0, builder, 100_000);
        _pushOrder(50_000e18, o, _sign(alicePk, o), 0);
        uint256 id = h.activePositionId(alice, mkt);

        // Open fee = 50_000 · 5bps = 25e18. Oracle rake = 15% = 3.75e18 (senior). Builder = 10% of
        // the 21.25e18 residual = 2.125e18.
        assertApproxEqRel(h.vaultOf(mkt).rakeOwed - v0.rakeOwed, 3.75e18, 1e15, "rake is the full 15%");
        assertApproxEqRel(h.builderOwed(builder), 2.125e18, 1e15, "builder open share = 10% of residual");

        uint256 owedAfterOpen = h.builderOwed(builder);
        _adv(1);
        IH2Market.Order memory c = _orderB(alicePk, true, false, 1e18, 0, 54_500e18, 200, 1, builder, 100_000);
        _pushOrder(55_000e18, c, _sign(alicePk, c), 0);
        assertTrue(h.positions(id).closed);
        assertGt(h.builderOwed(builder), owedAfterOpen, "builder earns the close fee + winnings-cut share");
    }

    /// A DECREASE pays the order's builder its share of the close fee + realized winnings cut; an
    /// INCREASE pays its builder the share of the OPEN FEE (increases no longer crystallize a cut).
    function test_builderAccruesOnDecreaseAndIncrease() public {
        address builder = makeAddr("builder");
        _registerBuilder(builder);

        uint256 id = _openLong(alicePk, 2e18, 100, 50_000e18, 0);
        _adv(1);
        IH2Market.Order memory dec = _orderB(alicePk, true, false, 1e18, 0, 54_000e18, 500, 1, builder, 100_000);
        _pushOrder(55_000e18, dec, _sign(alicePk, dec), 0);
        uint256 owedAfterDec = h.builderOwed(builder);
        assertGt(owedAfterDec, 0, "builder earns on a decrease (fee + winnings cut)");

        _adv(1);
        IH2Market.Order memory inc = _orderB(alicePk, true, true, 1e18, 100, 55_500e18, 200, 2, builder, 100_000);
        _pushOrder(55_000e18, inc, _sign(alicePk, inc), 0);
        assertTrue(!h.positions(id).closed);
        assertGt(h.builderOwed(builder), owedAfterDec, "builder earns the increase's open-fee share");
    }

    /// An UNREGISTERED builder forfeits its share to the vault; the order still executes.
    function test_unregisteredBuilderForfeitsShareToVault() public {
        address builder = makeAddr("unreg"); // never staked
        assertFalse(reg.isBuilder(builder));
        IH2Market.VaultView memory v0 = h.vaultOf(mkt);
        _adv(1);
        IH2Market.Order memory o = _orderB(alicePk, true, true, 1e18, 100, 50_200e18, 200, 0, builder, 100_000);
        _pushOrder(50_000e18, o, _sign(alicePk, o), 0);
        assertGt(h.activePositionId(alice, mkt), 0, "order executed");
        assertEq(h.builderOwed(builder), 0, "unregistered builder earned nothing");
        // The whole post-rake fee lifted the pool (nothing skimmed for the builder).
        assertGt(h.vaultOf(mkt).poolAssets, v0.poolAssets, "share went to the vault");
    }

    /// A per-order builder rate above the market cap reverts (surfaced directly on the self-service path).
    function test_builderFeeAboveCapReverts() public {
        address builder = makeAddr("builder");
        _registerBuilder(builder);
        _adv(2);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        // cap is 100_000; ask for 200_000.
        IH2Market.Order memory o = _orderB(bobPk, true, true, 1e18, 100, 50_100e18, 200, 0, builder, 200_000);
        vm.prank(keeper);
        vm.expectRevert(IH2Market.BadBuilderFee.selector);
        h.executeAtMark(o, _sign(bobPk, o));
    }

    /// A builder claims its accrued fees (USDM) and can unregister to recover its native stake.
    function test_builderClaimsFeesAndUnregisters() public {
        address builder = makeAddr("builder");
        _registerBuilder(builder);
        _adv(1);
        IH2Market.Order memory o = _orderB(alicePk, true, true, 1e18, 100, 50_200e18, 200, 0, builder, 100_000);
        _pushOrder(50_000e18, o, _sign(alicePk, o), 0);
        uint256 owed = h.builderOwed(builder);
        assertGt(owed, 0);

        uint256 b0 = usdm.balanceOf(builder);
        vm.prank(builder);
        h.claimBuilderFees(builder);
        assertEq(usdm.balanceOf(builder) - b0, owed, "claimed the accrued USDM");
        assertEq(h.builderOwed(builder), 0, "owed zeroed");

        uint256 n0 = builder.balance;
        vm.prank(builder);
        reg.unregister();
        assertEq(builder.balance - n0, MIN_BUILDER_STAKE, "native stake returned");
        assertFalse(reg.isBuilder(builder));
    }

    /// @dev Open a long naming `builder` at 10% on an arbitrary market `m` (inline so it can target
    /// a market other than the default `mkt`).
    function _openWithBuilderOn(uint256 m, uint256 pk, address builder) internal returns (uint256 id) {
        _adv(1);
        IH2Market.Order memory o = IH2Market.Order({
            user: vm.addr(pk), marketId: m, isLong: true, isOpen: true, size: 1e18, leverage: 100,
            targetPrice: 50_200e18, maxSlippageBps: 200, deadline: uint64(block.timestamp + 1 hours),
            channel: 0, nonce: 0, builder: builder, builderFeePpm: 100_000
        });
        _pushOrderM(m, 50_000e18, o, _sign(pk, o), 0, int32(0));
        id = h.activePositionId(vm.addr(pk), m);
    }

    /// A market with NO registry (address(0)) disables builder codes: the order executes and the
    /// would-be builder share stays with the vault.
    function test_zeroRegistryForfeitsAndExecutes() public {
        uint256 zmkt = h.createMarket(token, _fees(), _risk(0), _oracleParams(), _spread(), address(0));
        address b = makeAddr("b0");
        uint256 id = _openWithBuilderOn(zmkt, alicePk, b);
        assertGt(id, 0, "executed with no registry");
        assertEq(h.builderOwed(b), 0, "builder codes disabled: share to the vault");
    }

    /// A hostile/broken registry that REVERTS on isBuilder must not brick order execution — the
    /// try/catch treats a revert as ineligible and forfeits the share to the vault.
    function test_revertingRegistryForfeitsAndExecutes() public {
        RevertingRegistry bad = new RevertingRegistry();
        uint256 rmkt = h.createMarket(token, _fees(), _risk(0), _oracleParams(), _spread(), address(bad));
        address b = makeAddr("bR");
        uint256 id = _openWithBuilderOn(rmkt, alicePk, b);
        assertGt(id, 0, "executed despite a reverting registry");
        assertEq(h.builderOwed(b), 0, "reverting registry -> forfeit to the vault");
    }

    // ============================================================
    // vol/skew → derived spread
    // ============================================================

    /// The derived spread grows with vol² (variance-like): halving vol quarters the spread.
    function test_derivedSpreadScalesWithVolSquared() public {
        // vol=5000 → 2000·5000²/1e8 = 500 ppm → +25 on 50_000 (ceil-to-$1-tick).
        _adv(1);
        IH2Market.Order memory oa = _order(alicePk, true, true, 1e18, 100, 50_100e18, 200, 0);
        _pushOrder(50_000e18, oa, _sign(alicePk, oa), uint32(5_000));
        uint256 ea = h.positions(h.activePositionId(alice, mkt)).entryPrice;

        // vol=10000 → 2000 ppm → +100.
        _adv(1);
        IH2Market.Order memory ob = _order(bobPk, true, true, 1e18, 100, 50_200e18, 200, 0);
        _pushOrder(50_000e18, ob, _sign(bobPk, ob), uint32(10_000));
        uint256 eb = h.positions(h.activePositionId(bob, mkt)).entryPrice;

        assertEq(ea, 50_025e18, "vol=5000 gives 500 ppm");
        assertEq(eb, 50_100e18, "vol=10000 gives 2000 ppm");
        assertEq(eb - 50_000e18, 4 * (ea - 50_000e18), "spread scales with vol^2");
    }

    /// Positive skew makes a long open pay a wider spread than a short open (asymmetry).
    function test_skewMakesLongsPayMoreOnOpen() public {
        // vol=10000 (base 2000 ppm), skew=10000 (1% ⇒ ±1000 ppm): long 3000 ppm (+150), short 1000 ppm (−50).
        _adv(1);
        IH2Market.Order memory ol = _order(alicePk, true, true, 1e18, 100, 50_300e18, 200, 0);
        _pushOrder(50_000e18, ol, _sign(alicePk, ol), uint32(10_000), int32(10_000));
        uint256 eLong = h.positions(h.activePositionId(alice, mkt)).entryPrice;

        _adv(1);
        IH2Market.Order memory os = _order(bobPk, false, true, 1e18, 100, 49_700e18, 200, 0);
        _pushOrder(50_000e18, os, _sign(bobPk, os), uint32(10_000), int32(10_000));
        uint256 eShort = h.positions(h.activePositionId(bob, mkt)).entryPrice;

        assertEq(eLong, 50_150e18, "long pays 3000 ppm up");
        assertEq(eShort, 49_950e18, "short pays only 1000 ppm down");
        assertGt(eLong - 50_000e18, 50_000e18 - eShort, "skew>0 means longs pay more");
    }

    /// Zero close coefficients ⇒ zero close spread even under a large pushed vol (the rake prices closes).
    function test_zeroCloseCoefficientsGiveZeroCloseSpread() public {
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(1);
        IH2Market.Order memory c = _order(alicePk, true, false, 1e18, 0, 49_000e18, 500, 1);
        _pushOrder(50_000e18, c, _sign(alicePk, c), uint32(50_000)); // huge vol, but closeVolK=0
        assertTrue(h.positions(id).closed);
        assertEq(h.positions(id).closePrice, 50_000e18, "close at mark exactly, no derived close spread");
    }

    /// The derived spread is clamped at the market's maxSpreadPpm.
    function test_derivedSpreadClampsAtMax() public {
        // vol=20000 → 8000 ppm uncapped, clamped to maxSpreadPpm=5000 → +250 on 50_000.
        _adv(1);
        IH2Market.Order memory o = _order(alicePk, true, true, 1e18, 100, 50_400e18, 200, 0);
        _pushOrder(50_000e18, o, _sign(alicePk, o), uint32(20_000));
        assertEq(h.positions(h.activePositionId(alice, mkt)).entryPrice, 50_250e18, "clamped at 5000 ppm");
    }

    /// The skew-favored side floors at 0 — never a rebate (a fill better than mark).
    function test_favoredSideFloorsAtZeroNoRebate() public {
        // short open, vol=5000 (base 500 ppm), skew=10000 (−1000 ppm for shorts): 500−1000 < 0 → 0.
        _adv(1);
        IH2Market.Order memory o = _order(bobPk, false, true, 1e18, 100, 49_800e18, 200, 0);
        _pushOrder(50_000e18, o, _sign(bobPk, o), uint32(5_000), int32(10_000));
        assertEq(h.positions(h.activePositionId(bob, mkt)).entryPrice, 50_000e18, "floored to 0: fills at mark, no rebate");
    }

    /// @dev Push an order attached to a mark on an ARBITRARY market (the standard `_pushOrder`
    /// hardcodes the default `mkt`); lets a test drive a market with its own spread coefficients.
    function _pushOrderM(uint256 m, uint256 mark, IH2Market.Order memory o, bytes memory sig, uint32 vol, int32 skew)
        internal
    {
        _refresh(mark);
        bytes memory data = abi.encode(m, uint8(IH2Market.ActionKind.Order_), abi.encode(o, sig));
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h), data: data });
        vm.prank(op);
        oracle.pushWithParams(feedId, mark, 0, 0, vol, skew, calls);
    }

    /// Skew keys off the taker's FILL DIRECTION, not the position side. On a market that skews
    /// closes, a long CLOSE is a SELL, so with skew>0 it gets the REBATED (smaller) spread —
    /// base − skew — not the widened one. (Position-side keying would have charged base + skew.)
    /// This is the only leg where the two conventions diverge (on opens `up == isLong`).
    function test_skewOnCloseKeysOffFillDirection() public {
        // Market skews CLOSES only: closeVolK=2000, closeSkewK=1000 (open coefficients 0).
        uint256 cmkt = h.createMarket(token, _fees(), _risk(0), _oracleParams(), _spreadK(0, 0, 2_000, 1_000), address(reg));

        _adv(1); // open a long at the mark (zero open spread)
        IH2Market.Order memory oo = IH2Market.Order({
            user: alice, marketId: cmkt, isLong: true, isOpen: true, size: 1e18, leverage: 100,
            targetPrice: 50_000e18, maxSlippageBps: 200, deadline: uint64(block.timestamp + 1 hours),
            channel: 0, nonce: 0, builder: address(0), builderFeePpm: 0
        });
        _pushOrderM(cmkt, 50_000e18, oo, _sign(alicePk, oo), 0, int32(0));
        uint256 id = h.activePositionId(alice, cmkt);

        _adv(1); // close the long (a SELL) with vol=10000 (base 2000ppm), skew=10000 (±1000ppm)
        IH2Market.Order memory oc = IH2Market.Order({
            user: alice, marketId: cmkt, isLong: true, isOpen: false, size: 1e18, leverage: 0,
            targetPrice: 49_000e18, maxSlippageBps: 500, deadline: uint64(block.timestamp + 1 hours),
            channel: 0, nonce: 1, builder: address(0), builderFeePpm: 0
        });
        _pushOrderM(cmkt, 50_000e18, oc, _sign(alicePk, oc), 10_000, int32(10_000));

        assertTrue(h.positions(id).closed, "closed");
        // Sell ⇒ !up ⇒ spread = base − skew = 2000 − 1000 = 1000 ppm down → 49_950 (rebated),
        // NOT base + skew = 3000 ppm → 49_850 (what position-side keying would have charged).
        assertEq(h.positions(id).closePrice, 49_950e18, "long close (sell) gets the rebated 1000ppm");
    }

    // ============================================================
    // marked-to-market NAV
    // ============================================================

    uint256 constant _PT = 1e18;  // priceTick
    uint256 constant _ST = 1e10;  // sizeTick

    function _openShort(uint256 pk, uint256 size, uint256 lev, uint256 mark, uint256 nonce)
        internal returns (uint256 id)
    {
        _adv(1);
        IH2Market.Order memory o = _order(pk, false, true, size, lev, mark, 200, nonce);
        _pushOrder(mark, o, _sign(pk, o), 0);
        id = h.activePositionId(vm.addr(pk), mkt);
    }

    /// @dev Full-close the caller's active position at `mark` (generous band).
    function _closeAll(uint256 pk, uint256 mark, uint256 nonce) internal {
        _adv(1);
        uint256 id = h.activePositionId(vm.addr(pk), mkt);
        IH2Market.PositionView memory p = h.positions(id);
        // Target the mark itself with a wide band so a flat close always fills.
        IH2Market.Order memory c = _order(pk, p.isLong, false, p.size, 0, mark, 1000, nonce);
        _pushOrder(mark, c, _sign(pk, c), 0);
    }

    /// @dev One open position's contribution to its side's aggregates (0 once closed).
    function _aggContribution(uint256 id) internal view returns (uint256 sizeU, uint256 entryW, int256 checkW) {
        IH2Market.PositionView memory p = h.positions(id);
        if (p.closed) return (0, 0, 0);
        sizeU  = p.size / _ST;
        entryW = (p.entryPrice / _PT) * sizeU;
        checkW = int256(p.fundingCheckpoint) * int256(sizeU);
    }

    /// The per-side aggregates equal the live Σ over open positions, and fully unwind to 0 on close.
    function test_mtm_aggregatesTrackAndUnwind() public {
        uint256 la = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        uint256 sb = _openShort(bobPk, 2e18, 100, 50_000e18, 0);

        (uint256 ls, uint256 le, int256 lc) = h.aggOf(mkt, true);
        (uint256 e1s, uint256 e1e, int256 e1c) = _aggContribution(la);
        assertEq(ls, e1s, "long sumSize"); assertEq(le, e1e, "long sumEntryW"); assertEq(lc, e1c, "long sumCheckW");

        (uint256 ss, uint256 se, int256 sc) = h.aggOf(mkt, false);
        (uint256 e2s, uint256 e2e, int256 e2c) = _aggContribution(sb);
        assertEq(ss, e2s, "short sumSize"); assertEq(se, e2e, "short sumEntryW"); assertEq(sc, e2c, "short sumCheckW");

        _closeAll(alicePk, 50_000e18, 1);
        _closeAll(bobPk, 50_000e18, 1);
        (ls, le, lc) = h.aggOf(mkt, true);
        (ss, se, sc) = h.aggOf(mkt, false);
        assertEq(ls, 0, "long unwinds"); assertEq(le, 0); assertEq(lc, 0);
        assertEq(ss, 0, "short unwinds"); assertEq(se, 0); assertEq(sc, 0);
    }

    /// _mtmValue == poolAssets − a single position's unrealized price PnL, to the wei (both signs).
    function test_mtm_equalsPoolMinusUnrealized_long() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(1);
        _pushMark(51_000e18, 0, 0, 0); // +1000·sizeUnits(1e8)·notionalScale(1e10) = 1000e18 profit
        IH2Market.VaultView memory v = h.vaultOf(mkt);
        assertEq(v.poolAssets - v.mtmValue, 1000e18, "pool owes the long's unrealized profit");
        _adv(1);
        _pushMark(49_000e18, 0, 0, 0); // loss → pool MTM-richer by the loss
        v = h.vaultOf(mkt);
        assertEq(v.mtmValue - v.poolAssets, 1000e18, "pool gains the long's unrealized loss");
    }

    function test_mtm_equalsPoolMinusUnrealized_short() public {
        _openShort(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(1);
        _pushMark(49_000e18, 0, 0, 0); // short profits when price falls
        IH2Market.VaultView memory v = h.vaultOf(mkt);
        assertEq(v.poolAssets - v.mtmValue, 1000e18, "pool owes the short's unrealized profit");
    }

    /// Funding is in the MTM: a long paying funding reduces the pool's liability (mtm rises).
    function test_mtm_includesFunding() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(1);
        _pushMark(51_000e18, 0, 0, 0);
        uint256 mtmNoFunding = h.vaultOf(mkt).mtmValue;
        _adv(1);
        _pushMark(51_000e18, int64(RATE_CAP), 0, 0); // positive long rate: longs pay
        _adv(100);
        _pushMark(51_000e18, int64(RATE_CAP), 0, 0);
        assertGt(h.vaultOf(mkt).mtmValue, mtmNoFunding, "long-paid funding lowers the pool liability");
    }

    /// EXIT: traders net-up ⇒ an LP redeems at the MTM (lower) value, not the stale poolAssets,
    /// and the pool still covers the winner (no first-mover extraction / stranding).
    function test_mtm_exitPricesAtMtmNotStalePool() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(1);
        _pushMark(51_000e18, 0, 0, 0);
        IH2Market.VaultView memory v = h.vaultOf(mkt);
        uint256 pa = v.poolAssets;
        assertEq(pa - v.mtmValue, 1000e18, "liability booked");

        uint256 shares = h.stakeOf(mkt, carl).shares;
        vm.prank(carl); h.requestUnstake(mkt, shares);
        _adv(uint256(TERM) + 1);
        _pushMark(51_000e18, 0, 0, 0); // operator keeps the feed fresh through the cooldown
        vm.prank(carl);
        uint256 got = h.withdraw(mkt);
        assertLt(got, pa, "redeemed at mtm, not the stale overstated poolAssets");

        // the winner can still close — the exit did not strand them
        _adv(1);
        IH2Market.Order memory c = _order(alicePk, true, false, 1e18, 0, 51_000e18, 1000, 1);
        _pushOrder(51_000e18, c, _sign(alicePk, c), 0);
        assertEq(h.activePositionId(alice, mkt), 0, "winner closed, pool covered the payout");
    }

    /// ENTRY: traders net-down ⇒ a depositor mints against the (higher) MTM, so NO outsized shares.
    function test_mtm_entryNoOutsizedShares() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(1);
        _pushMark(49_000e18, 0, 0, 0); // alice down 1000e18 → pool MTM-richer
        IH2Market.VaultView memory v = h.vaultOf(mkt);
        assertEq(v.mtmValue - v.poolAssets, 1000e18, "pool richer by the unrealized loss");
        uint256 ts = v.totalShares; uint256 pa = v.poolAssets; uint256 mtm = v.mtmValue;

        usdm.mint(bob, 1_000e18);
        vm.prank(bob); h.deposit(mkt, 1_000e18);
        uint256 got = h.stakeOf(mkt, bob).shares;
        uint256 naive = (1_000e18 * (ts + 1)) / (pa + 1);   // poolAssets-basis = the exploit
        uint256 fair  = (1_000e18 * (ts + 1)) / (mtm + 1);  // mtm-basis = what we mint
        assertEq(got, fair, "minted against mtm");
        assertLt(got, naive, "no outsized mint");
    }

    /// ILLIQUID: traders net-down ⇒ mtm > poolAssets, so a full redemption exceeds liquid cash and
    /// reverts; once the position settles into the pool, the withdrawal succeeds.
    function test_mtm_withdrawRevertsWhenIlliquid() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(1);
        _pushMark(49_900e18, 0, 0, 0); // loss 100e18 (< col) → mtm = pa + 100 > pa
        uint256 shares = h.stakeOf(mkt, carl).shares;
        vm.prank(carl); h.requestUnstake(mkt, shares);
        _adv(uint256(TERM) + 1);
        _pushMark(49_900e18, 0, 0, 0); // operator keeps the feed fresh; the illiquidity is the point
        vm.prank(carl);
        vm.expectRevert(IH2Market.InsufficientLiquidity.selector);
        h.withdraw(mkt);

        // settle the loser into the pool, then the full redemption fits
        _adv(1);
        IH2Market.Order memory c = _order(alicePk, true, false, 1e18, 0, 49_900e18, 1000, 1);
        _pushOrder(49_900e18, c, _sign(alicePk, c), 0);
        assertEq(h.activePositionId(alice, mkt), 0, "loss settled");
        vm.prank(carl);
        uint256 got = h.withdraw(mkt);
        assertGt(got, 0, "withdraw succeeds after settlement");
    }

    // ============================================================
    // owed winnings (a winning close the pool couldn't fully pay)
    // ============================================================

    /// @dev Zero fee + zero cut so owed math is exact: payoutNet = col + effPnl, owed = win − avail.
    function _feesZero() internal pure returns (IH2Market.FeeParams memory) {
        return IH2Market.FeeParams({
            openFlatPpm: 0, openLinearScale: 0, openQuadScale: 0,
            closeFlatPpm: 0, closeLinearScale: 0, closeQuadScale: 0,
            cutInterceptPpm: 0, cutSlopePpm: 0, maxCutPpm: 0,
            maxBuilderFeePpm: 0
        });
    }

    function _mkMarket(IH2Market.FeeParams memory fp) internal returns (uint256 m) {
        vm.prank(op);
        m = h.createMarket(token, fp, _risk(0), _oracleParams(), _spread(), address(reg));
    }

    function _orderOn(uint256 m, uint256 pk, bool isLong, bool isOpen, uint256 size, uint256 lev,
                      uint256 target, uint256 nonce)
        internal view returns (IH2Market.Order memory)
    {
        return IH2Market.Order({
            user: vm.addr(pk), marketId: m, isLong: isLong, isOpen: isOpen,
            size: size, leverage: lev, targetPrice: target, maxSlippageBps: 2000,
            deadline: uint64(block.timestamp + 1 hours), channel: 0, nonce: nonce,
            builder: address(0), builderFeePpm: 0
        });
    }

    function _pushOrderOn(uint256 m, uint256 mark, IH2Market.Order memory o, bytes memory sig) internal {
        _refresh(mark);
        bytes memory data = abi.encode(m, uint8(IH2Market.ActionKind.Order_), abi.encode(o, sig));
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h), data: data });
        vm.prank(op);
        oracle.pushWithParams(feedId, mark, 0, 0, 0, int32(0), calls);
    }

    function _openLongOn(uint256 m, uint256 pk, uint256 size, uint256 lev, uint256 mark, uint256 nonce)
        internal returns (uint256 id)
    {
        _adv(1);
        IH2Market.Order memory o = _orderOn(m, pk, true, true, size, lev, mark, nonce);
        _pushOrderOn(m, mark, o, _sign(pk, o));
        id = h.activePositionId(vm.addr(pk), m);
    }

    function _closeAllOn(uint256 m, uint256 pk, uint256 mark, uint256 nonce) internal {
        _adv(1);
        IH2Market.PositionView memory p = h.positions(h.activePositionId(vm.addr(pk), m));
        IH2Market.Order memory c = _orderOn(m, pk, p.isLong, false, p.size, 0, mark, nonce);
        _pushOrderOn(m, mark, c, _sign(pk, c));
    }

    /// @dev Assert a WinningsOwed(market,user,entryId,amount) was emitted by `h` among recorded logs.
    function _assertWinningsOwed(uint256 m, address user, uint256 entryId, uint256 amount) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("WinningsOwed(uint256,address,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(h) || logs[i].topics[0] != sig) continue;
            if (uint256(logs[i].topics[1]) != m) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) != user) continue;
            (uint256 eid, uint256 amt) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(eid, entryId, "owed entryId"); assertEq(amt, amount, "owed amount");
            found = true;
        }
        assertTrue(found, "WinningsOwed emitted");
    }

    function _seedOn(uint256 m, address who, uint256 amount) internal {
        usdm.mint(who, amount);
        vm.startPrank(who);
        usdm.approve(address(h), type(uint256).max);
        h.deposit(m, amount);
        vm.stopPrank();
    }

    /// @dev Strand `alice`: a 1000e18-win long closed against a `seed`-sized pool. Returns (market,
    /// owed). With zero fees: col = 500e18, win = 1000e18, payout = col + seed, owed = win − seed.
    function _strandAliceWinner(uint256 seed, uint256 nonceBase) internal returns (uint256 m, uint256 owed) {
        m = _mkMarket(_feesZero());
        _adv(1); _pushMark(50_000e18, 0, 0, 0);
        _seedOn(m, carl, seed);
        _openLongOn(m, alicePk, 1e18, 100, 50_000e18, nonceBase);
        _closeAllOn(m, alicePk, 51_000e18, nonceBase + 1);
        owed = 1000e18 - seed; // win − avail (avail == seed; no fees to shift it)
    }

    /// Stranded winner: the close does NOT revert, pays what's liquid (col + pool), and enqueues the
    /// rest as owed — senior to LPs, FIFO. Cash leaving the contract equals the payout (conservation).
    function test_owed_strandedWinnerPaysPartialAndEnqueues() public {
        uint256 m = _mkMarket(_feesZero());
        _adv(1); _pushMark(50_000e18, 0, 0, 0);
        _seedOn(m, carl, 300e18);
        _openLongOn(m, alicePk, 1e18, 100, 50_000e18, 0);

        uint256 hBefore = usdm.balanceOf(address(h));
        uint256 aBefore = usdm.balanceOf(alice);

        vm.recordLogs();
        _closeAllOn(m, alicePk, 51_000e18, 1);
        _assertWinningsOwed(m, alice, 0, 700e18);

        assertEq(h.owedOf(m), 700e18, "shortfall enqueued (win 1000 - pool 300)");
        assertEq(usdm.balanceOf(alice) - aBefore, 800e18, "paid col 500 + liquid pool 300");
        assertEq(hBefore - usdm.balanceOf(address(h)), 800e18, "only the payout left the contract");
        assertEq(h.vaultOf(m).poolAssets, 0, "pool fully drained to its reservation");
        (, uint256 amt, uint256 claimed, uint256 claimable) = h.owedEntry(m, 0);
        assertEq(amt, 700e18); assertEq(claimed, 0); assertEq(claimable, 0, "nothing fundable yet");
    }

    /// FIFO, no race: a later owed entry cannot claim ahead of an earlier one, whoever calls first.
    function test_owed_fifoNoRace() public {
        uint256 m = _mkMarket(_feesZero());
        _adv(1); _pushMark(50_000e18, 0, 0, 0);
        _seedOn(m, carl, 300e18);
        _openLongOn(m, alicePk, 1e18, 100, 50_000e18, 0); // entry 0 (alice) enqueues first
        _openLongOn(m, bobPk,   1e18, 100, 50_000e18, 0); // entry 1 (bob) enqueues after
        _closeAllOn(m, alicePk, 51_000e18, 1);            // alice owed 700 (drains the 300 pool)
        _closeAllOn(m, bobPk,   51_000e18, 1);            // bob owed 1000 (pool already at reservation)

        assertEq(h.owedOf(m), 1700e18, "both shortfalls queued");
        _seedOn(m, carl, 400e18); // refill 400 — funds the HEAD (alice), not enough to reach bob

        (, , , uint256 aliceClaimable) = h.owedEntry(m, 0);
        (, , , uint256 bobClaimable)   = h.owedEntry(m, 1);
        assertEq(aliceClaimable, 400e18, "head funded first");
        assertEq(bobClaimable, 0, "junior entry cannot jump the queue");

        vm.prank(bob);
        vm.expectRevert(IH2Market.ZeroAmount.selector);
        h.claimWinnings(m, 1); // bob cannot pull alice's funding

        uint256 bal = usdm.balanceOf(alice);
        vm.prank(alice);
        assertEq(h.claimWinnings(m, 0), 400e18, "alice claims the funded head");
        assertEq(usdm.balanceOf(alice) - bal, 400e18);
        assertEq(h.owedOf(m), 1300e18, "700-400 + bob's 1000 remain");
    }

    /// A refill lets the owed be claimed in pieces as the pool fills — partial, then the rest.
    function test_owed_refillThenClaimPartialThenFull() public {
        (uint256 m, uint256 owed) = _strandAliceWinner(300e18, 0); // owed 700
        assertEq(owed, 700e18);

        _seedOn(m, carl, 400e18);
        uint256 b0 = usdm.balanceOf(alice);
        vm.prank(alice);
        assertEq(h.claimWinnings(m, 0), 400e18, "claims what the refill funds");
        assertEq(usdm.balanceOf(alice) - b0, 400e18);
        assertEq(h.owedOf(m), 300e18);

        _seedOn(m, carl, 300e18); // fund the remainder
        uint256 b1 = usdm.balanceOf(alice);
        vm.prank(alice);
        assertEq(h.claimWinnings(m, 0), 300e18, "claims the rest");
        assertEq(usdm.balanceOf(alice) - b1, 300e18);
        assertEq(h.owedOf(m), 0, "fully paid");

        vm.prank(alice);
        vm.expectRevert(IH2Market.ZeroAmount.selector);
        h.claimWinnings(m, 0); // nothing left
    }

    /// Owed is senior to LPs: an LP withdrawal can only drain the pool ABOVE the owed reservation.
    function test_owed_seniorToLps() public {
        (uint256 m, ) = _strandAliceWinner(300e18, 0); // owed 700, pool drained to 0
        _seedOn(m, carl, 1000e18);                     // refill: pool 1000, outstanding 700

        uint256 shares = h.stakeOf(m, carl).shares;
        vm.prank(carl); h.requestUnstake(m, shares);
        _adv(uint256(TERM) + 1);
        _pushMark(51_000e18, 0, 0, 0); // keep primary fresh for the withdraw

        vm.prank(carl);
        uint256 got = h.withdraw(m);
        assertApproxEqAbs(got, 300e18, 1, "LP pulls only the pool above the owed reservation");
        assertApproxEqAbs(h.vaultOf(m).poolAssets, 700e18, 1, "the owed stays backed");
        assertEq(h.owedOf(m), 700e18, "alice's senior claim intact");
    }

    /// Funded-only credit-as-collateral: an open draws the user's CLAIMABLE owed first, then the
    /// wallet — never an unfunded IOU. A position never opens on credit the pool can't back.
    function test_owed_fundedCreditAsCollateral() public {
        (uint256 m, ) = _strandAliceWinner(300e18, 0); // alice owed 700 (entry 0), pool 0
        _seedOn(m, carl, 400e18);                      // fund 400 of alice's owed

        uint256 wallet0 = usdm.balanceOf(alice);
        uint256 id = _openLongOn(m, alicePk, 1e18, 100, 50_000e18, 2); // needs col 500e18

        assertEq(h.positions(id).col, 500e18, "collateral assembled");
        assertEq(wallet0 - usdm.balanceOf(alice), 100e18, "only the 100 remainder pulled from the wallet");
        (, , uint256 claimed, ) = h.owedEntry(m, 0);
        assertEq(claimed, 400e18, "the funded owed was drawn into collateral");
        assertEq(h.owedOf(m), 300e18, "unfunded remainder still owed");
        assertEq(h.vaultOf(m).poolAssets, 0, "drawn owed left the pool as collateral");
    }

    /// Waive on deep insolvency (drainable < fees): the trader is paid down to their collateral, the
    /// unrealized fees are NOT credited (operator forgoes rake on cash the pool never funded), and
    /// conservation holds — cash leaving equals the payout.
    function test_owed_waiveFeesWhenDrainBelowFees() public {
        uint256 m = _mkMarket(_fees()); // real fees + cut
        _adv(1); _pushMark(50_000e18, 0, 0, 0);
        _seedOn(m, carl, 10e18);        // tiny pool: drainable ≪ the close's fees
        uint256 id = _openLongOn(m, alicePk, 1e18, 100, 50_000e18, 0);
        uint256 col = h.positions(id).col; // col after the open fee

        uint256 hBefore = usdm.balanceOf(address(h));
        uint256 aBefore = usdm.balanceOf(alice);
        _closeAllOn(m, alicePk, 60_000e18, 1); // huge win; pool can't fund even the fees

        uint256 paid = usdm.balanceOf(alice) - aBefore;
        assertEq(paid, col, "paid exactly the collateral - fees above the drain are waived");
        assertEq(hBefore - usdm.balanceOf(address(h)), paid, "only the payout left (conservation)");
        assertGt(h.owedOf(m), 0, "the rest is owed");
    }

    // ============================================================
    // LP pricing through a primary outage (fallback adverse band)
    // ============================================================

    /// @dev Primary goes stale (no push past primaryStaleSecs=300s) while the fallback is refreshed.
    function _primaryStaleFallbackFresh(uint256 fbPrice1e18) internal {
        _adv(400);
        fallbackFeed.setAnswer(int256(fbPrice1e18 / 1e10));
        fallbackFeed.setUpdatedAt(block.timestamp);
    }

    /// Primary fresh ⇒ the normal regime: LP NAV is the primary-mark MTM, stale flag false.
    function test_lpPricing_freshPrimaryUsesNormalNav() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(1); _pushMark(50_000e18, 0, 0, 0);
        (uint256 depNav, bool s1) = h.lpNav(mkt, false);
        (uint256 wdNav,  bool s2) = h.lpNav(mkt, true);
        assertEq(depNav, h.mtm(mkt), "deposit NAV == primary MTM");
        assertEq(wdNav,  h.mtm(mkt), "withdraw NAV == primary MTM");
        assertFalse(s1); assertFalse(s2);
        assertFalse(h.vaultOf(mkt).stale, "not stale");
    }

    /// Primary stale + fallback fresh: deposit prices at the HIGH adverse edge (fewer shares),
    /// withdraw at the LOW edge (less out), and the edges span the fbCloseSpread band. vaultOf flags
    /// the regime. A 1e18 long: ±0.2% of 50_000 = ±100 price ⇒ ±100e18 price PnL.
    function test_lpPricing_staleFallbackAdverseBand() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        uint256 flat = h.mtm(mkt); // primary mark still 50_000 ⇒ alice flat ⇒ NAV == poolAssets
        _primaryStaleFallbackFresh(50_000e18);

        assertTrue(h.vaultOf(mkt).stale, "vaultOf surfaces the stale regime");
        (uint256 depNav, bool s1) = h.lpNav(mkt, false);
        (uint256 wdNav,  bool s2) = h.lpNav(mkt, true);
        assertTrue(s1 && s2, "stale");
        assertEq(depNav, flat + 100e18, "deposit at the high edge (long +PnL, pool owes more)");
        assertEq(wdNav,  flat - 100e18, "withdraw at the low edge");
        assertGt(depNav, flat); assertLt(wdNav, flat);
        assertEq(depNav - wdNav, 200e18, "edges span the fbCloseSpread band (2000 ppm on 1e18 long)");

        // A real deposit mints FEWER shares than the flat-fallback NAV would.
        uint256 ts = h.vaultOf(mkt).totalShares;
        usdm.mint(bob, 1_000e18);
        vm.prank(bob); uint256 shares = h.deposit(mkt, 1_000e18);
        assertLt(shares, 1_000e18 * (ts + 1) / (flat + 1), "adverse-high NAV mints fewer shares");
    }

    /// Both sources stale ⇒ LPs wait: deposit and withdraw revert NoFreshPrice. claimWinnings does not.
    function test_lpPricing_bothStaleRevertsNoFreshPrice() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(400); // no primary push, no fallback refresh ⇒ both stale

        usdm.mint(bob, 1_000e18);
        vm.prank(bob);
        vm.expectRevert(IH2Market.NoFreshPrice.selector);
        h.deposit(mkt, 1_000e18);

        uint256 shares = h.stakeOf(mkt, carl).shares;
        vm.prank(carl); h.requestUnstake(mkt, shares);
        _adv(uint256(TERM) + 1); // cooldown elapses, still no fresh price
        vm.prank(carl);
        vm.expectRevert(IH2Market.NoFreshPrice.selector);
        h.withdraw(mkt);
    }

    /// claimWinnings needs no mark: a stranded winner can still claim during a full price outage.
    function test_lpPricing_claimWinningsWorksDuringOutage() public {
        (uint256 m, ) = _strandAliceWinner(300e18, 0); // alice owed 700, pool 0
        _seedOn(m, carl, 400e18);                      // fund 400 while fresh
        _adv(400);                                     // both sources go stale

        // Sanity: an LP action on m is blocked now.
        usdm.mint(bob, 1e18);
        vm.prank(bob);
        vm.expectRevert(IH2Market.NoFreshPrice.selector);
        h.deposit(m, 1e18);

        uint256 b0 = usdm.balanceOf(alice);
        vm.prank(alice);
        assertEq(h.claimWinnings(m, 0), 400e18, "winner claims through the outage");
        assertEq(usdm.balanceOf(alice) - b0, 400e18);
    }
}

/// @dev A builder registry that always reverts — for the market's try/catch safety test.
contract RevertingRegistry is IBuilderRegistry {
    function isBuilder(address) external pure override returns (bool) {
        revert("nope");
    }
}

/// @dev H2Market with getters for the internal MTM aggregates + value (test-only).
contract H2MarketHarness is H2Market {
    constructor(address usdm_, address oracle_) H2Market(usdm_, oracle_) {}

    function aggOf(uint256 marketId, bool isLong) external view returns (uint256, uint256, int256) {
        OpenAgg storage a = _openAgg[marketId][isLong];
        return (a.sumSize, a.sumEntryW, a.sumCheckW);
    }

    function mtm(uint256 marketId) external view returns (uint256) {
        return _mtmValue(marketId);
    }

    function lpNav(uint256 marketId, bool isWithdraw) external view returns (uint256 nav, bool stale) {
        return _lpNav(marketId, isWithdraw);
    }
}
