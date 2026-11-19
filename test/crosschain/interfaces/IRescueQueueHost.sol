// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title IRescueQueueHost
/// @notice Test-only view of the generic rescue queue that every crosschain host (executor, dispatcher, Stargate
///         factory) exposes through `RescueModule`.
interface IRescueQueueHost {
    function scheduleRescue(address target_, uint256 value_, bytes calldata callData_) external returns (uint256);

    function executeRescue(uint256 rescueId_, bytes calldata callData_) external;

    function rescueCount() external view returns (uint256);

    function pendingRescueCount() external view returns (uint256);
}
