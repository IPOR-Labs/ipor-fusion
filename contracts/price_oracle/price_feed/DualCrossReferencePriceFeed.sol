// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AggregatorV3Interface} from "../ext/AggregatorV3Interface.sol";
import {IPriceFeed} from "./IPriceFeed.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

/// @title DualCrossReferencePriceFeed
/// @notice Price feed for any Asset in USD using exactly two cross-referenced Oracle Aggregator price feeds
/// @dev Uses AssetX/AssetY and AssetY/USD pairs to calculate AssetX/USD price
/// @dev Example usage with Chainlink price feeds:
/// @dev To calculate BTC/USD price using ETH/USD and BTC/ETH feeds:
/// @dev - assetX: BTC token address (0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599)
/// @dev - assetXAssetYOracleFeed: BTC/ETH Chainlink price feed (0xdeb288F737066589598e9214E782fa5A8eD689e8)
/// @dev - assetYUsdOracleFeed: ETH/USD Chainlink price feed (0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)
/// @dev The resulting price feed will calculate: BTC/USD = (BTC/ETH) * (ETH/USD)
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

        if (assetXPriceInAssetY <= 0 || assetYPriceInUsd <= 0) revert NegativeOrZeroPrice();

        price = IporMath
            .convertToWad(
                assetXPriceInAssetY.toUint256() * assetYPriceInUsd.toUint256(),
                AggregatorV3Interface(ASSET_X_ASSET_Y_ORACLE_FEED).decimals() +
                    AggregatorV3Interface(ASSET_Y_USD_ORACLE_FEED).decimals()
            )
            .toInt256();

        return (0, price, 0, 0, 0);
    }

    /// @dev Internal function to return the number of decimals
    function _decimals() internal pure returns (uint8) {
        return 18;
    }
}
