// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "../ext/AggregatorV3Interface.sol";
import {IPriceFeed} from "./IPriceFeed.sol";

/// @title AssetChainlinkPriceFeed
/// @notice Price feed for any Asset in USD using two Chainlink price feeds
/// @dev Uses AssetX/AssetY and AssetY/USD pairs to calculate AssetX/USD price
contract AssetChainlinkPriceFeed is IPriceFeed {
    using SafeCast for int256;
    using SafeCast for uint256;

    error ZeroAddress();
    error InvalidDecimals();
    error NegativeOrZeroPrice();

    /// @dev Asset for which the price feed is provided
    address public immutable ASSET_X;

    /// @dev Price Oracle for pair ASSET_X/ASSET_Y in Chainlink
    address public immutable ASSET_X_ASSET_Y_CHAINLINK_FEED;

    /// @dev Price Oracle for pair ASSET_Y/USD in Chainlink
    address public immutable ASSET_Y_USD_CHAINLINK_FEED;

    /// @dev Denominator used to normalize price decimals
    uint256 private immutable PRICE_DENOMINATOR;

    /// @notice Constructor to initialize the price feed
    /// @param assetX_ Asset for which the price feed is provided in USD
    /// @param assetXAssetYChainlinkFeed_ Chainlink feed for ASSET_X/ASSET_Y
    /// @param assetYUsdChainlinkFeed_ Chainlink feed for ASSET_Y/USD
    constructor(address assetX_, address assetXAssetYChainlinkFeed_, address assetYUsdChainlinkFeed_) {
        if (
            assetX_ == address(0) || assetXAssetYChainlinkFeed_ == address(0) || assetYUsdChainlinkFeed_ == address(0)
        ) {
            revert ZeroAddress();
        }

        ASSET_X = assetX_;
        ASSET_X_ASSET_Y_CHAINLINK_FEED = assetXAssetYChainlinkFeed_;
        ASSET_Y_USD_CHAINLINK_FEED = assetYUsdChainlinkFeed_;

        uint256 assetXAssetYChainlinkFeedDecimals = AggregatorV3Interface(ASSET_X_ASSET_Y_CHAINLINK_FEED).decimals();
        uint256 assetYUsdChainlinkFeedDecimals = AggregatorV3Interface(ASSET_Y_USD_CHAINLINK_FEED).decimals();

        if (assetXAssetYChainlinkFeedDecimals > 18 || assetYUsdChainlinkFeedDecimals > 18) {
            revert InvalidDecimals();
        }

        PRICE_DENOMINATOR = 10 ** ((assetXAssetYChainlinkFeedDecimals + assetYUsdChainlinkFeedDecimals) - _decimals());
    }

    /// @inheritdoc IPriceFeed
    function decimals() external pure override returns (uint8) {
        return _decimals();
    }

    /// @inheritdoc IPriceFeed
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        (
            uint80 assetYUsdRoundId,
            int256 assetYPriceInUsd,
            uint256 assetYStartedAt,
            uint256 assetYUpdatedAt,
            uint80 assetYAnsweredInRound
        ) = AggregatorV3Interface(ASSET_Y_USD_CHAINLINK_FEED).latestRoundData();

        (
            uint80 assetXYRoundId,
            int256 assetXPriceInAssetY,
            uint256 assetXYStartedAt,
            uint256 assetXYUpdatedAt,
            uint80 assetXYAnsweredInRound
        ) = AggregatorV3Interface(ASSET_X_ASSET_Y_CHAINLINK_FEED).latestRoundData();

        if (assetYPriceInUsd <= 0 || assetXPriceInAssetY <= 0) revert NegativeOrZeroPrice();

        price = Math
            .mulDiv(assetYPriceInUsd.toUint256(), assetXPriceInAssetY.toUint256(), PRICE_DENOMINATOR)
            .toInt256();

        return (
            _combineRoundIds(assetXYRoundId, assetYUsdRoundId),
            price,
            Math.min(assetYStartedAt, assetXYStartedAt),
            Math.min(assetYUpdatedAt, assetXYUpdatedAt),
            _combineRoundIds(assetXYAnsweredInRound, assetYAnsweredInRound)
        );
    }

    /// @dev Internal function to return the number of decimals
    function _decimals() internal pure returns (uint8) {
        return 8;
    }

    /// @dev Combines two round IDs into a single ID
    /// @param id1 First round ID
    /// @param id2 Second round ID
    /// @return Combined round ID
    function _combineRoundIds(uint80 id1, uint80 id2) internal pure returns (uint80) {
        return uint80((uint256(id1) + uint256(id2)) / 2);
    }
}
