// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RewardsClaimManager} from "../managers/rewards/RewardsClaimManager.sol";
import {FusionFactoryCreate3Lib} from "./lib/FusionFactoryCreate3Lib.sol";

/// @title RewardsManagerFactory
/// @notice Factory contract for deploying new instances of RewardsClaimManager
/// @dev This factory pattern allows for standardized creation of RewardsClaimManager contracts
/// with proper initialization of access control and plasma vault dependencies
contract RewardsManagerFactory {
    /// @notice Error thrown when trying to use zero address as base
    error InvalidBaseAddress();

    /// @notice Error thrown when caller is not the FusionFactory
    error CallerNotFusionFactory();

    /// @notice The address of the FusionFactory that is authorized to call deployDeterministic
    address public immutable FUSION_FACTORY;

    constructor(address fusionFactory_) {
        FUSION_FACTORY = fusionFactory_;
    }

    modifier onlyFusionFactory() {
        if (msg.sender != FUSION_FACTORY) revert CallerNotFusionFactory();
        _;
    }

    /// @notice Creates a new instance of RewardsClaimManager using CREATE3 deterministic deployment
    /// @param baseAddress_ The address of the base RewardsClaimManager implementation
    /// @param salt_ The CREATE3 salt for deterministic address
    /// @param accessManager_ The address of the access control manager that will have initial authority
    /// @param plasmaVault_ The address of the plasma vault contract that will handle reward distributions
    /// @return rewardsManager The address of the deterministically deployed RewardsClaimManager
    function deployDeterministic(
        address baseAddress_,
        bytes32 salt_,
        address accessManager_,
        address plasmaVault_
    ) external onlyFusionFactory returns (address rewardsManager) {
        if (baseAddress_ == address(0)) revert InvalidBaseAddress();

        rewardsManager = FusionFactoryCreate3Lib.deployMinimalProxyDeterministic(baseAddress_, salt_);
        RewardsClaimManager(rewardsManager).proxyInitialize(accessManager_, plasmaVault_);
    }

    /// @notice Predicts the address of a deterministic RewardsClaimManager deployment
    /// @param salt_ The CREATE3 salt to predict the address for
    /// @return The predicted deployment address
    function predictDeterministicAddress(bytes32 salt_) external view returns (address) {
        return FusionFactoryCreate3Lib.predictAddress(salt_);
    }
}
