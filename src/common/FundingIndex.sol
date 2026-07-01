// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import { MarkRing } from "./MarkRing.sol";

/// @title FundingIndex
/// @notice Pure-function helpers for IsoMarket's funding accumulator. The accumulator integrates
/// the funding rate over time in price-scaled units; positions checkpoint it at open and pay the
/// delta at close. Per-token state is owned by IsoMarket; this library only provides math.
library FundingIndex {
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
}
