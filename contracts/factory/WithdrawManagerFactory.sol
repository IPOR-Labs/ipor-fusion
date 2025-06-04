// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {WithdrawManager} from "../managers/withdraw/WithdrawManager.sol";

/// @title WithdrawManagerFactory
/// @notice Factory contract for creating WithdrawManager instances
/// @dev This factory is responsible for deploying new WithdrawManager contracts with proper initialization
contract WithdrawManagerFactory {
    /// @notice Emitted when a new WithdrawManager instance is created
    /// @param index The index of the WithdrawManager instance
    /// @param withdrawManager The address of the newly created WithdrawManager contract
    /// @param accessManager The address of the AccessManager contract that will control permissions
    event WithdrawManagerCreated(uint256 index, address withdrawManager, address accessManager);

    /// @notice Creates a new instance of WithdrawManager
    /// @dev Deploys a new WithdrawManager contract and initializes it with the provided access manager
    /// @param index_ The index of the WithdrawManager instance
    /// @param accessManager_ The address of the AccessManager contract that will control permissions for the new WithdrawManager
    /// @return withdrawManager The address of the newly deployed WithdrawManager contract
    function create(uint256 index_, address accessManager_) external returns (address withdrawManager) {
        withdrawManager = address(new WithdrawManager(accessManager_));
        emit WithdrawManagerCreated(index_, withdrawManager, accessManager_);
    }
}
