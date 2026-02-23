// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IPriceFeed} from "../../../contracts/price_oracle/price_feed/IPriceFeed.sol";

/// @title Mock Price Feed with configurable timestamp for testing
contract MockPriceFeedWithTimestamp is IPriceFeed {
    int256 private _price;
    uint8 private _decimals;
    uint256 private _updatedAt;

    constructor(int256 price_, uint8 decimals_, uint256 updatedAt_) {
        _price = price_;
        _decimals = decimals_;
        _updatedAt = updatedAt_;
    }

    function setPrice(int256 price_) external {
        _price = price_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        return (0, _price, 0, _updatedAt, 0);
    }
}
