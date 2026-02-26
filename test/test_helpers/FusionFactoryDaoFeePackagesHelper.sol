// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {PlasmaVaultFactory} from "../../contracts/factory/PlasmaVaultFactory.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {AccessManagerFactory} from "../../contracts/factory/AccessManagerFactory.sol";
import {PriceManagerFactory} from "../../contracts/factory/PriceManagerFactory.sol";
import {WithdrawManagerFactory} from "../../contracts/factory/WithdrawManagerFactory.sol";
import {RewardsManagerFactory} from "../../contracts/factory/RewardsManagerFactory.sol";
import {ContextManagerFactory} from "../../contracts/factory/ContextManagerFactory.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";

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
        PlasmaVaultFactory newPlasmaVaultFactory = new PlasmaVaultFactory(address(fusionFactory));

        // Deploy new PlasmaVaultBase - the existing one on the fork is already initialized
        // and cannot be used with new PlasmaVault instances (would fail with InvalidInitialization)
        PlasmaVaultBase newPlasmaVaultBase = new PlasmaVaultBase();

        // Deploy new FeeManagerFactory - the existing FeeManager on fork may have incompatible interface
        FeeManagerFactory newFeeManagerFactory = new FeeManagerFactory();

        // Deploy all new factories - fork factories only have create(), not clone()
        AccessManagerFactory newAccessManagerFactory = new AccessManagerFactory(address(fusionFactory));
        PriceManagerFactory newPriceManagerFactory = new PriceManagerFactory(address(fusionFactory));
        WithdrawManagerFactory newWithdrawManagerFactory = new WithdrawManagerFactory(address(fusionFactory));
        RewardsManagerFactory newRewardsManagerFactory = new RewardsManagerFactory(address(fusionFactory));
        ContextManagerFactory newContextManagerFactory = new ContextManagerFactory(address(fusionFactory));

        // Update all factory addresses with the new factories
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses;
        factoryAddresses.plasmaVaultFactory = address(newPlasmaVaultFactory);
        factoryAddresses.feeManagerFactory = address(newFeeManagerFactory);
        factoryAddresses.accessManagerFactory = address(newAccessManagerFactory);
        factoryAddresses.priceManagerFactory = address(newPriceManagerFactory);
        factoryAddresses.withdrawManagerFactory = address(newWithdrawManagerFactory);
        factoryAddresses.rewardsManagerFactory = address(newRewardsManagerFactory);
        factoryAddresses.contextManagerFactory = address(newContextManagerFactory);

        vm.startPrank(admin);
        fusionFactory.upgradeToAndCall(address(newImplementation), "");
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), daoFeeManager);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), admin);
        fusionFactory.updateFactoryAddresses(fusionFactory.getFusionFactoryVersion(), factoryAddresses);
        fusionFactory.updatePlasmaVaultBase(address(newPlasmaVaultBase));
        vm.stopPrank();

        _deployAndSetBaseAddresses(vm, fusionFactory, admin);

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

    function _deployAndSetBaseAddresses(Vm vm, FusionFactory fusionFactory, address admin) private {
        address plasmaVaultCoreBase = address(new PlasmaVault());
        address accessManagerBase = address(new IporFusionAccessManager(admin, 1 seconds));
        address priceManagerBase = address(
            new PriceOracleMiddlewareManager(admin, fusionFactory.getPriceOracleMiddleware())
        );
        address withdrawManagerBase = address(new WithdrawManager(accessManagerBase));
        address rewardsManagerBase = address(new RewardsClaimManager(admin, plasmaVaultCoreBase));
        address[] memory approved = new address[](1);
        approved[0] = address(1);
        address contextManagerBase = address(new ContextManager(admin, approved));

        vm.startPrank(admin);
        fusionFactory.updateBaseAddresses(
            fusionFactory.getFusionFactoryVersion(),
            plasmaVaultCoreBase,
            accessManagerBase,
            priceManagerBase,
            withdrawManagerBase,
            rewardsManagerBase,
            contextManagerBase
        );
        vm.stopPrank();
    }
}
