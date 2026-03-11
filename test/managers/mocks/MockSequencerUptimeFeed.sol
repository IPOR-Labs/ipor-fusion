// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "../../../contracts/price_oracle/ext/AggregatorV3Interface.sol";

/// @title Mock Sequencer Uptime Feed for testing
contract MockSequencerUptimeFeed is AggregatorV3Interface {
    int256 private _answer; // 0 = UP, 1 = DOWN
    uint256 private _startedAt;
    uint256 private _updatedAt;

    constructor(int256 answer_, uint256 startedAt_, uint256 updatedAt_) {
        _answer = answer_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
    }

    function setStartedAt(uint256 startedAt_) external {
        _startedAt = startedAt_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function decimals() external pure override returns (uint8) {
        return 0;
    }

    function description() external pure override returns (string memory) {
        return "Mock Sequencer Uptime Feed";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80
    ) external pure override returns (uint80, int256, uint256, uint256, uint80) {
        revert("Not implemented");
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _answer, _startedAt, _updatedAt, 1);
    }
}
