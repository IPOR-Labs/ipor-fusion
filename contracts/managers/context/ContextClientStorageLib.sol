// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

library ContextClientStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.context.client.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CONTEXT_SENDER_STORAGE_SLOT =
        0x1ed01a488675aee5f2546b3ab61bd85c8f7a260e8a6dddb11fc993513462ac00; //

    struct ContextSenderStorage {
        /// @dev The address of the current context sender
        address contextSender;
    }

    function _getContextStorage() private pure returns (ContextSenderStorage storage $) {
        assembly {
            $.slot := CONTEXT_SENDER_STORAGE_SLOT
        }
    }

    /// @notice Sets the context sender
    /// @param sender The address to set as context sender
    function setContextSender(address sender) internal {
        ContextSenderStorage storage $ = _getContextStorage();
        $.contextSender = sender;
    }

    /// @notice Clears the context
    function clearContextStorage() internal {
        ContextSenderStorage storage $ = _getContextStorage();
        $.contextSender = address(0);
    }

    /// @notice Gets the current context sender
    /// @return The address of the current context sender
    function getContextSender() internal view returns (address) {
        ContextSenderStorage storage $ = _getContextStorage();
        return $.contextSender;
    }

    /// @notice Checks if context is currently set
    /// @return True if context is set, false otherwise
    function isContextSet() internal view returns (bool) {
        ContextSenderStorage storage $ = _getContextStorage();
        return $.contextSender != address(0);
    }

    function getSenderFromContext() internal view returns (address) {
        address sender = getContextSender();
        if (sender == address(0)) {
            return msg.sender;
        }
        return sender;
    }
}
