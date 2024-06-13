// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

interface IPriceFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound);
}
