// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPriceFeed} from "./IPriceFeed.sol";

/// @title UsdPriceFeed
/// @notice A price feed implementation that always returns 1 USD in 8 decimals
/// @dev Can be used as a fallback for this stablecoin which does not have a price feed on a particular chain
contract USDPriceFeed is IPriceFeed {
    /// @notice The number of decimals used in price values
    // solhint-disable-next-line const-name-snakecase
    uint8 public constant override decimals = 8;

    /// @notice Returns the latest price data for this feed
    /// @dev Always returns 1 USD with 8 decimals precision (1e8)
    /// @return roundId The round ID (always 0)
    /// @return price The price in USD with 8 decimals (1e8 = $1.00)
    /// @return startedAt The timestamp when the round started (always 0)
    /// @return time The timestamp when the round was updated (always 0)
    /// @return answeredInRound The round ID in which the answer was computed (always 0)
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        return (0, 1e8, 0, 0, 0);
    }
}
