// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/// @title IAggregatorV3
/// @notice Minimal Chainlink-compatible aggregator interface. Used to read Redstone Bolt
/// feeds on MegaETH (Bolt exposes the standard Chainlink shape).
interface IAggregatorV3 {
    function latestRoundData() external view returns (
        uint80  roundId,
        int256  answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80  answeredInRound
    );
    function decimals() external view returns (uint8);
}
