// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @notice Test double for MegaETH's high-precision-timestamp system contract
/// (0x6342000000000000000000000000000000000002). The canonical contract stores the µs
/// timestamp in Oracle slot 0 and returns it from `timestamp()`; this mirrors that, so tests
/// can `vm.etch` this code at the canonical address and `vm.store(addr, 0, micros)` to drive it.
contract MockHighPrecisionTimestamp {
    function timestamp() external view returns (uint256 t) {
        assembly { t := sload(0) }
    }
}
