// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "./IFuseCommon.sol";

/// @title Interface for Fuses
interface IFuse is IFuseCommon {
    /// @notice Enters to the Market
    function enter(bytes calldata data_) external;

    /// @notice Exits from the Market
    function exit(bytes calldata data_) external;
}
