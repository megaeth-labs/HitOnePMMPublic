// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import { IAggregatorV3 } from "../../src/common/IAggregatorV3.sol";

/// @notice Trivial Chainlink-style aggregator mock for testing.
contract MockAggregatorV3 is IAggregatorV3 {
    int256  internal _answer;
    uint256 internal _updatedAt;
    uint8   internal _decimals;

    constructor(uint8 decimals_, int256 initialAnswer, uint256 initialUpdatedAt) {
        _decimals  = decimals_;
        _answer    = initialAnswer;
        _updatedAt = initialUpdatedAt;
    }

    function setAnswer(int256 a) external { _answer = a; }
    function setUpdatedAt(uint256 t) external { _updatedAt = t; }

    function decimals() external view returns (uint8) { return _decimals; }

    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
    ) {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}
