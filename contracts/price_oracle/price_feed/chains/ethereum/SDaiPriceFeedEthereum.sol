// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "../../../ext/AggregatorV3Interface.sol";

import {IPriceFeed} from "../../IPriceFeed.sol";
import {ISavingsDai} from "../../ext/ISavingsDai.sol";

/// @title Price feed for sDai on Ethereum Mainnet
/// @notice Provides price feed functionality for sDai token by combining Chainlink DAI/USD price with sDai/DAI exchange rate
/// @dev Implements IPriceFeed interface
contract SDaiPriceFeedEthereum is IPriceFeed {
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @dev  Price Oracle for pair DAI USD on Ethereum Mainnet
    address public constant DAI_CHAINLINK_FEED = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    address public constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;

    /// @dev Error when invalid exchange ratio is used
    error InvalidExchangeRatio();

    /// @dev Error when invalid price is used
    error InvalidPrice();

    /// @dev Error when wrong decimals are used
    error WrongDecimals();

    constructor() {
        /// @dev Notice! It is enough to check during construction not during runtime because DAI_CHAINLINK_FEED is immutable not upgradeable contract and decimals are not expected to change.
        if (_decimals() != AggregatorV3Interface(DAI_CHAINLINK_FEED).decimals()) {
            revert WrongDecimals();
        }
    }

    /// @notice Returns the number of decimals for price precision
    /// @return decimals The number of decimal places
    function decimals() external pure override returns (uint8) {
        return _decimals();
    }

    /// @notice Gets the latest price data for sDai in USD
    /// @return roundId The round ID from Chainlink feed
    /// @return price The calculated sDai price in USD (with 8 decimals)
    /// @return startedAt The timestamp when the round started
    /// @return time The timestamp when the price was last updated
    /// @return answeredInRound The round ID in which the answer was computed
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        (
            uint80 chainlinkRoundId,
            int256 answer,
            uint256 startedAt_,
            uint256 updatedAt,
            uint80 chainlinkAnsweredInRound
        ) = AggregatorV3Interface(DAI_CHAINLINK_FEED).latestRoundData();

        if (answer <= 0) revert InvalidPrice();

        uint256 sdaiExchangeRatio = ISavingsDai(SDAI).convertToAssets(1e18);

        if (sdaiExchangeRatio == 0) revert InvalidExchangeRatio();

        return (
            chainlinkRoundId,
            Math.mulDiv(answer.toUint256(), sdaiExchangeRatio, 1e18).toInt256(),
            startedAt_,
            updatedAt,
            chainlinkAnsweredInRound
        );
    }

    function _decimals() internal pure returns (uint8) {
        return 8;
    }
}
