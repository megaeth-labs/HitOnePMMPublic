// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test }         from "forge-std/Test.sol";
import { ParamCatalog } from "../../src/common/ParamCatalog.sol";

contract ParamCatalogHarness {
    function validateStructural(ParamCatalog.Structural calldata p, uint256 usdmDenom) external pure {
        ParamCatalog.Structural memory pm = p;
        ParamCatalog.validateAndDeriveStructural(pm, usdmDenom);
    }
    function validateRisk(ParamCatalog.Risk calldata p) external pure {
        ParamCatalog.validateRisk(p);
    }
    function houseCut(uint256 effPnl, uint256 intercept, uint256 slopeBps, uint256 maxBps, uint256 usdmDenom)
        external pure returns (uint256)
    {
        return ParamCatalog.houseCut(effPnl, intercept, slopeBps, maxBps, usdmDenom);
    }
}

contract ParamCatalogTest is Test {
    ParamCatalogHarness internal h;
    uint256 internal constant USDM_18 = 1e18;

    function setUp() public { h = new ParamCatalogHarness(); }

    function _okStructural() internal pure returns (ParamCatalog.Structural memory) {
        return ParamCatalog.Structural({
            priceTick: 1e18, sizeTick: 1e10, notionalScale: 0,
            minLeverage: 100, maxLeverage: 1000,
            maxPositionDuration: 30 days,
            cutIntercept: 0, cutSlopeBps: 550, maxCutBps: 550
        });
    }

    function _okRisk() internal pure returns (ParamCatalog.Risk memory) {
        return ParamCatalog.Risk({
            openFeeBps: 10, linearScale: 1e30, quadScale: type(uint256).max,
            maxPositionNotional: 200_000e18,
            maxOIGross: type(uint256).max, maxOISkew: type(uint256).max,
            maxDevBps: 3
        });
    }

    // ---- structural ----

    function test_structuralOk() public view { h.validateStructural(_okStructural(), USDM_18); }

    function test_structuralPriceTickZero() public {
        ParamCatalog.Structural memory p = _okStructural(); p.priceTick = 0;
        vm.expectRevert(ParamCatalog.BadPriceTick.selector);
        h.validateStructural(p, USDM_18);
    }

    function test_structuralSizeTickZero() public {
        ParamCatalog.Structural memory p = _okStructural(); p.sizeTick = 0;
        vm.expectRevert(ParamCatalog.BadSizeTick.selector);
        h.validateStructural(p, USDM_18);
    }

    function test_structuralProductBelowUsdmDenom() public {
        // priceTick × sizeTick < usdmDenom — fails BadPriceTick
        ParamCatalog.Structural memory p = _okStructural();
        p.priceTick = 1; p.sizeTick = 1;       // product = 1 < 1e18
        vm.expectRevert(ParamCatalog.BadPriceTick.selector);
        h.validateStructural(p, USDM_18);
    }

    function test_structuralLeverageInverted() public {
        ParamCatalog.Structural memory p = _okStructural();
        p.minLeverage = 500; p.maxLeverage = 200;
        vm.expectRevert(ParamCatalog.BadLeverage.selector);
        h.validateStructural(p, USDM_18);
    }

    function test_structuralLeverageAboveCeil() public {
        ParamCatalog.Structural memory p = _okStructural(); p.maxLeverage = 20_000;
        vm.expectRevert(ParamCatalog.BadLeverage.selector);
        h.validateStructural(p, USDM_18);
    }

    function test_structuralLeverageBelowFloor() public {
        ParamCatalog.Structural memory p = _okStructural(); p.minLeverage = 0;
        vm.expectRevert(ParamCatalog.BadLeverage.selector);
        h.validateStructural(p, USDM_18);
    }

    function test_structuralDurationTooShort() public {
        ParamCatalog.Structural memory p = _okStructural(); p.maxPositionDuration = 1 minutes;
        vm.expectRevert(ParamCatalog.BadDuration.selector);
        h.validateStructural(p, USDM_18);
    }

    function test_structuralDurationTooLong() public {
        ParamCatalog.Structural memory p = _okStructural(); p.maxPositionDuration = 366 days;
        vm.expectRevert(ParamCatalog.BadDuration.selector);
        h.validateStructural(p, USDM_18);
    }

    function test_structuralHouseCutTooHigh() public {
        ParamCatalog.Structural memory p = _okStructural(); p.maxCutBps = 5001;
        vm.expectRevert(ParamCatalog.BadHouseCut.selector);
        h.validateStructural(p, USDM_18);
    }

    // ---- risk ----

    function test_riskOk() public view { h.validateRisk(_okRisk()); }

    function test_riskFeeTooHigh() public {
        ParamCatalog.Risk memory p = _okRisk(); p.openFeeBps = 1001;
        vm.expectRevert(ParamCatalog.BadFee.selector); h.validateRisk(p);
    }

    function test_riskLinearScaleZero() public {
        ParamCatalog.Risk memory p = _okRisk(); p.linearScale = 0;
        vm.expectRevert(ParamCatalog.BadSlippageScale.selector); h.validateRisk(p);
    }

    function test_riskQuadScaleZero() public {
        ParamCatalog.Risk memory p = _okRisk(); p.quadScale = 0;
        vm.expectRevert(ParamCatalog.BadSlippageScale.selector); h.validateRisk(p);
    }

    function test_riskDevBpsTooHigh() public {
        ParamCatalog.Risk memory p = _okRisk(); p.maxDevBps = 10_001;
        vm.expectRevert(ParamCatalog.BadDevBand.selector); h.validateRisk(p);
    }

    // ---- winnings-cut ramp ----

    function test_houseCutBelowInterceptIsZero() public view {
        // profit $800, intercept $1000 -> no cut
        assertEq(h.houseCut(800e18, 1000e18, 1, 550, USDM_18), 0);
    }

    function test_houseCutAtInterceptIsZero() public view {
        assertEq(h.houseCut(1000e18, 1000e18, 1, 550, USDM_18), 0);
    }

    function test_houseCutOnRamp() public view {
        // profit $1200, intercept $1000, slope 1bps/$ -> rate = 200bps; cut = 1200 * 2% = 24
        assertEq(h.houseCut(1200e18, 1000e18, 1, 550, USDM_18), 24e18);
    }

    function test_houseCutSaturatesAtMax() public view {
        // profit $5000, excess $4000 * 1bps/$ = 4000bps -> capped at 550; cut = 5000 * 5.5% = 275
        assertEq(h.houseCut(5000e18, 1000e18, 1, 550, USDM_18), 275e18);
    }

    function test_houseCutZeroIntercept_flatWhenSlopeSaturates() public view {
        // intercept 0, slope 550 saturates for any profit >= $1 -> behaves like flat 5.5%
        assertEq(h.houseCut(1000e18, 0, 550, 550, USDM_18), 55e18);
        assertEq(h.houseCut(10_000e18, 0, 550, 550, USDM_18), 550e18);
    }
}
