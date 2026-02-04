// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {PlasmaVaultFactory} from "../../contracts/factory/PlasmaVaultFactory.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";

/// @title FusionFactoryDaoFeePackagesHelper
/// @notice Helper library for setting up DAO fee packages on FusionFactory in fork tests
library FusionFactoryDaoFeePackagesHelper {
    /// @notice Sets up a default zero-fee package on the FusionFactory
    /// @param vm The Foundry VM instance
    /// @param fusionFactory The FusionFactory to configure
    /// @dev This function handles upgrade, role assignment, PlasmaVaultFactory deployment and DAO fee package setup for fork tests
    function setupDefaultDaoFeePackages(Vm vm, FusionFactory fusionFactory) internal {
        address daoFeeManager = address(0xFEE0);
        address feeRecipient = address(0xFEE1);

        // Get admin to grant roles and upgrade
        address admin = fusionFactory.getRoleMember(fusionFactory.DEFAULT_ADMIN_ROLE(), 0);

        // Deploy new implementation and upgrade
        FusionFactory newImplementation = new FusionFactory();

        // Deploy new PlasmaVaultFactory with updated PlasmaVaultInitData structure (includes plasmaVaultVotesPlugin)
        // The existing factory on the fork has an old PlasmaVaultFactory that doesn't support the new struct
        PlasmaVaultFactory newPlasmaVaultFactory = new PlasmaVaultFactory();

        // Deploy new PlasmaVaultBase - the existing one on the fork is already initialized
        // and cannot be used with new PlasmaVault instances (would fail with InvalidInitialization)
        PlasmaVaultBase newPlasmaVaultBase = new PlasmaVaultBase();

        // Deploy new FeeManagerFactory - the existing FeeManager on fork may have incompatible interface
        FeeManagerFactory newFeeManagerFactory = new FeeManagerFactory();

        // Update factory addresses with the new factories
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = fusionFactory.getFactoryAddresses();
        factoryAddresses.plasmaVaultFactory = address(newPlasmaVaultFactory);
        factoryAddresses.feeManagerFactory = address(newFeeManagerFactory);

        vm.startPrank(admin);
        fusionFactory.upgradeToAndCall(address(newImplementation), "");
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), daoFeeManager);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), admin);
        fusionFactory.updateFactoryAddresses(fusionFactory.getFusionFactoryVersion(), factoryAddresses);
        fusionFactory.updatePlasmaVaultBase(address(newPlasmaVaultBase));
        vm.stopPrank();

        // Create DAO fee packages
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 0,
            performanceFee: 0,
            feeRecipient: feeRecipient
        });

        vm.prank(daoFeeManager);
        fusionFactory.setDaoFeePackages(packages);
    }

    /// @notice Sets up custom DAO fee packages on the FusionFactory
    /// @param vm The Foundry VM instance
    /// @param fusionFactory The FusionFactory to configure
    /// @param packages The DAO fee packages to set
    function setupDaoFeePackages(
        Vm vm,
        FusionFactory fusionFactory,
        FusionFactoryStorageLib.FeePackage[] memory packages
    ) internal {
        address daoFeeManager = address(0xFEE0);

        // Get admin to grant DAO_FEE_MANAGER_ROLE
        address admin = fusionFactory.getRoleMember(fusionFactory.DEFAULT_ADMIN_ROLE(), 0);

        vm.startPrank(admin);
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), daoFeeManager);
        vm.stopPrank();

        vm.prank(daoFeeManager);
        fusionFactory.setDaoFeePackages(packages);
    }

    /// @notice Sets up DAO fee packages with a specific account as the fee manager
    /// @param vm The Foundry VM instance
    /// @param fusionFactory The FusionFactory to configure
    /// @param daoFeeManager The account to be granted DAO_FEE_MANAGER_ROLE
    /// @param feeRecipient The recipient for fees
    function setupDefaultDaoFeePackagesWithManager(
        Vm vm,
        FusionFactory fusionFactory,
        address daoFeeManager,
        address feeRecipient
    ) internal {
        // Get admin to grant DAO_FEE_MANAGER_ROLE
        address admin = fusionFactory.getRoleMember(fusionFactory.DEFAULT_ADMIN_ROLE(), 0);

        vm.startPrank(admin);
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), daoFeeManager);
        vm.stopPrank();

        // Create DAO fee packages
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 0,
            performanceFee: 0,
            feeRecipient: feeRecipient
        });

        vm.prank(daoFeeManager);
        fusionFactory.setDaoFeePackages(packages);
    }
}
