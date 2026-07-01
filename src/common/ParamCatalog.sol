// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/// @title ParamCatalog
/// @notice Per-token configuration shared by every venue. Two cadences:
///   - `Structural` — owner-set, infrequent. Tick granularity (price + size), leverage range,
///     position lifetime, house cut.
///   - `Risk` — maker-set, frequent. Fee, slippage scales (in sizeUnits), OI caps,
///     oracle deviation band.
///
/// **Internal-vs-external scale.** External API takes price/size in 1e18-scaled USDM-wei and
/// asset-wei (unchanged from prior versions). Internally, every venue stores priceUnits and
/// sizeUnits compressed by `priceTick` and `sizeTick` — fitting easily in uint128 each.
/// Math is overflow-safe in tick-space because realistic priceUnits/sizeUnits are far below
/// 2^96. The conversion is transparent: outputs (events, views) emit 1e18-scaled values.
library ParamCatalog {
    uint256 internal constant SCALE                = 1e18;
    uint256 internal constant BPS_DENOM            = 10_000;
    uint256 internal constant MAX_FEE_BPS          = 1_000;
    uint256 internal constant MAX_HOUSE_CUT_BPS    = 5_000;
    uint256 internal constant MIN_LEVERAGE_FLOOR   = 1;
    uint256 internal constant MAX_LEVERAGE_CEIL    = 10_000;
    uint256 internal constant MIN_DURATION_FLOOR   = 1 hours;
    uint256 internal constant MAX_DURATION_CEIL    = 365 days;
    uint256 internal constant MAX_DEV_BPS          = 10_000;

    /// @notice Skew is measured in PPM (parts per million). 1 PPM = 0.0001%.
    /// fillPrice = mark × (SKEW_SCALE ± skew) / SKEW_SCALE.
    uint256 internal constant SKEW_SCALE           = 1_000_000;
    uint256 internal constant SKEW_SCALE_SQRT      = 1_000;

    error BadPriceTick();
    error BadSizeTick();
    error BadSlippageScale();
    error BadFee();
    error BadLeverage();
    error BadDuration();
    error BadHouseCut();
    error BadDevBand();

    /// @notice Owner-set, infrequent.
    ///
    /// **Winnings cut.** The house rake on positive effective PnL is a per-token linear ramp,
    /// not a flat rate. No cut applies until profit clears `cutIntercept` (USDM-wei). Above it,
    /// the cut *rate* ramps by `cutSlopeBps` per whole USDM of profit beyond the intercept,
    /// capped at `maxCutBps`. The cut is then that rate applied to the *whole* effective PnL.
    /// See `houseCut`.
    struct Structural {
        uint256 priceTick;          // min price step in 1e18 USDM-wei (e.g., 1e18 = $1 step)
        uint256 sizeTick;           // min size step in 1e18 asset-wei (e.g., 1e10 = 1 sat for BTC)
        uint256 notionalScale;      // derived = (priceTick × sizeTick) / 1e18; USDM-wei per (priceUnit × sizeUnit)
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 maxPositionDuration;
        uint256 cutIntercept;       // USDM-wei of profit below which no winnings cut is taken
        uint256 cutSlopeBps;        // cut-rate bps added per whole USDM of profit above the intercept
        uint256 maxCutBps;          // ceiling on the winnings-cut rate
    }

    /// @notice Maker-set, frequent. Slippage scales are in `sizeUnits`, not 1e18.
    struct Risk {
        uint256 openFeeBps;
        uint256 linearScale;        // larger ⇒ less linear slippage; type(uint256).max ⇒ off
        uint256 quadScale;          // larger ⇒ less quadratic slippage; type(uint256).max ⇒ off
        uint256 maxPositionNotional;// USDM-wei (1e18 scale) — unchanged convention
        uint256 maxOIGross;         // USDM-wei
        uint256 maxOISkew;          // USDM-wei
        uint256 maxDevBps;
    }

    struct TokenParams {
        Structural structural;
        Risk       risk;
    }

    /// @notice Validate `structural` AND compute the derived `notionalScale` field.
    /// `usdmDenom = 10 ** usdm.decimals()` is passed by the venue (cached in its constructor).
    /// `notionalScale = priceTick × sizeTick / usdmDenom` — must be a positive integer.
    function validateAndDeriveStructural(Structural memory p, uint256 usdmDenom) internal pure {
        if (p.priceTick == 0)                                                revert BadPriceTick();
        if (p.sizeTick == 0)                                                 revert BadSizeTick();
        uint256 product = p.priceTick * p.sizeTick;
        if (product < usdmDenom || product % usdmDenom != 0)                 revert BadPriceTick();
        p.notionalScale = product / usdmDenom;
        if (p.minLeverage < MIN_LEVERAGE_FLOOR ||
            p.maxLeverage > MAX_LEVERAGE_CEIL ||
            p.minLeverage > p.maxLeverage)                                   revert BadLeverage();
        if (p.maxPositionDuration < MIN_DURATION_FLOOR ||
            p.maxPositionDuration > MAX_DURATION_CEIL)                       revert BadDuration();
        if (p.maxCutBps > MAX_HOUSE_CUT_BPS)                                 revert BadHouseCut();
    }

    /// @notice Winnings cut on positive effective PnL, as a per-token linear ramp.
    /// `rate = min(maxBps, slopeBps × (effPnl − intercept) / usdmDenom)` for `effPnl > intercept`
    /// (else 0), and the returned cut is `effPnl × rate / BPS_DENOM`. `usdmDenom = 10**decimals`
    /// makes `slopeBps` read as "bps of rate per 1 whole USDM of profit above the intercept".
    function houseCut(
        uint256 effPnl,
        uint256 intercept,
        uint256 slopeBps,
        uint256 maxBps,
        uint256 usdmDenom
    ) internal pure returns (uint256) {
        if (effPnl <= intercept) return 0;
        uint256 rateBps = slopeBps * (effPnl - intercept) / usdmDenom;
        if (rateBps > maxBps) rateBps = maxBps;
        return effPnl * rateBps / BPS_DENOM;
    }

    /// @notice Validate `risk`. `linearScale` and `quadScale` are interpreted in sizeUnits.
    function validateRisk(Risk memory p) internal pure {
        if (p.openFeeBps > MAX_FEE_BPS)                                      revert BadFee();
        if (p.linearScale == 0 || p.quadScale == 0)                          revert BadSlippageScale();
        if (p.maxDevBps > MAX_DEV_BPS)                                       revert BadDevBand();
    }
}
