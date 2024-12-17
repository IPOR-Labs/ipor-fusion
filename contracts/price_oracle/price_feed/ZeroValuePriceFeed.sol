// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "./IPriceFeed.sol";

/// @title Zero Value Price Feed
/// @notice A price feed implementation that always returns zero values
/// @dev Can be used as a fallback or for testing purposes
contract ZeroValuePriceFeed is IPriceFeed {
    function decimals() external view returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound) {
        return (0, 0, 0, 0, 0);
    }
}
