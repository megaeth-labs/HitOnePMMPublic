// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/// @title MarkRing
/// @notice Packed ring-buffer encodings for IsoMarket — both the mark-price history (32-bit
/// packed entries, 8/slot) and the parallel funding-rate ring (int64 entries, 4/slot).
///
/// Mark ring: each slot is 32 bits — int24 priceDelta (tick units, high 24) + uint8 timeDelta
/// (10ms units, low 8). `timeDelta == 0` is the SENTINEL — written by `setMark` after a
/// >2.55s gap to signal a ring discontinuity. Walk-back consumers must stop at a sentinel.
/// A same-10ms-window push is forbidden by the contract (caller must coalesce).
///
/// Rate ring: parallel, same RING_LEN, packed as 4 × int64 per uint256 slot. Each slot
/// records the funding rate active during the interval *ending* at the matching mark entry's
/// timestamp. `setMark` writes the unchanged `currentRate`. `setMarkAndRate` writes the
/// **old** rate (which was active during the ending interval), then updates `currentRate`.
library MarkRing {
    error MarkDeltaTooLarge();

    uint256 internal constant RING_LEN              = 200;
    uint256 internal constant MARK_SLOT_COUNT       = 25;     // RING_LEN / 8
    uint256 internal constant MARK_ENTRIES_PER_SLOT = 8;
    uint256 internal constant MARK_ENTRY_BITS       = 32;
    uint256 internal constant RATE_SLOT_COUNT       = 50;     // RING_LEN / 4
    uint256 internal constant RATE_ENTRIES_PER_SLOT = 4;
    uint256 internal constant RATE_ENTRY_BITS       = 64;
    uint256 internal constant GAP_UNIT_MS           = 10;
    uint256 internal constant GAP_MAX_UNITS         = 255;    // 2.55 seconds — beyond this, sentinel
    int256  internal constant PRICE_DELTA_MIN       = -8_388_608;   // -2^23
    int256  internal constant PRICE_DELTA_MAX       =  8_388_607;   //  2^23 - 1
    uint8   internal constant TIME_DELTA_SENTINEL   = 0;

    /// @notice Pack a non-sentinel (priceDelta, timeDelta) entry. timeDelta must be in [1, 255].
    /// Reverts if priceDelta does not fit in int24.
    function packEntry(int256 priceDelta, uint256 timeDelta) internal pure returns (uint32) {
        if (priceDelta < PRICE_DELTA_MIN || priceDelta > PRICE_DELTA_MAX) revert MarkDeltaTooLarge();
        uint32 timeBits  = uint32(timeDelta) & 0xFF;
        uint32 priceBits = uint32(uint256(priceDelta) & 0xFFFFFF);
        return (priceBits << 8) | timeBits;
    }

    /// @notice Sentinel entry: timeDelta = 0, priceDelta = 0. Marks a gap > 2.55s in the ring.
    /// Walk-backs stop here.
    function sentinelEntry() internal pure returns (uint32) {
        return 0;
    }

    function isSentinel(uint32 entry) internal pure returns (bool) {
        return (entry & 0xFF) == 0;
    }

    /// @notice Unpack a non-sentinel entry. Callers must check `isSentinel` first.
    function unpackEntry(uint32 entry) internal pure returns (int256 priceDelta, uint256 timeDelta) {
        timeDelta = entry & 0xFF;
        uint32 priceBits = entry >> 8;
        // Sign-extend the 24-bit two's-complement value.
        if (priceBits & 0x800000 != 0) {
            priceDelta = int256(uint256(priceBits)) - (1 << 24);
        } else {
            priceDelta = int256(uint256(priceBits));
        }
    }

    /// @notice Write `entry` at logical index `head` (mod RING_LEN) in the mark ring.
    function writeMarkEntry(uint256[MARK_SLOT_COUNT] storage ring, uint256 head, uint32 entry) internal {
        uint256 idx     = head % RING_LEN;
        uint256 slotIdx = idx / MARK_ENTRIES_PER_SLOT;
        uint256 inSlot  = idx % MARK_ENTRIES_PER_SLOT;
        uint256 shift   = inSlot * MARK_ENTRY_BITS;
        uint256 mask    = uint256(type(uint32).max) << shift;
        uint256 cur     = ring[slotIdx];
        ring[slotIdx]   = (cur & ~mask) | (uint256(entry) << shift);
    }

    /// @notice Read mark entry at logical index `idx`.
    function readMarkEntry(uint256[MARK_SLOT_COUNT] storage ring, uint256 idx) internal view returns (uint32) {
        uint256 wrapped = idx % RING_LEN;
        uint256 slotIdx = wrapped / MARK_ENTRIES_PER_SLOT;
        uint256 inSlot  = wrapped % MARK_ENTRIES_PER_SLOT;
        return uint32(ring[slotIdx] >> (inSlot * MARK_ENTRY_BITS));
    }

    /// @notice Write a signed int64 rate at logical index `head` in the rate ring.
    function writeRateEntry(uint256[RATE_SLOT_COUNT] storage ring, uint256 head, int64 rate) internal {
        uint256 idx     = head % RING_LEN;
        uint256 slotIdx = idx / RATE_ENTRIES_PER_SLOT;
        uint256 inSlot  = idx % RATE_ENTRIES_PER_SLOT;
        uint256 shift   = inSlot * RATE_ENTRY_BITS;
        uint256 mask    = uint256(type(uint64).max) << shift;
        uint256 packed  = uint256(uint64(rate)) & type(uint64).max;
        uint256 cur     = ring[slotIdx];
        ring[slotIdx]   = (cur & ~mask) | (packed << shift);
    }

    /// @notice Read int64 rate at logical index `idx` in the rate ring.
    function readRateEntry(uint256[RATE_SLOT_COUNT] storage ring, uint256 idx) internal view returns (int64) {
        uint256 wrapped = idx % RING_LEN;
        uint256 slotIdx = wrapped / RATE_ENTRIES_PER_SLOT;
        uint256 inSlot  = wrapped % RATE_ENTRIES_PER_SLOT;
        return int64(uint64(ring[slotIdx] >> (inSlot * RATE_ENTRY_BITS)));
    }
}
