// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {WithdrawManager} from "../managers/withdraw/WithdrawManager.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title WithdrawManagerFactory
/// @notice Factory contract for creating WithdrawManager instances
/// @dev This factory is responsible for deploying new WithdrawManager contracts with proper initialization
contract WithdrawManagerFactory {
    /// @notice Emitted when a new WithdrawManager instance is created
    /// @param index The index of the WithdrawManager instance
    /// @param withdrawManager The address of the newly created WithdrawManager contract
    /// @param accessManager The address of the AccessManager contract that will control permissions
    event WithdrawManagerCreated(uint256 index, address withdrawManager, address accessManager);

    /// @notice Emitted when a new WithdrawManager instance is cloned
    /// @param baseAddress The address of the base WithdrawManager implementation to clone
    /// @param index The index of the WithdrawManager instance
    /// @param withdrawManager The address of the newly cloned WithdrawManager contract
    /// @param accessManager The address of the AccessManager contract that will control permissions for the new WithdrawManager
    event WithdrawManagerCloned(address baseAddress, uint256 index, address withdrawManager, address accessManager);

    /// @notice Error thrown when trying to use zero address as base
    error InvalidBaseAddress();

    /// @notice Creates a new instance of WithdrawManager using traditional deployment
    /// @dev Deploys a new WithdrawManager contract and initializes it with the provided access manager
    /// @param index_ The index of the WithdrawManager instance
    /// @param accessManager_ The address of the AccessManager contract that will control permissions for the new WithdrawManager
    /// @return withdrawManager The address of the newly deployed WithdrawManager contract
    function create(uint256 index_, address accessManager_) external returns (address withdrawManager) {
        withdrawManager = address(new WithdrawManager(accessManager_));
        emit WithdrawManagerCreated(index_, withdrawManager, accessManager_);
    }

    /// @notice Creates a new instance of WithdrawManager using Clones pattern
    /// @dev Clones the base WithdrawManager and initializes it with the provided access manager
    /// @param baseAddress_ The address of the base WithdrawManager implementation to clone
    /// @param index_ The index of the WithdrawManager instance
    /// @param accessManager_ The address of the AccessManager contract that will control permissions for the new WithdrawManager
    /// @return withdrawManager The address of the newly cloned WithdrawManager contract
    function clone(
        address baseAddress_,
        uint256 index_,
        address accessManager_
    ) external returns (address withdrawManager) {
        if (baseAddress_ == address(0)) revert InvalidBaseAddress();

        withdrawManager = Clones.clone(baseAddress_);
        WithdrawManager(withdrawManager).proxyInitialize(accessManager_);

        emit WithdrawManagerCreated(index_, withdrawManager, accessManager_);
        emit WithdrawManagerCloned(baseAddress_, index_, withdrawManager, accessManager_);
    }
}
