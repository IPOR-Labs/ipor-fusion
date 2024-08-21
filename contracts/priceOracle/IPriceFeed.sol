// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

/// @title Interface for custom calculating the latest price of an asset, expressed in USD, standard like Chainlink's AggregatorV3Interface
interface IPriceFeed {
    /// @notice Returns the number of decimals of the price
    /// @return The number of decimals of the price
    function decimals() external view returns (uint8);

    /// @notice Returns the latest price of an asset, expressed in USD
    /// @return roundId The round ID from which the data was retrieved
    /// @return price The latest price of the asset, expressed in USD, with 8 decimals
    /// @return startedAt Timestamp of the start of the round
    /// @return time Timestamp of the data of the round
    /// @return answeredInRound The round ID from which the answer was retrieved
    /// @dev Notice! The price is expressed always in 8 decimals.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound);
}
