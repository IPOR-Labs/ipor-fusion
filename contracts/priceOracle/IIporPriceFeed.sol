// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

interface IIporPriceFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound);
}
