// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ContextManager} from "../managers/context/ContextManager.sol";
import {FusionFactoryCreate3Lib} from "./lib/FusionFactoryCreate3Lib.sol";

/// @title ContextManagerFactory
/// @notice Factory contract for creating ContextManager instances that manage execution context and permissions for vault operations
contract ContextManagerFactory {
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

    /// @notice Creates a new instance of ContextManager using CREATE3 deterministic deployment
    /// @param baseAddress_ The address of the base ContextManager implementation
    /// @param salt_ The CREATE3 salt for deterministic address
    /// @param accessManager_ The initial authority address for access control
    /// @param approvedTargets_ The addresses of the approved targets
    /// @return contextManager Address of the deterministically deployed ContextManager
    function deployDeterministic(
        address baseAddress_,
        bytes32 salt_,
        address accessManager_,
        address[] memory approvedTargets_
    ) external onlyFusionFactory returns (address contextManager) {
        if (baseAddress_ == address(0)) revert InvalidBaseAddress();

        contextManager = FusionFactoryCreate3Lib.deployMinimalProxyDeterministic(baseAddress_, salt_);
        ContextManager(contextManager).proxyInitialize(accessManager_, approvedTargets_);
    }

    /// @notice Predicts the address of a deterministic ContextManager deployment
    /// @param salt_ The CREATE3 salt to predict the address for
    /// @return The predicted deployment address
    function predictDeterministicAddress(bytes32 salt_) external view returns (address) {
        return FusionFactoryCreate3Lib.predictAddress(salt_);
    }
}
