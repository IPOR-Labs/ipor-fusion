// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "../ext/AggregatorV3Interface.sol";
import {IPriceFeed} from "./IPriceFeed.sol";

/// @title DualCrossReferencePriceFeed
/// @notice Price feed for any Asset in USD using exactly two cross-referenced Oracle Aggregator price feeds
/// @dev Uses AssetX/AssetY and AssetY/USD pairs to calculate AssetX/USD price
contract DualCrossReferencePriceFeed is IPriceFeed {
    using SafeCast for int256;
    using SafeCast for uint256;

    error ZeroAddress();
    error InvalidDecimals();
    error NegativeOrZeroPrice();

    /// @dev Asset for which the price feed is provided
    address public immutable ASSET_X;

    /// @dev Price Oracle for pair ASSET_X/ASSET_Y in Oracles Aggregator
    address public immutable ASSET_X_ASSET_Y_ORACLE_FEED;

    /// @dev Price Oracle for pair ASSET_Y/USD in Oracles Aggregator
    address public immutable ASSET_Y_USD_ORACLE_FEED;

    /// @dev Denominator used to normalize price decimals
    uint256 private immutable PRICE_DENOMINATOR;

    /// @dev Flag indicating if we need to multiply or divide by the denominator
    bool private immutable SHOULD_MULTIPLY;

    /// @notice Constructor to initialize the price feed
    /// @param assetX_ Asset for which the price feed is provided in USD
    /// @param assetXAssetYOracleFeed_ Oracle feed for ASSET_X/ASSET_Y
    /// @param assetYUsdOracleFeed_ Oracle feed for ASSET_Y/USD
    constructor(address assetX_, address assetXAssetYOracleFeed_, address assetYUsdOracleFeed_) {
        if (assetX_ == address(0) || assetXAssetYOracleFeed_ == address(0) || assetYUsdOracleFeed_ == address(0)) {
            revert ZeroAddress();
        }

        ASSET_X = assetX_;
        ASSET_X_ASSET_Y_ORACLE_FEED = assetXAssetYOracleFeed_;
        ASSET_Y_USD_ORACLE_FEED = assetYUsdOracleFeed_;

        uint256 assetXAssetYOracleFeedDecimals = AggregatorV3Interface(ASSET_X_ASSET_Y_ORACLE_FEED).decimals();
        uint256 assetYUsdOracleFeedDecimals = AggregatorV3Interface(ASSET_Y_USD_ORACLE_FEED).decimals();

        if (assetXAssetYOracleFeedDecimals < 8 || assetYUsdOracleFeedDecimals < 8) {
            revert InvalidDecimals();
        }

        uint256 totalFeedDecimals = assetXAssetYOracleFeedDecimals + assetYUsdOracleFeedDecimals;
        uint256 targetDecimals = _decimals();

        if (totalFeedDecimals >= targetDecimals) {
            // Need to divide by denominator
            SHOULD_MULTIPLY = false;
            PRICE_DENOMINATOR = 10 ** (totalFeedDecimals - targetDecimals);
        } else {
            // Need to multiply by denominator
            SHOULD_MULTIPLY = true;
            PRICE_DENOMINATOR = 10 ** (targetDecimals - totalFeedDecimals);
        }
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
        ) = AggregatorV3Interface(ASSET_Y_USD_ORACLE_FEED).latestRoundData();

        (
            uint80 assetXYRoundId,
            int256 assetXPriceInAssetY,
            uint256 assetXYStartedAt,
            uint256 assetXYUpdatedAt,
            uint80 assetXYAnsweredInRound
        ) = AggregatorV3Interface(ASSET_X_ASSET_Y_ORACLE_FEED).latestRoundData();

        if (assetYPriceInUsd <= 0 || assetXPriceInAssetY <= 0) revert NegativeOrZeroPrice();

        uint256 rawPrice = assetYPriceInUsd.toUint256() * assetXPriceInAssetY.toUint256();

        if (SHOULD_MULTIPLY) {
            price = (rawPrice * PRICE_DENOMINATOR).toInt256();
        } else {
            price = Math.mulDiv(rawPrice, 1, PRICE_DENOMINATOR).toInt256();
        }

        return (0, price, Math.min(assetYStartedAt, assetXYStartedAt), Math.min(assetYUpdatedAt, assetXYUpdatedAt), 0);
    }

    /// @dev Internal function to return the number of decimals
    function _decimals() internal pure returns (uint8) {
        return 18;
    }
}
