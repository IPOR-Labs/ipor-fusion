// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "../AggregatorV3Interface.sol";

import {IPriceFeed} from "../IPriceFeed.sol";
import {ISavingsDai} from "./ISavingsDai.sol";

contract SDaiPriceFeed is IPriceFeed {
    using SafeCast for int256;
    using SafeCast for uint256;
    // dai/usd
    address public constant DAI_CHAINLINK_FEED = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    address public constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        (, int256 answer, , , ) = AggregatorV3Interface(DAI_CHAINLINK_FEED).latestRoundData();
        uint256 sdaiExchangeRatio = ISavingsDai(SDAI).convertToAssets(1e18);
        return (uint80(0), Math.mulDiv(answer.toUint256(), sdaiExchangeRatio, 1e18).toInt256(), 0, 0, 0);
    }
}
