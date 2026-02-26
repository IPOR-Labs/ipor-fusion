// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultInitData} from "../vaults/PlasmaVault.sol";
import {PlasmaVault} from "../vaults/PlasmaVault.sol";

import {FusionFactoryCreate3Lib} from "./lib/FusionFactoryCreate3Lib.sol";

/// @title PlasmaVaultFactory
/// @notice Factory contract for creating and deploying new PlasmaVault instances
/// @dev This factory uses the standard deployment pattern rather than minimal proxy pattern
/// @dev Each call to getInstance creates a new, independent PlasmaVault contract
/// @dev The factory emits events for tracking vault creation and initialization parameters
contract PlasmaVaultFactory {
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

    /// @notice Creates a new instance of PlasmaVault using CREATE3 deterministic deployment
    /// @param baseAddress_ The address of the base PlasmaVault implementation
    /// @param salt_ The CREATE3 salt for deterministic address
    /// @param initData_ The initialization data containing vault configuration parameters
    /// @return plasmaVault The address of the deterministically deployed PlasmaVault
    function deployDeterministic(
        address baseAddress_,
        bytes32 salt_,
        PlasmaVaultInitData memory initData_
    ) external onlyFusionFactory returns (address plasmaVault) {
        if (baseAddress_ == address(0)) revert InvalidBaseAddress();

        plasmaVault = FusionFactoryCreate3Lib.deployMinimalProxyDeterministic(baseAddress_, salt_);
        PlasmaVault(plasmaVault).proxyInitialize(initData_);
    }

    /// @notice Predicts the address of a deterministic PlasmaVault deployment
    /// @param salt_ The CREATE3 salt to predict the address for
    /// @return The predicted deployment address
    function predictDeterministicAddress(bytes32 salt_) external view returns (address) {
        return FusionFactoryCreate3Lib.predictAddress(salt_);
    }
}
