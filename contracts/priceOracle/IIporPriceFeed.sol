// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

interface IIporPriceFeed {
    function getLatestPrice() external view returns (uint256);
}