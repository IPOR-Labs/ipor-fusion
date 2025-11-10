// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title IEnsoExecutor Interface
/// @notice Interface for EnsoExecutor contract that manages asset balances
interface IEnsoExecutor {
    /// @notice Get balance from EnsoExecutor
    /// @return assetAddress The address of the asset
    /// @return assetBalance The balance amount of the asset
    function getBalance() external view returns (address assetAddress, uint256 assetBalance);
}
