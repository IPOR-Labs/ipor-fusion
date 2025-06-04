// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IPriceFeed {
    function fetchPrice() external returns (uint256, bool);

    function fetchRedemptionPrice() external returns (uint256, bool);

    function lastGoodPrice() external view returns (uint256);
}
