// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title IContextClient
 * @notice Interface for contracts that need to manage sender context in vault operations
 * @dev This interface defines the core functionality for context management in the vault system
 *
 * The context system allows for:
 * - Temporary impersonation of transaction senders
 * - Secure execution of operations with delegated permissions
 * - Clean context management with setup and cleanup
 *
 * Security considerations:
 * - Only authorized contracts should be allowed to set/clear context
 * - Context should never be nested (one context at a time)
 * - Context must always be cleared after use
 * - Proper access control should be implemented by contracts using this interface
 */
interface IContextClient {
    /**
     * @notice Sets up a new context with the specified sender address
     * @param sender The address to be set as the context sender
     * @dev Requirements:
     * - Must be called by an authorized contract
     * - No active context should exist when setting up new context
     * - Emits ContextSet event on successful setup
     * @custom:security Should implement access control to prevent unauthorized context manipulation
     */
    function setupContext(address sender) external;

    /**
     * @notice Clears the current active context
     * @dev Requirements:
     * - Must be called by an authorized contract
     * - An active context must exist
     * - Emits ContextCleared event on successful cleanup
     * @custom:security Should always be called after context operations are complete
     */
    function clearContext() external;

    /**
     * @notice Emitted when a new context is successfully set
     * @param sender The address that was set as the context sender
     * @dev This event should be monitored for context tracking and auditing
     */
    event ContextSet(address indexed sender);

    /**
     * @notice Emitted when an active context is cleared
     * @param sender The address that was removed from the context
     * @dev This event should be monitored to ensure proper context cleanup
     */
    event ContextCleared(address indexed sender);

    /**
     * @notice Expected errors that may be thrown by implementations
     * @dev Implementations should define these errors:
     * - ContextAlreadySet(): When attempting to set context while one is active
     * - ContextNotSet(): When attempting to clear or access non-existent context
     * - UnauthorizedSender(): When unauthorized address attempts to modify context
     */
}
