// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IStargateExecutorImmutables
/// @notice The immutable getters of `StargateCrosschainExecutor` that `StargateExecutorDeploymentLib` reads from the
///         executor itself (via `address(this)` under delegatecall) when it files a dispatcher deployment request.
interface IStargateExecutorImmutables {
    /// @notice Asset identifier the executor is bound to.
    function ASSET_ID() external view returns (bytes32);

    /// @notice Executor admin (rescue module).
    function ADMIN() external view returns (address);

    /// @notice Rescue guardian (rescue module).
    function RESCUE_GUARDIAN() external view returns (address);

    /// @notice Rescue delay in seconds (rescue module).
    function RESCUE_DELAY() external view returns (uint256);

    /// @notice Chain id the executor is deployed on.
    function LOCAL_CHAIN_ID() external view returns (uint256);
}
