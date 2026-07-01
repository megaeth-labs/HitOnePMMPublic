// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/// @title IHighPrecisionTimestamp
/// @notice MegaETH system contract exposing a microsecond-precision wall-clock timestamp.
/// Canonical address: 0x6342000000000000000000000000000000000002. The value lives in Oracle
/// storage slot 0 and `timestamp()` returns it as microseconds since the Unix epoch. The
/// sequencer maintains the value via system transactions; `update()` reverts under canonical
/// configuration. See https://docs.megaeth.com/spec/system-contracts/high-precision-timestamp
interface IHighPrecisionTimestamp {
    function timestamp() external view returns (uint256);
}
