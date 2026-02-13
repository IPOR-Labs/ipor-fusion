// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title MockEthReceiver
/// @notice Mock contract for testing ETH transfers in async executor
/// @dev Simple contract that can receive ETH and track received amounts
contract MockEthReceiver {
    uint256 public totalReceived;

    /// @notice Allows contract to receive ETH
    receive() external payable {
        totalReceived += msg.value;
    }

    /// @notice Returns the total amount of ETH received
    /// @return The total amount of ETH received
    function getTotalReceived() external view returns (uint256) {
        return totalReceived;
    }

    /// @notice Function that can receive ETH with callData
    /// @dev This function allows receiving ETH with a function call
    function receiveEth() external payable {
        totalReceived += msg.value;
    }
}
