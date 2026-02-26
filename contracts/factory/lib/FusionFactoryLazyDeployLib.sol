// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RewardsManagerFactory} from "../RewardsManagerFactory.sol";
import {ContextManagerFactory} from "../ContextManagerFactory.sol";
import {FusionFactoryStorageLib} from "./FusionFactoryStorageLib.sol";
import {VaultInstanceAddresses, Component} from "./FusionFactoryStorageLib.sol";
import {FusionFactoryCreate3Lib} from "./FusionFactoryCreate3Lib.sol";
import {IporFusionAccessManager} from "../../managers/access/IporFusionAccessManager.sol";
import {Roles} from "../../libraries/Roles.sol";
import {IPlasmaVaultGovernance} from "../../interfaces/IPlasmaVaultGovernance.sol";
import {IRewardsClaimManager} from "../../interfaces/IRewardsClaimManager.sol";
import {RewardsClaimManager} from "../../managers/rewards/RewardsClaimManager.sol";

/// @title Fusion Factory Lazy Deploy Library
/// @notice Library for deploying Phase 2 components (RewardsManager, ContextManager) at pre-computed addresses
library FusionFactoryLazyDeployLib {
    error ComponentAlreadyDeployed();
    error VaultNotRegistered();

    event LazyComponentDeployed(address indexed plasmaVault, Component component, address deployedAddress);

    /// @notice Deploys a Phase 2 component (RewardsManager or ContextManager) at its pre-computed address
    /// @param plasmaVault_ The address of the plasma vault
    /// @param component_ The component to deploy
    /// @return deployedAddress The address of the deployed component
    function deployLazyComponent(
        address plasmaVault_,
        Component component_
    ) public returns (address deployedAddress) {
        VaultInstanceAddresses memory vaultAddresses = FusionFactoryStorageLib.getVaultInstanceAddresses(plasmaVault_);
        if (vaultAddresses.plasmaVault == address(0)) revert VaultNotRegistered();

        FusionFactoryStorageLib.BaseAddresses memory baseAddresses = FusionFactoryStorageLib.getBaseAddresses();
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = FusionFactoryStorageLib.getFactoryAddresses();

        if (component_ == Component.RewardsManager) {
            if (vaultAddresses.rewardsManagerDeployed) revert ComponentAlreadyDeployed();

            bytes32 rewardsSalt = FusionFactoryCreate3Lib.deriveComponentSalt(vaultAddresses.masterSalt, "rewards");

            deployedAddress = RewardsManagerFactory(factoryAddresses.rewardsManagerFactory).deployDeterministic(
                baseAddresses.rewardsManagerBase,
                rewardsSalt,
                vaultAddresses.accessManager,
                plasmaVault_
            );

            IporFusionAccessManager accessManager = IporFusionAccessManager(vaultAddresses.accessManager);

            // Factory has ADMIN_ROLE on AccessManager. To call restricted functions on the
            // newly deployed RewardsManager and PlasmaVault, we temporarily grant ourselves
            // the required roles and configure function-level access, then revert changes.

            // 1. Grant factory TECH_REWARDS_CLAIM_MANAGER_ROLE (admin of this role = ADMIN_ROLE)
            accessManager.grantRole(Roles.TECH_REWARDS_CLAIM_MANAGER_ROLE, address(this), 0);

            // 2. Temporarily allow ADMIN_ROLE to call setupVestingTime on the new RewardsManager
            //    (normally requires ATOMIST_ROLE whose admin is OWNER_ROLE — factory can't grant it)
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = RewardsClaimManager.setupVestingTime.selector;
            accessManager.setTargetFunctionRole(deployedAddress, selectors, Roles.ADMIN_ROLE);

            // 3. Execute the restricted calls
            IRewardsClaimManager(deployedAddress).setupVestingTime(
                FusionFactoryStorageLib.getVestingPeriodInSeconds()
            );
            IPlasmaVaultGovernance(plasmaVault_).setRewardsClaimManagerAddress(deployedAddress);

            // 4. Restore: set setupVestingTime back to ATOMIST_ROLE and revoke factory's temp role
            accessManager.setTargetFunctionRole(deployedAddress, selectors, Roles.ATOMIST_ROLE);
            accessManager.revokeRole(Roles.TECH_REWARDS_CLAIM_MANAGER_ROLE, address(this));

            FusionFactoryStorageLib.markComponentDeployed(plasmaVault_, Component.RewardsManager);

            emit LazyComponentDeployed(plasmaVault_, Component.RewardsManager, deployedAddress);

            // Revoke factory ADMIN_ROLE if all Phase 2 components are now deployed
            if (vaultAddresses.contextManagerDeployed) {
                accessManager.revokeRole(Roles.ADMIN_ROLE, address(this));
            }
        } else if (component_ == Component.ContextManager) {
            if (vaultAddresses.contextManagerDeployed) revert ComponentAlreadyDeployed();

            bytes32 contextSalt = FusionFactoryCreate3Lib.deriveComponentSalt(vaultAddresses.masterSalt, "context");

            address[] memory approvedAddresses = new address[](5);
            approvedAddresses[0] = plasmaVault_;
            approvedAddresses[1] = vaultAddresses.withdrawManager;
            approvedAddresses[2] = vaultAddresses.priceManager;
            approvedAddresses[3] = vaultAddresses.rewardsManager;
            approvedAddresses[4] = vaultAddresses.feeManager;

            deployedAddress = ContextManagerFactory(factoryAddresses.contextManagerFactory).deployDeterministic(
                baseAddresses.contextManagerBase,
                contextSalt,
                vaultAddresses.accessManager,
                approvedAddresses
            );

            FusionFactoryStorageLib.markComponentDeployed(plasmaVault_, Component.ContextManager);

            emit LazyComponentDeployed(plasmaVault_, Component.ContextManager, deployedAddress);

            // Revoke factory ADMIN_ROLE if all Phase 2 components are now deployed
            VaultInstanceAddresses memory updatedAddresses = FusionFactoryStorageLib.getVaultInstanceAddresses(plasmaVault_);
            if (updatedAddresses.rewardsManagerDeployed) {
                IporFusionAccessManager(vaultAddresses.accessManager).revokeRole(Roles.ADMIN_ROLE, address(this));
            }
        }
    }
}
