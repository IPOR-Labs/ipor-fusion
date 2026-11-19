// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

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
 * - The context sender is bound to the caller of setupContext (IL-9533): only that caller (the ContextManager) gets
 *   the sender back from _getSenderFromContext. Any other caller during the relayed call, including re-entrant code
 *   reached through it (a venue, a hook, a hooked token), acts as itself. The setter is kept in transient storage
 *   (cleared by clearContext and at the end of the transaction).
 * - Clients deployed before this version return the context sender to every caller while a relayed call runs: on
 *   them, relay only calls that cannot reach untrusted code
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
     * @param sender_ The address to set as the context sender
     * @dev Only callable by authorized contracts through the restricted modifier
     * @dev Uses ContextClientStorageLib for persistent storage
     * @dev Records msg.sender as the context setter (transient storage). Until clearContext, only the setter gets
     *      sender_ back from _getSenderFromContext; every other caller resolves to itself.
     * @dev address(0) is rejected, so a stored zero always means "no context"
     * @custom:security Non-reentrant by design through single context restriction
     * @custom:security On clients deployed before IL-9533, while a relayed call runs, the context sender is visible
     *                 to any caller, not only to the ContextManager: code that gets control during the call and
     *                 re-enters such a client acts as the sender on every function without nonReentrant (e.g. approve).
     *                 On them, relay only calls that cannot reach untrusted code.
     * @custom:access Restricted to TECH_CONTEXT_MANAGER_ROLE only
     * @custom:throws UnauthorizedSender if sender_ is address(0)
     * @custom:throws ContextAlreadySet if a context is currently active
     */
    function setupContext(address sender_) external override restricted {
        if (sender_ == address(0)) {
            revert UnauthorizedSender();
        }

        if (ContextClientStorageLib.isContextSenderSet()) {
            revert ContextAlreadySet();
        }

        ContextClientStorageLib.setContextSender(sender_);

        emit ContextSet(sender_);
    }

    /**
     * @notice Clears the current context
     * @dev Only callable by authorized contracts through the restricted modifier
     * @dev Uses ContextClientStorageLib for persistent storage
     * @dev Reads the raw stored sender (not the caller-resolved one), so ContextNotSet is reached when no context is
     *      set. Clears the stored sender and the context setter. A relayed call whose data is clearContext() makes the
     *      ContextManager's own clearContext revert, so the whole relayed call reverts.
     * @custom:security Should always be called after context operations are complete
     * @custom:access Restricted to TECH_CONTEXT_MANAGER_ROLE only
     * @custom:throws ContextNotSet if no context is currently set
     */
    function clearContext() external override restricted {
        address currentSender = ContextClientStorageLib.getContextSender();

        if (currentSender == address(0)) {
            revert ContextNotSet();
        }

        ContextClientStorageLib.clearContextStorage();

        emit ContextCleared(currentSender);
    }

    /**
     * @notice Retrieves the sender address from the current context
     * @dev Internal view function for derived contracts to access context
     * @dev Returns the stored context sender only when msg.sender is the context setter (the caller of
     *      setupContext); otherwise, and when no context is set, returns msg.sender
     * @return address The sender address stored in the current context, or msg.sender
     * @custom:security Ensure proper access control in derived contracts
     * @custom:access Internal function - access controlled by inheriting contracts
     */
    function _getSenderFromContext() internal view returns (address) {
        return ContextClientStorageLib.getSenderFromContext();
    }
}
