// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPriceFeed} from "../../contracts/price_oracle/price_feed/IPriceFeed.sol";

contract MutableValuePriceFeed is IPriceFeed {
    int256 private _price;

    constructor(int256 price_) {
        _price = price_;
    }

    function setPrice(int256 price_) external {
        _price = price_;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        return (0, _price, 0, 0, 0);
    }
}
