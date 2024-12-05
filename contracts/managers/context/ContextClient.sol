// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "./IContextClient.sol";
import "./ContextClientStorageLib.sol";
import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";

/// @title ContextClient
/// @notice Contract that manages context for operations requiring sender context
/// @dev Implements IContextClient interface using ContextClientStorageLib for storage
abstract contract ContextClient is IContextClient, AccessManagedUpgradeable {
    /// @dev Custom errors
    error ContextAlreadySet();
    error ContextNotSet();
    error UnauthorizedSender();

    /// @notice Sets up the context with the provided sender address
    /// @param sender The address to set as the context sender
    /// @dev Only callable by authorized contracts
    function setupContext(address sender) external override restricted {
        // Ensure context isn't already set
        if (ContextClientStorageLib.isContextSet()) {
            revert ContextAlreadySet();
        }

        // Store the context
        ContextClientStorageLib.setContextSender(sender);
    }

    /// @notice Clears the current context
    /// @dev Only callable by authorized contracts
    function clearContext() external override restricted {
        // Ensure context is set before clearing
        if (!ContextClientStorageLib.isContextSet()) {
            revert ContextNotSet();
        }

        // Clear the context
        ContextClientStorageLib.clearContextStorage();
    }
}
