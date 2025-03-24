// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPreHook} from "../IPreHook.sol";

/// @title PauseFunctionPreHook
/// @notice Pre-execution hook for pausing specific functions in the Plasma Vault
/// @dev This contract implements the IPreHook interface to provide emergency pause functionality
///      for individual functions in the vault system. When this hook is registered for a function,
///      any attempt to call that function will revert.
///
/// Key features:
/// - Simple and gas efficient implementation
/// - Function-level granular pausing
/// - Clear error messaging with function selector information
/// - Zero-state contract (no storage variables)
///
/// Usage:
/// - Register this hook for specific function selectors through PlasmaVaultGovernance
/// - When registered, any call to the associated function will revert
/// - Useful for emergency situations or planned maintenance
/// - Can be used to pause restricted (access-controlled) functions
///
/// Security considerations:
/// - Protected by PlasmaVault's access control for hook registration
/// - No state variables that could be manipulated
/// - Immutable behavior once deployed
/// - Cannot be bypassed when registered
///

contract PauseFunctionPreHook is IPreHook {
    /// @notice Error thrown when attempting to call a paused function
    /// @param selector The function selector that was attempted to be called
    error FunctionPaused(bytes4 selector);

    /// @notice Executes the pre-hook logic to prevent function execution
    /// @dev Always reverts with FunctionPaused error containing the selector
    /// @param selector_ The function selector that triggered this pre-hook
    function run(bytes4 selector_) external pure {
        revert FunctionPaused(selector_);
    }
}
