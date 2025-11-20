// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RewardsClaimManager} from "../managers/rewards/RewardsClaimManager.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title RewardsManagerFactory
/// @notice Factory contract for deploying new instances of RewardsClaimManager
/// @dev This factory pattern allows for standardized creation of RewardsClaimManager contracts
/// with proper initialization of access control and plasma vault dependencies
contract RewardsManagerFactory {
    /// @notice Emitted when a new RewardsClaimManager instance is created
    /// @param index The index of the RewardsClaimManager instance
    /// @param rewardsManager The address of the newly created RewardsClaimManager
    /// @param accessManager The address of the access control manager
    /// @param plasmaVault The address of the plasma vault contract
    event RewardsManagerCreated(uint256 index, address rewardsManager, address accessManager, address plasmaVault);

    /// @notice Error thrown when trying to use zero address as base
    error InvalidBaseAddress();

    /// @notice Creates a new instance of RewardsClaimManager
    /// @param accessManager_ The address of the access control manager that will have initial authority
    /// @param plasmaVault_ The address of the plasma vault contract that will handle reward distributions
    /// @return rewardsManager The address of the newly deployed RewardsClaimManager instance
    function create(
        uint256 index_,
        address accessManager_,
        address plasmaVault_
    ) external returns (address rewardsManager) {
        rewardsManager = address(new RewardsClaimManager(accessManager_, plasmaVault_));
        emit RewardsManagerCreated(index_, rewardsManager, accessManager_, plasmaVault_);
    }

    /// @notice Creates a new instance of RewardsClaimManager using Clones pattern
    /// @dev Clones the base RewardsClaimManager and initializes it with the provided parameters
    /// @param baseAddress_ The address of the base RewardsClaimManager implementation to clone
    /// @param index_ The index of the RewardsClaimManager instance
    /// @param accessManager_ The address of the access control manager that will have initial authority
    /// @param plasmaVault_ The address of the plasma vault contract that will handle reward distributions
    /// @return rewardsManager The address of the newly cloned RewardsClaimManager contract
    function clone(
        address baseAddress_,
        uint256 index_,
        address accessManager_,
        address plasmaVault_
    ) external returns (address rewardsManager) {
        if (baseAddress_ == address(0)) revert InvalidBaseAddress();

        rewardsManager = Clones.clone(baseAddress_);
        RewardsClaimManager(rewardsManager).proxyInitialize(accessManager_, plasmaVault_);

        emit RewardsManagerCreated(index_, rewardsManager, accessManager_, plasmaVault_);
    }
}
