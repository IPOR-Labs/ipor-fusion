// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "../ext/AggregatorV3Interface.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IPriceFeed} from "./IPriceFeed.sol";

/// @title Price feed for any Asset in USD in 8 decimals using Chainlink oracles for ETH/USD and ASSET/ETH pairs in a specific network.
contract AssetChainlinkPriceFeed is IPriceFeed {
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @dev Asset for which the price feed is provided
    address public immutable ASSET;

    /// @dev Price Oracle for pair ASSET, ETH in Chainlink
    address public immutable ASSET_ETH_CHAINLINK_FEED;

    /// @dev  Price Oracle for pair ETH USD in Chainlink
    address public immutable ETH_USD_CHAINLINK_FEED;

    uint256 private immutable PRICE_DENOMINATOR;

    /// @param asset_ Asset for which the price feed is provided in a specific network
    /// @param assetEthChainlinkFeed_ Chainlink feed for ASSET/ETH in a specific network
    /// @param ethUsdChainlinkFeed_ Chainlink feed for ETH/USD in a specific network
    constructor(address asset_, address assetEthChainlinkFeed_, address ethUsdChainlinkFeed_) {
        if (asset_ == address(0) || assetEthChainlinkFeed_ == address(0) || ethUsdChainlinkFeed_ == address(0)) {
            revert Errors.WrongAddress();
        }

        ASSET = asset_;
        ASSET_ETH_CHAINLINK_FEED = assetEthChainlinkFeed_;
        ETH_USD_CHAINLINK_FEED = ethUsdChainlinkFeed_;

        uint256 assetEthChainlinkFeedDecimals = AggregatorV3Interface(ASSET_ETH_CHAINLINK_FEED).decimals();
        uint256 ethUsdChainlinkFeedDecimals = AggregatorV3Interface(ETH_USD_CHAINLINK_FEED).decimals();

        PRICE_DENOMINATOR = 10 ** ((assetEthChainlinkFeedDecimals + ethUsdChainlinkFeedDecimals) - _decimals());
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
        (, int256 ethPriceInUsd, , , ) = AggregatorV3Interface(ETH_USD_CHAINLINK_FEED).latestRoundData();
        (, int256 assetPriceInEth, , , ) = AggregatorV3Interface(ASSET_ETH_CHAINLINK_FEED).latestRoundData();

        return (
            uint80(0),
            Math.mulDiv(ethPriceInUsd.toUint256(), assetPriceInEth.toUint256(), PRICE_DENOMINATOR).toInt256(),
            0,
            0,
            0
        );
    }

    function _decimals() internal pure returns (uint8) {
        return 8;
    }
}
