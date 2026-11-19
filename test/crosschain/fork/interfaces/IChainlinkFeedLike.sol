// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice Chainlink aggregator read used by the IL-9654 fork fixture to keep the price feed fresh after a time warp.
interface IChainlinkFeedLike {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
