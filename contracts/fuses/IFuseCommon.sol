// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Interface for Fuses Common functions
interface IFuseCommon {
    /// @notice Market ID associated with the Fuse
    //solhint-disable-next-line
    function MARKET_ID() external view returns (uint256);
}
