// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title IPreHook
/// @notice Interface for pre-execution hooks in Plasma Vault operations
/// @dev Implemented by contracts that provide pre-execution validation or setup logic
interface IPreHook {
    /// @notice Executes the pre-hook logic
    /// @dev Called before the main vault operation
    function run() external;
}
