// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { MarkRing } from "./MarkRing.sol";

/// @title FundingIndex
/// @notice Pure-function helpers for the funding accumulator. The accumulator integrates the
/// funding rate over time in price-scaled units; positions checkpoint it at open and pay the
/// delta at close. Two rate conventions are supported:
///   - absolute  ({effectiveAt}/{stepBack}): rate is an absolute price-scaled per-second value.
///     Used by IsoMarket.
///   - percentage ({effectiveAtPct}/{stepBackPct}): rate is a signed fixed-point FRACTION per
///     second and the absolute per-second amount is derived as `ratePct/PCT_SCALE * mark1e18`.
///     Used by HitOneMarket so the effective funding tracks the mark without the maker rescaling it.
/// Both conventions leave the index in the same price-scaled units, so settlement is identical.
library FundingIndex {
    /// @dev Denominator for percentage rates: real_fraction_per_sec = ratePct / PCT_SCALE. The
    /// scale is 100 * 2**63, so the full int64 range spans ±1%/sec (raw 2**63 ⇒ 0.01 = 1%/sec).
    /// This both hard-caps the rate at 1%/sec and uses the whole int64 for the useful range.
    int256 internal constant PCT_SCALE = int256(100) << 63;

    /// @notice Extrapolate the committed `fundingIndex` forward to `targetTime` at `rate`.
    /// `fundingIndex` is the value committed at `lastPushAt`. Caller ensures targetTime ≥ lastPushAt.
    function effectiveAt(int128 fundingIndex, int64 rate, uint64 lastPushAt, uint64 targetTime)
        internal pure returns (int128)
    {
        unchecked {
            uint64 dt = targetTime - lastPushAt;
            // rate * dt overflow: rate ≤ ~10^18 (signed), dt ≤ ~10^10 (≈ 300y of seconds).
            // Product fits in int256 comfortably; downcast to int128 with a guarded add.
            int256 delta = int256(rate) * int256(uint256(dt));
            int256 out   = int256(fundingIndex) + delta;
            require(out >= type(int128).min && out <= type(int128).max, "FI: overflow");
            return int128(out);
        }
    }

    /// @notice Subtract `rate * duration` from `indexAtK` to step backward one ring segment.
    function stepBack(int128 indexAtK, int64 rate, uint64 durationSec)
        internal pure returns (int128)
    {
        unchecked {
            int256 delta = int256(rate) * int256(uint256(durationSec));
            int256 out   = int256(indexAtK) - delta;
            require(out >= type(int128).min && out <= type(int128).max, "FI: overflow");
            return int128(out);
        }
    }

    /// @notice Percentage variant of {effectiveAt}. `ratePct` is a signed fixed-point fraction/sec
    /// (real = ratePct / PCT_SCALE) and `mark1e18` is the mark held over [lastPushAt, targetTime];
    /// the per-second absolute funding is `ratePct/PCT_SCALE * mark1e18`. Multiplication is checked
    /// (the mark factor makes the product far larger than the absolute path), so an out-of-range
    /// product reverts rather than wraps.
    function effectiveAtPct(int128 fundingIndex, int64 ratePct, uint256 mark1e18, uint64 lastPushAt, uint64 targetTime)
        internal pure returns (int128)
    {
        uint64 dt    = targetTime - lastPushAt;
        int256 delta = (int256(ratePct) * int256(mark1e18) * int256(uint256(dt))) / PCT_SCALE;
        int256 out   = int256(fundingIndex) + delta;
        require(out >= type(int128).min && out <= type(int128).max, "FI: overflow");
        return int128(out);
    }

    /// @notice Percentage variant of {stepBack}. `mark1e18` is the mark held over the segment.
    function stepBackPct(int128 indexAtK, int64 ratePct, uint256 mark1e18, uint64 durationSec)
        internal pure returns (int128)
    {
        int256 delta = (int256(ratePct) * int256(mark1e18) * int256(uint256(durationSec))) / PCT_SCALE;
        int256 out   = int256(indexAtK) - delta;
        require(out >= type(int128).min && out <= type(int128).max, "FI: overflow");
        return int128(out);
    }
}
