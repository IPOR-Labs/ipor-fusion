// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Interface for Fuses - instant withdraw from the market
interface IFuseInstantWithdraw {
    /// @notice Instant withdraw assets from the external market
    /// @param params - array of parameters
    /// @dev - Notice! Always first param is the asset value in underlying
    /// @dev params[0] is asset value in underlying, next params are specific for the Fuse,
    /// @dev params[1] - could be address of the asset, address of the external vault or address of the market or any other specific param for the Fuse
    /// @dev params[n] - any other specific param for a given the Fuse
    function instantWithdraw(bytes32[] calldata params) external;
}
