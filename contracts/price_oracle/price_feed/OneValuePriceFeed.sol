// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPriceFeed} from "./IPriceFeed.sol";

/// @title One Value Price Feed
/// @notice A price feed implementation that always returns one value
/// @dev Can be used as a fallback or for testing purposes
contract OneValuePriceFeed is IPriceFeed {
    function decimals() external view returns (uint8) {
        return 8;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        return (0, 1, 0, 0, 0);
    }
}
