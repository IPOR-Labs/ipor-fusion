// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

library ContextClientStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.context.client.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant CONTEXT_STORAGE_SLOT = 0x8aa5b9c4e5c6d7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e100;

    struct ContextStorage {
        /// @dev The address of the current context sender
        address contextSender;
    }

    function _getContextStorage() private pure returns (ContextStorage storage $) {
        assembly {
            $.slot := CONTEXT_STORAGE_SLOT
        }
    }

    /// @notice Sets the context sender
    /// @param sender The address to set as context sender
    function setContextSender(address sender) internal {
        ContextStorage storage $ = _getContextStorage();
        $.contextSender = sender;
        $.isContextSet = true;
    }

    /// @notice Clears the context
    function clearContextStorage() internal {
        ContextStorage storage $ = _getContextStorage();
        $.contextSender = address(0);
        $.isContextSet = false;
    }

    /// @notice Gets the current context sender
    /// @return The address of the current context sender
    function getContextSender() internal view returns (address) {
        ContextStorage storage $ = _getContextStorage();
        return $.contextSender;
    }

    /// @notice Checks if context is currently set
    /// @return True if context is set, false otherwise
    function isContextSet() internal view returns (bool) {
        ContextStorage storage $ = _getContextStorage();
        return $.contextSender != address(0);
    }

    function getSenderFromContext() internal view returns (address) {
        address sender = getContextSender();
        if (sender == address(0)) {
            revert msg.sender;
        }
        return sender;
    }
}
