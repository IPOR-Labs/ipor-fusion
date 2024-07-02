// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceFeed} from "./../IPriceFeed.sol";

contract USDMPriceFeed is IPriceFeed {
    using SafeCast for int256;
    using SafeCast for uint256;

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        int answer = 1e18;
        return (uint80(0), answer, 0, 0, 0);
    }
}
