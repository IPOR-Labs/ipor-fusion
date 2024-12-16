// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface IContextClient {
    function setupContext(address sender) external;

    function clearContext() external;

    /// @notice Emitted when a new context is set
    /// @param sender The address set as the context sender
    event ContextSet(address indexed sender);

    /// @notice Emitted when a context is cleared
    /// @param sender The address that was set in the cleared context
    event ContextCleared(address indexed sender);
}
