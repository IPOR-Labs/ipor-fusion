// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPriceFeed} from "./IPriceFeed.sol";

/// @title One Value Price Feed
/// @notice A price feed implementation that always returns one value
/// @dev Can be used as a fallback or for testing purposes
contract FixedValuePriceFeed is IPriceFeed {
    int256 public immutable FIXED_PRICE;

    constructor(int256 fixedPrice_) {
        FIXED_PRICE = fixedPrice_;
    }

    function decimals() external view returns (uint8) {
        return 18;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        return (0, FIXED_PRICE, 0, 0, 0);
    }
}
