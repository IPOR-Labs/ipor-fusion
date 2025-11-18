// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPreHook} from "../../contracts/handlers/pre_hooks/IPreHook.sol";

/// @title SimpleExecutePreHook
/// @notice Simple pre-hook that only emits an Execute event with a name
/// @dev Used for testing purposes to verify pre-hook execution
contract SimpleExecutePreHook is IPreHook {
    /// @notice Emitted when the pre-hook is executed
    /// @param name The name passed to the constructor
    /// @param selector The function selector of the main operation
    event Execute(uint256 name, bytes4 selector);

    /// @notice The name that will be emitted in the Execute event
    uint256 public immutable name;

    /// @param name_ The name to be emitted in the Execute event
    constructor(uint256 name_) {
        name = name_;
    }

    /// @notice Executes the pre-hook logic - only emits Execute event
    /// @param selector_ The function selector of the main operation that will be executed
    function run(bytes4 selector_) external {
        emit Execute(name, selector_);
    }
}
