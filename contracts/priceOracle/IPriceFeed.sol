// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @title Interface for custom calculating the latest price of an asset, expressed in USD, standard like Chainlink's AggregatorV3Interface
interface IPriceFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound);
}
