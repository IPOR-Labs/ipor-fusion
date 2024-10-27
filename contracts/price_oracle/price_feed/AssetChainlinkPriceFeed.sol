// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "../ext/AggregatorV3Interface.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IPriceFeed} from "./IPriceFeed.sol";

/// @title Price feed for any Asset in USD in 8 decimals using Chainlink oracles for AssetX/AssetY and AssetY/USD pairs in a specific network.
contract AssetChainlinkPriceFeed is IPriceFeed {
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @dev Asset for which the price feed is provided
    address public immutable ASSET_X;

    /// @dev Price Oracle for pair ASSET A, ASSET B in Chainlink
    address public immutable ASSET_X_ASSET_Y_CHAINLINK_FEED;

    /// @dev  Price Oracle for pair ASSET B USD in Chainlink
    address public immutable ASSET_Y_USD_CHAINLINK_FEED;

    uint256 private immutable PRICE_DENOMINATOR;

    /// @param assetX_ Asset for which the price feed is provided in USD in a specific network
    /// @param assetXAssetYChainlinkFeed_ Chainlink feed for ASSET/ETH in a specific network
    /// @param assetYUsdChainlinkFeed_ Chainlink feed for ETH/USD in a specific network
    constructor(address assetX_, address assetXAssetYChainlinkFeed_, address assetYUsdChainlinkFeed_) {
        if (assetX_ == address(0) || assetXAssetYChainlinkFeed_ == address(0) || assetYUsdChainlinkFeed_ == address(0)) {
            revert Errors.WrongAddress();
        }

        ASSET_X = assetX_;
        ASSET_X_ASSET_Y_CHAINLINK_FEED = assetXAssetYChainlinkFeed_;
        ASSET_Y_USD_CHAINLINK_FEED = assetYUsdChainlinkFeed_;

        uint256 assetXAssetYChainlinkFeedDecimals = AggregatorV3Interface(ASSET_X_ASSET_Y_CHAINLINK_FEED).decimals();
        uint256 assetYUsdChainlinkFeedDecimals = AggregatorV3Interface(ASSET_Y_USD_CHAINLINK_FEED).decimals();

        PRICE_DENOMINATOR = 10 ** ((assetXAssetYChainlinkFeedDecimals + assetYUsdChainlinkFeedDecimals) - _decimals());
    }

    function decimals() external pure override returns (uint8) {
        return _decimals();
    }

    function latestRoundData()
    external
    view
    override
    returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        (, int256 assetYPriceInUsd, , , ) = AggregatorV3Interface(ASSET_Y_USD_CHAINLINK_FEED).latestRoundData();
        (, int256 assetXPriceInAssetY, , , ) = AggregatorV3Interface(ASSET_X_ASSET_Y_CHAINLINK_FEED).latestRoundData();

        return (
            uint80(0),
            Math.mulDiv(assetYPriceInUsd.toUint256(), assetXPriceInAssetY.toUint256(), PRICE_DENOMINATOR).toInt256(),
            0,
            0,
            0
        );
    }

    function _decimals() internal pure returns (uint8) {
        return 8;
    }
}
