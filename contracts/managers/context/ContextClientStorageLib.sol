// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title ContextClientStorageLib
/// @notice Library for managing context sender storage in DeFi vault operations
/// @dev Implements a storage pattern using an isolated storage slot to maintain sender context
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

    /// @dev Structure holding the context sender information
    /// @custom:storage-location erc7201:io.ipor.context.client.storage
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
    /// @param sender The address to set as the context sender
    /// @custom:security Only callable by authorized contracts in the system
    /// @custom:security-risk HIGH - Incorrect context setting can lead to unauthorized access
    function setContextSender(address sender) internal {
        ContextSenderStorage storage $ = _getContextSenderStorage();
        $.contextSender = sender;
    }

    /// @notice Clears the current context by setting the sender to address(0)
    /// @dev Must be called at the end of context-dependent operations
    /// @dev Prevents context leaking between different operations
    /// @custom:security Critical for security to prevent context pollution
    /// @custom:security-risk MEDIUM - Failing to clear context could lead to unauthorized access
    function clearContextStorage() internal {
        ContextSenderStorage storage $ = _getContextSenderStorage();
        $.contextSender = address(0);
    }

    /// @notice Retrieves the current context sender address
    /// @dev Returns the currently set context sender without modification
    /// @return The address of the current context sender
    /// @custom:security Returns address(0) if no context is set
    function getContextSender() internal view returns (address) {
        ContextSenderStorage storage $ = _getContextSenderStorage();
        return $.contextSender;
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
    /// @return address The effective sender address (context sender or msg.sender)
    /// @custom:security Critical for access control and permission validation
    /// @custom:security-risk HIGH - Core component of permission system
    function getSenderFromContext() internal view returns (address) {
        address sender = getContextSender();

        if (sender == address(0)) {
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
