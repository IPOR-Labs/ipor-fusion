// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title IPreHook
/// @notice Interface for pre-execution hooks in Plasma Vault operations
/// @dev This interface defines the contract that handles pre-execution validations and setup logic for vault operations.
///      Pre-hooks are essential components that run before main vault operations to ensure proper state management,
///      perform validations, or prepare the system for the upcoming operation.
///      Implementations must be gas-efficient and reentrant-safe.
interface IPreHook {
    /// @notice Executes the pre-hook logic before the main vault operation
    /// @dev This function is called by the vault before executing the main operation.
    ///      Implementations should:
    ///      - Be gas efficient
    ///      - Include proper access control
    ///      - Handle all edge cases
    ///      - Revert on validation failures
    ///      The function must not be susceptible to reentrancy attacks
    /// @param selector_ The function selector of the main operation that will be executed
    function run(bytes4 selector_) external;
}
