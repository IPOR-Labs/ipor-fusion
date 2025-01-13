// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {PreHooksLib} from "./PreHooksLib.sol";
import {IPreHook} from "./IPreHook.sol";

/// @title PreHooksHandler
/// @notice Handles pre-execution hooks for Plasma Vault operations
/// @dev Provides validation and setup logic to run before main vault operations
abstract contract PreHooksHandler {
    using Address for address;

    function _runPreHooks(bytes4 selector) internal {
        address implementation = PreHooksLib.getPreHookImplementation(selector);
        if (implementation == address(0)) {
            return;
        }
        implementation.functionDelegateCall(abi.encodeWithSelector(IPreHook.run.selector));
    }
}
