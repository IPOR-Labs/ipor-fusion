// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICollSurplusPool {
    /// @notice Collateral surplus credited to `_account` by liquidations and not yet claimed
    function getCollateral(address _account) external view returns (uint256);
}
