// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AggregatorV3Interface} from "../ext/AggregatorV3Interface.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IPriceFeed} from "./IPriceFeed.sol";

/// @title Price feed for WETH  in USD in 8 decimals
contract WETHPriceFeed is IPriceFeed {

    /// @dev  Price Oracle for pair ETH USD in Chainlink
    /// @dev Arbitrum 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612
    /// @dev Ethereum 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
    address public immutable ETH_USD_CHAINLINK_FEED;

    /// @param ethUsdChainlinkFeed_ Chainlink feed for ETH/USD in a specific network
    constructor(address ethUsdChainlinkFeed_) {
        if (ethUsdChainlinkFeed_ == address(0)) {
            revert Errors.WrongAddress();
        }

        ETH_USD_CHAINLINK_FEED = ethUsdChainlinkFeed_;

        /// @def Notice! It is enough to check during construction not during runtime because ETH_CHAINLINK_FEED is immutable not upgradeable contract and decimals are not expected to change.
        if (_decimals() != AggregatorV3Interface(ETH_USD_CHAINLINK_FEED).decimals()) {
            revert Errors.WrongDecimals();
        }

    }

    function decimals() external view override returns (uint8) {
        return _decimals();
    }

    function latestRoundData()
    external
    view
    override
    returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {

        (, int256 answer, , ,) = AggregatorV3Interface(ETH_USD_CHAINLINK_FEED).latestRoundData();

        /// @dev wETH/ETH ratio is 1:1
        return (uint80(0), answer, 0, 0, 0);
    }

    function _decimals() internal view returns (uint8) {
        return 8;
    }
}
