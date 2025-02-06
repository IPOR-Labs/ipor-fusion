// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {PreHooksLib} from "./PreHooksLib.sol";
import {IPreHook} from "./IPreHook.sol";

/// @title PreHooksHandler
/// @notice Handles pre-execution hooks for Plasma Vault operations
/// @dev Abstract contract that manages the execution of pre-hooks in the vault system.
///      This handler is responsible for:
///      - Safely executing pre-hook logic through delegate calls
///      - Managing hook execution flow
///      - Ensuring proper hook validation
///
///      Security considerations:
///      - Uses delegate calls for hook execution
///      - Implements null address checks
///      - Maintains execution context safety
///
///      Integration notes:
///      - Contracts inheriting this handler must ensure proper access control
///      - Pre-hooks are optional and can be skipped if implementation is not set
abstract contract PreHooksHandler {
    using Address for address;

    /// @notice Executes pre-hooks for a given operation
    /// @dev Internal function that runs the pre-hook logic through a delegate call.
    ///      The function:
    ///      - Retrieves the pre-hook implementation for the given selector
    ///      - Skips execution if no implementation is found (address(0))
    ///      - Executes the hook via delegate call to maintain vault's context
    ///      - Preserves the vault's storage context during execution
    /// @param selector_ The function selector of the operation requiring pre-hook execution
    function _runPreHooks(bytes4 selector_) internal {
        address implementation = PreHooksLib.getPreHookImplementation(selector_);
        if (implementation == address(0)) {
            return;
        }
        implementation.functionDelegateCall(abi.encodeWithSelector(IPreHook.run.selector, selector_));
    }
}
