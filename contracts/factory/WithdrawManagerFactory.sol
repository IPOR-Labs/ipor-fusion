// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {WithdrawManager} from "../managers/withdraw/WithdrawManager.sol";
import {FusionFactoryCreate3Lib} from "./lib/FusionFactoryCreate3Lib.sol";

/// @title WithdrawManagerFactory
/// @notice Factory contract for creating WithdrawManager instances
/// @dev This factory is responsible for deploying new WithdrawManager contracts with proper initialization
contract WithdrawManagerFactory {
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

    /// @notice Creates a new instance of WithdrawManager using CREATE3 deterministic deployment
    /// @param baseAddress_ The address of the base WithdrawManager implementation
    /// @param salt_ The CREATE3 salt for deterministic address
    /// @param accessManager_ The address of the AccessManager contract that will control permissions
    /// @return withdrawManager The address of the deterministically deployed WithdrawManager
    function deployDeterministic(
        address baseAddress_,
        bytes32 salt_,
        address accessManager_
    ) external onlyFusionFactory returns (address withdrawManager) {
        if (baseAddress_ == address(0)) revert InvalidBaseAddress();

        withdrawManager = FusionFactoryCreate3Lib.deployMinimalProxyDeterministic(baseAddress_, salt_);
        WithdrawManager(withdrawManager).proxyInitialize(accessManager_);
    }

    /// @notice Predicts the address of a deterministic WithdrawManager deployment
    /// @param salt_ The CREATE3 salt to predict the address for
    /// @return The predicted deployment address
    function predictDeterministicAddress(bytes32 salt_) external view returns (address) {
        return FusionFactoryCreate3Lib.predictAddress(salt_);
    }
}
