// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "../../../ext/AggregatorV3Interface.sol";

import {IPriceFeed} from "../../IPriceFeed.sol";
import {IWstETH} from "../../ext/IWstETH.sol";

/// @title Price feed for wstETH on Ethereum Mainnet
contract WstETHPriceFeedEthereum is IPriceFeed {
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @dev Chainlink price feed address for stETH/USD on Ethereum Mainnet
    address public constant STETH_CHAINLINK_FEED = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    /// @dev Wrapped stETH token address
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @dev Minimum price that will be considered valid
    int256 private constant MIN_PRICE = 1e8; // $1

    error WrongDecimals();
    error WrongPrice();
    error InvalidTimestamp();
    error StalePrice();
    error InvalidStEthRatio();

    constructor() {
        if (_decimals() != AggregatorV3Interface(STETH_CHAINLINK_FEED).decimals()) {
            revert WrongDecimals();
        }
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
        (
            uint80 chainlinkRoundId,
            int256 answer,
            uint256 startTime,
            uint256 updateTime,
            uint80 answeredInRoundId
        ) = AggregatorV3Interface(STETH_CHAINLINK_FEED).latestRoundData();

        // Validate Chainlink response
        if (answer <= MIN_PRICE) revert WrongPrice();
        if (updateTime == 0) revert InvalidTimestamp();

        // Get wstETH/stETH ratio
        uint256 stEthRatio = IWstETH(WSTETH).getStETHByWstETH(1e18);
        if (stEthRatio == 0) revert InvalidStEthRatio();

        // Calculate wstETH price
        price = Math.mulDiv(answer.toUint256(), stEthRatio, 1e18).toInt256();

        return (chainlinkRoundId, price, startTime, updateTime, answeredInRoundId);
    }

    function _decimals() internal pure returns (uint8) {
        return 8;
    }
}
