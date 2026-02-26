// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IporFusionAccessManager} from "../managers/access/IporFusionAccessManager.sol";
import {FusionFactoryCreate3Lib} from "./lib/FusionFactoryCreate3Lib.sol";

/// @title AccessManagerFactory
/// @notice Factory contract for creating and deploying new instances of IporFusionAccessManager
/// @dev This factory pattern allows for standardized creation of access management contracts
/// with configurable parameters for initial authority and redemption delay
contract AccessManagerFactory {
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

    /// @notice Creates a new instance of IporFusionAccessManager using CREATE3 deterministic deployment
    /// @param baseAddress_ The address of the base IporFusionAccessManager implementation
    /// @param salt_ The CREATE3 salt for deterministic address
    /// @param initialAuthority_ The address that will have initial authority over the access manager
    /// @param redemptionDelayInSeconds_ The time delay in seconds required before redemption operations
    /// @return accessManager The address of the deterministically deployed IporFusionAccessManager
    function deployDeterministic(
        address baseAddress_,
        bytes32 salt_,
        address initialAuthority_,
        uint256 redemptionDelayInSeconds_
    ) external onlyFusionFactory returns (address accessManager) {
        if (baseAddress_ == address(0)) revert InvalidBaseAddress();

        accessManager = FusionFactoryCreate3Lib.deployMinimalProxyDeterministic(baseAddress_, salt_);
        IporFusionAccessManager(accessManager).proxyInitialize(initialAuthority_, redemptionDelayInSeconds_);
    }

    /// @notice Predicts the address of a deterministic AccessManager deployment
    /// @param salt_ The CREATE3 salt to predict the address for
    /// @return The predicted deployment address
    function predictDeterministicAddress(bytes32 salt_) external view returns (address) {
        return FusionFactoryCreate3Lib.predictAddress(salt_);
    }
}
