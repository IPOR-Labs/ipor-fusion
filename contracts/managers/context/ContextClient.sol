// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IContextClient} from "./IContextClient.sol";
import {ContextClientStorageLib} from "./ContextClientStorageLib.sol";
import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";

/**
 * @title ContextClient
 * @notice Contract that manages context for operations requiring sender context
 * @dev Implements IContextClient interface using ContextClientStorageLib for storage
 *
 * Role-based permissions:
 * - TECH_CONTEXT_MANAGER_ROLE: Can setup and clear context
 * - No other roles have direct access to context management
 *
 * Function permissions:
 * - setupContext: Restricted to TECH_CONTEXT_MANAGER_ROLE
 * - clearContext: Restricted to TECH_CONTEXT_MANAGER_ROLE
 * - getSenderFromContext: Internal function, no direct role restrictions
 *
 * Security considerations:
 * - Context operations are restricted to authorized managers only
 * - Single context enforcement prevents context manipulation
 * - Clear separation between context setup and usage
 *
 * @custom:security-contact security@yourproject.com
 */
abstract contract ContextClient is IContextClient, AccessManagedUpgradeable {
    /// @dev Custom errors for context-related operations
    /// @notice Thrown when attempting to set context when one is already active
    error ContextAlreadySet();
    /// @notice Thrown when attempting to clear or access context when none is set
    error ContextNotSet();
    /// @notice Thrown when an unauthorized address attempts to interact with protected functions
    error UnauthorizedSender();

    /**
     * @notice Sets up the context with the provided sender address
     * @param sender The address to set as the context sender
     * @dev Only callable by authorized contracts through the restricted modifier
     * @dev Uses ContextClientStorageLib for persistent storage
     * @custom:security Non-reentrant by design through single context restriction
     * @custom:access Restricted to TECH_CONTEXT_MANAGER_ROLE only
     * @custom:throws ContextAlreadySet if a context is currently active
     */
    function setupContext(address sender) external override restricted {
        // Ensure context isn't already set
        if (ContextClientStorageLib.isContextSenderSet()) {
            revert ContextAlreadySet();
        }

        ContextClientStorageLib.setContextSender(sender);

        emit ContextSet(sender);
    }

    /**
     * @notice Clears the current context
     * @dev Only callable by authorized contracts through the restricted modifier
     * @dev Uses ContextClientStorageLib for persistent storage
     * @custom:security Should always be called after context operations are complete
     * @custom:access Restricted to TECH_CONTEXT_MANAGER_ROLE only
     * @custom:throws ContextNotSet if no context is currently set
     */
    function clearContext() external override restricted {
        // Get current context before clearing
        address currentSender = ContextClientStorageLib.getSenderFromContext();

        // Ensure context is set before clearing
        if (currentSender == address(0)) {
            revert ContextNotSet();
        }

        ContextClientStorageLib.clearContextStorage();

        emit ContextCleared(currentSender);
    }

    /**
     * @notice Retrieves the sender address from the current context
     * @dev Internal view function for derived contracts to access context
     * @return address The sender address stored in the current context
     * @custom:security Ensure proper access control in derived contracts
     * @custom:access Internal function - access controlled by inheriting contracts
     */
    function getSenderFromContext() internal view returns (address) {
        return ContextClientStorageLib.getSenderFromContext();
    }
}
