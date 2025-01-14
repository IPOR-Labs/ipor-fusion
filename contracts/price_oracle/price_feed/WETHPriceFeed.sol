// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AggregatorV3Interface} from "../ext/AggregatorV3Interface.sol";
import {IPriceFeed} from "./IPriceFeed.sol";

/// @title Price feed for WETH in USD
/// @notice Provides price data for WETH/USD pair using Chainlink oracle
/// @dev Returns prices with 8 decimals precision
contract WETHPriceFeed is IPriceFeed {
    /// @notice Custom errors for the contract
    error ZeroAddress();
    error InvalidDecimals();
    error InvalidPrice();
    error StalePrice();

    /// @notice Number of decimals in price feed output
    uint8 private constant PRICE_FEED_DECIMALS = 8;

    /// @notice Chainlink ETH/USD price feed address
    /// @dev Arbitrum 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612
    /// @dev Ethereum 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
    address public immutable ETH_USD_CHAINLINK_FEED;

    event PriceFeedInitialized(address indexed chainlinkFeed);

    /// @notice Constructs the price feed with Chainlink oracle address
    /// @param ethUsdChainlinkFeed_ Chainlink feed address for ETH/USD
    /// @dev Validates feed decimals during construction
    constructor(address ethUsdChainlinkFeed_) {
        if (ethUsdChainlinkFeed_ == address(0)) {
            revert ZeroAddress();
        }

        ETH_USD_CHAINLINK_FEED = ethUsdChainlinkFeed_;

        if (PRICE_FEED_DECIMALS != AggregatorV3Interface(ETH_USD_CHAINLINK_FEED).decimals()) {
            revert InvalidDecimals();
        }

        emit PriceFeedInitialized(ethUsdChainlinkFeed_);
    }

    /// @inheritdoc IPriceFeed
    function decimals() external pure override returns (uint8) {
        return PRICE_FEED_DECIMALS;
    }

    /// @inheritdoc IPriceFeed
    /// @dev Returns latest price data from Chainlink oracle
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        (
            uint80 chainlinkRoundId,
            int256 answer,
            uint256 startTime,
            uint256 updateTime,
            uint80 chainlinkAnsweredInRound
        ) = AggregatorV3Interface(ETH_USD_CHAINLINK_FEED).latestRoundData();

        if (answer <= 0) revert InvalidPrice();
        if (updateTime == 0) revert StalePrice();

        // WETH/ETH ratio is always 1:1
        return (chainlinkRoundId, answer, startTime, updateTime, chainlinkAnsweredInRound);
    }

    /// @dev Internal function returning decimals
    function _decimals() internal pure returns (uint8) {
        return PRICE_FEED_DECIMALS;
    }
}
