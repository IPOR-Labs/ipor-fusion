// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title ContextClientStorageLib
/// @notice Library for managing context sender storage in DeFi vault operations
/// @dev Implements a storage pattern using an isolated storage slot to maintain sender context
/// @dev Used to track the original sender across multiple contract calls in a transaction
/// @custom:security-contact security@yourproject.com
library ContextClientStorageLib {
    /// @dev Unique storage slot for context sender data
    /// @dev Calculated as: keccak256(abi.encode(uint256(keccak256("io.ipor.context.client.storage")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev The last byte is cleared to allow for additional storage patterns
    /// @dev This specific slot ensures no storage collision with other contract storage
    bytes32 private constant CONTEXT_SENDER_STORAGE_SLOT =
        0x1ed01a488675aee5f2546b3ab61bd85c8f7a260e8a6dddb11fc993513462ac00;

    /// @dev Structure holding the context sender information
    /// @custom:storage-location This struct is stored in a specific storage slot defined by CONTEXT_SENDER_STORAGE_SLOT
    /// @custom:security Isolated storage pattern to prevent unauthorized access
    struct ContextSenderStorage {
        /// @dev The address of the current context sender. If address(0), no context is set
        /// @dev Used to track the original caller across multiple contract interactions
        address contextSender;
    }

    /// @notice Sets the context sender address
    /// @dev Should be called at the beginning of a context-dependent operation
    /// @dev This function should only be called by authorized contracts in the system
    /// @param sender The address to set as the context sender
    /// @custom:security Ensure proper access control when calling this function
    function setContextSender(address sender) internal {
        ContextSenderStorage storage $ = _getContextSenderStorage();
        $.contextSender = sender;
    }

    /// @notice Clears the current context by setting the sender to address(0)
    /// @dev Should be called at the end of a context-dependent operation to prevent context leaking
    /// @dev Important to call this to avoid context pollution in subsequent operations
    function clearContextStorage() internal {
        ContextSenderStorage storage $ = _getContextSenderStorage();
        $.contextSender = address(0);
    }

    /// @notice Retrieves the current context sender address
    /// @dev Returns the currently set context sender without any validation
    /// @return The address of the current context sender (may be address(0))
    /// @dev Returns address(0) if no context is set
    function getContextSender() internal view returns (address) {
        ContextSenderStorage storage $ = _getContextSenderStorage();
        return $.contextSender;
    }

    /// @notice Checks if a valid context sender is currently set
    /// @dev A context is considered set when the contextSender is not address(0)
    /// @return bool True if a valid context sender is set, false otherwise
    /// @dev Used to determine if we're operating within a context
    function isContextSenderSet() internal view returns (bool) {
        ContextSenderStorage storage $ = _getContextSenderStorage();
        return $.contextSender != address(0);
    }

    /// @notice Gets the effective sender address, either from context or msg.sender
    /// @dev If no context is set (sender is address(0)), returns msg.sender
    /// @dev This is the main function to use when determining the effective caller
    /// @return address The effective sender address to use for the current operation
    function getSenderFromContext() internal view returns (address) {
        address sender = getContextSender();
        if (sender == address(0)) {
            return msg.sender;
        }
        return sender;
    }

    /// @dev Internal function to access the context storage slot
    /// @return $ Storage pointer to the ContextSenderStorage struct
    /// @custom:security Uses assembly to access a specific storage slot for better isolation
    /// @dev Uses named return parameter '$' as per project conventions
    function _getContextSenderStorage() private pure returns (ContextSenderStorage storage $) {
        assembly {
            $.slot := CONTEXT_SENDER_STORAGE_SLOT
        }
    }
}
