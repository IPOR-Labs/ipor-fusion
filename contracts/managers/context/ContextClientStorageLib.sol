// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title ContextClientStorageLib
/// @notice Library for managing context sender storage in DeFi vault operations
/// @dev Implements a storage pattern using an isolated storage slot to maintain sender context
/// @dev The context sender is bound to the contract that set it (IL-9533): setContextSender stores the sender in
///      the ERC-7201 struct and the address that called setupContext (msg.sender, the ContextManager) in a transient
///      slot. getSenderFromContext returns the stored sender only while msg.sender is that setter; every other caller,
///      including code re-entering the client during the relayed call (a venue, a hook, a hooked token), resolves to
///      itself. Delegatecalls keep msg.sender and the transient storage of the client, so code delegatecalled by the
///      client (PlasmaVaultBase, the votes plugin, pre-hooks, fuses, linked libraries) still sees the sender when the
///      setter is the caller.
/// @dev Clients deployed before this version return the stored sender to every caller during a relayed call: on them,
///      relay only calls that cannot reach untrusted code (an external venue, hook or hooked token).
/// @custom:security This library is critical for maintaining caller context across contract interactions
/// @custom:security-contact security@ipor.io
library ContextClientStorageLib {
    /// @dev Unique storage slot for context sender data
    /// @dev Calculated as: keccak256(abi.encode(uint256(keccak256("io.ipor.context.client.sender.storage")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev The last byte is cleared to allow for additional storage patterns
    /// @dev This specific slot ensures no storage collision with other contract storage
    /// @custom:security Uses ERC-7201 namespaced storage pattern to prevent storage collisions
    bytes32 private constant CONTEXT_SENDER_STORAGE_SLOT =
        0x68262fe08792a71a690eb5eb2de15df1b0f463dd786bf92bdbd5f0f0d1ae8b00;

    /// @dev Transient storage slot holding the address that called setupContext (the context setter)
    /// @dev Calculated as: keccak256(abi.encode(uint256(keccak256("io.ipor.context.client.setter.transient")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev Used only with TSTORE/TLOAD (EIP-1153, Cancun): the value is cleared by clearContextStorage and at the end of
    ///      the transaction. It is never written with SSTORE, so it cannot collide with persistent storage.
    /// @custom:security A setter left from a call that never cleared its context does not survive the transaction:
    ///                  a stored sender without a setter of the current transaction is returned to no caller
    bytes32 private constant CONTEXT_SETTER_TRANSIENT_SLOT =
        0x32da880bae19f8deb5d12b6b7797c7d78f9aeaf8a96898db43e4901c904c3a00;

    /// @dev Structure holding the context sender information
    /// @custom:storage-location erc7201:io.ipor.context.client.sender.storage
    /// @custom:security Isolated storage pattern to prevent unauthorized access and storage collisions
    struct ContextSenderStorage {
        /// @dev The address of the current context sender
        /// @dev If address(0), no context is set, indicating direct interaction
        /// @dev Used to track the original caller across multiple contract interactions
        address contextSender;
    }

    /// @notice Sets the context sender address for the current transaction context
    /// @dev Should be called at the beginning of a context-dependent operation
    /// @dev Critical for maintaining caller context in complex vault operations
    /// @dev Also records msg.sender (the caller of setupContext, i.e. the ContextManager) as the context setter in
    ///      transient storage; only that address gets the sender back from getSenderFromContext
    /// @param sender_ The address to set as the context sender
    /// @custom:security Only callable by authorized contracts in the system
    /// @custom:security-risk HIGH - Incorrect context setting can lead to unauthorized access
    function setContextSender(address sender_) internal {
        ContextSenderStorage storage $ = _getContextSenderStorage();
        $.contextSender = sender_;

        assembly {
            tstore(CONTEXT_SETTER_TRANSIENT_SLOT, caller())
        }
    }

    /// @notice Clears the current context by setting the sender and the context setter to address(0)
    /// @dev Must be called at the end of context-dependent operations
    /// @dev Prevents context leaking between different operations
    /// @custom:security Critical for security to prevent context pollution
    /// @custom:security-risk MEDIUM - Failing to clear context could lead to unauthorized access
    function clearContextStorage() internal {
        ContextSenderStorage storage $ = _getContextSenderStorage();
        $.contextSender = address(0);

        assembly {
            tstore(CONTEXT_SETTER_TRANSIENT_SLOT, 0)
        }
    }

    /// @notice Retrieves the current context sender address
    /// @dev Returns the currently set context sender without modification
    /// @dev Raw value: it does not check who asks. Use getSenderFromContext to resolve the effective caller.
    /// @return The address of the current context sender
    /// @custom:security Returns address(0) if no context is set
    function getContextSender() internal view returns (address) {
        ContextSenderStorage storage $ = _getContextSenderStorage();
        return $.contextSender;
    }

    /// @notice Retrieves the address that set the current context (the caller of setupContext)
    /// @dev Read from transient storage; address(0) when no context was set in the current transaction
    /// @return setter The context setter of the current transaction, or address(0)
    function getContextSetter() internal view returns (address setter) {
        assembly {
            setter := tload(CONTEXT_SETTER_TRANSIENT_SLOT)
        }
    }

    /// @notice Verifies if a valid context sender is currently set
    /// @dev Used to determine if we're operating within a delegated context
    /// @return bool True if a valid context sender is set, false otherwise
    /// @custom:security Used for control flow in permission checks
    function isContextSenderSet() internal view returns (bool) {
        ContextSenderStorage storage $ = _getContextSenderStorage();
        return $.contextSender != address(0);
    }

    /// @notice Gets the effective sender address for the current operation
    /// @dev Core function for determining the actual caller in vault operations
    /// @dev Resolution order:
    ///      1. no context sender stored -> msg.sender (direct path: one SLOAD, no transient read);
    ///      2. msg.sender is not the context setter of the current transaction -> msg.sender;
    ///      3. otherwise -> the stored context sender.
    ///      Only the contract that called setupContext (the ContextManager) gets the relayed sender back. Any other
    ///      caller during the relayed call, including re-entrant code reached through the call (an ERC4626 venue of an
    ///      instant-withdraw fuse, an Euler hook, a hooked token), acts as itself on every function of the client, e.g.
    ///      approve, transfer or a restricted function. Delegatecalls keep msg.sender, so code delegatecalled by the
    ///      client resolves the same way. The vault's own self-calls (msg.sender == the vault) resolve to the vault;
    ///      PlasmaVault and PlasmaVaultBase also authorize them against the vault in _checkCanCall (IL-8310).
    /// @return address The effective sender address (context sender or msg.sender)
    /// @custom:security Critical for access control and permission validation
    /// @custom:security Before IL-9533 the stored sender was returned to any caller during a relayed call (msg.sender
    /// was not checked), so on clients deployed earlier code re-entering the client acts as the sender. See
    /// ContextClient.setupContext.
    /// @custom:security-risk HIGH - Core component of permission system
    function getSenderFromContext() internal view returns (address) {
        address sender = getContextSender();

        if (sender == address(0)) {
            return msg.sender;
        }

        if (msg.sender != getContextSetter()) {
            return msg.sender;
        }

        return sender;
    }

    /// @dev Internal function to access the context storage slot
    /// @return $ Storage pointer to the ContextSenderStorage struct
    /// @custom:security Uses assembly to access a specific storage slot
    /// @custom:security Uses ERC-7201 namespaced storage pattern
    function _getContextSenderStorage() private pure returns (ContextSenderStorage storage $) {
        assembly {
            $.slot := CONTEXT_SENDER_STORAGE_SLOT
        }
    }
}
