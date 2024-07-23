// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {IporFusionAccessManager} from "../contracts/managers/access/IporFusionAccessManager.sol";
import {Vm} from "forge-std/Test.sol";
import {PlasmaVaultGovernance} from "../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVault} from "../contracts/vaults/PlasmaVault.sol";
import {Roles} from "../contracts/libraries/Roles.sol";

struct UsersToRoles {
    address superAdmin;
    address atomist;
    address[] alphas;
    address[] performanceFeeManagers;
    address[] managementFeeManagers;
    uint32 feeTimelock;
}

/// @title Storage
library RoleLib {
    function createAccessManager(UsersToRoles memory usersWithRoles, Vm vm) public returns (IporFusionAccessManager) {
        IporFusionAccessManager accessManager = new IporFusionAccessManager(usersWithRoles.superAdmin);

        vm.prank(usersWithRoles.superAdmin);
        accessManager.setRoleAdmin(Roles.ALPHA_ROLE, Roles.ATOMIST_ROLE);
        vm.prank(usersWithRoles.superAdmin);
        accessManager.setRoleAdmin(Roles.PERFORMANCE_FEE_MANAGER_ROLE, Roles.ATOMIST_ROLE);
        vm.prank(usersWithRoles.superAdmin);
        accessManager.setRoleAdmin(Roles.MANAGEMENT_FEE_MANAGER_ROLE, Roles.ATOMIST_ROLE);

        vm.prank(usersWithRoles.superAdmin);
        accessManager.grantRole(Roles.ATOMIST_ROLE, usersWithRoles.atomist, 0);

        vm.prank(usersWithRoles.superAdmin);
        accessManager.grantRole(Roles.GUARDIAN_ROLE, usersWithRoles.atomist, 0);

        vm.prank(usersWithRoles.superAdmin);
        accessManager.grantRole(Roles.OWNER_ROLE, usersWithRoles.atomist, 0);

        for (uint256 i; i < usersWithRoles.alphas.length; i++) {
            vm.prank(usersWithRoles.atomist);
            accessManager.grantRole(Roles.ALPHA_ROLE, usersWithRoles.alphas[i], 0);
        }

        for (uint256 i; i < usersWithRoles.performanceFeeManagers.length; i++) {
            vm.prank(usersWithRoles.atomist);
            accessManager.grantRole(
                Roles.PERFORMANCE_FEE_MANAGER_ROLE,
                usersWithRoles.performanceFeeManagers[i],
                usersWithRoles.feeTimelock
            );
        }

        for (uint256 i; i < usersWithRoles.managementFeeManagers.length; i++) {
            vm.prank(usersWithRoles.atomist);
            accessManager.grantRole(
                Roles.MANAGEMENT_FEE_MANAGER_ROLE,
                usersWithRoles.managementFeeManagers[i],
                usersWithRoles.feeTimelock
            );
        }

        return accessManager;
    }

    function setupPlasmaVaultRoles(
        UsersToRoles memory usersWithRoles_,
        Vm vm_,
        address plasmaVault_,
        IporFusionAccessManager accessManager_
    ) public {
        bytes4[] memory performanceFeeSig = new bytes4[](1);
        performanceFeeSig[0] = PlasmaVaultGovernance.configurePerformanceFee.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(plasmaVault_, performanceFeeSig, Roles.PERFORMANCE_FEE_MANAGER_ROLE);

        bytes4[] memory managementFeeSig = new bytes4[](1);
        managementFeeSig[0] = PlasmaVaultGovernance.configureManagementFee.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(plasmaVault_, managementFeeSig, Roles.MANAGEMENT_FEE_MANAGER_ROLE);

        bytes4[] memory alphaSig = new bytes4[](1);
        alphaSig[0] = PlasmaVault.execute.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(plasmaVault_, alphaSig, Roles.ALPHA_ROLE);

        bytes4[] memory atomistsSig = new bytes4[](8);
        atomistsSig[0] = PlasmaVaultGovernance.addBalanceFuse.selector;
        atomistsSig[1] = PlasmaVaultGovernance.addFuses.selector;
        atomistsSig[2] = PlasmaVaultGovernance.removeFuses.selector;
        atomistsSig[3] = PlasmaVaultGovernance.setPriceOracle.selector;
        atomistsSig[4] = PlasmaVaultGovernance.setupMarketsLimits.selector;
        atomistsSig[5] = PlasmaVaultGovernance.activateMarketsLimits.selector;
        atomistsSig[6] = PlasmaVaultGovernance.deactivateMarketsLimits.selector;
        atomistsSig[7] = PlasmaVaultGovernance.updateDependencyBalanceGraphs.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(plasmaVault_, atomistsSig, Roles.ATOMIST_ROLE);

        bytes4[] memory atomistsSig2 = new bytes4[](3);
        atomistsSig2[0] = IporFusionAccessManager.setRedemptionDelay.selector;
        atomistsSig2[1] = IporFusionAccessManager.enableTransferShares.selector;
        atomistsSig2[2] = IporFusionAccessManager.convertToPublicVault.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(address(accessManager_), atomistsSig2, Roles.ATOMIST_ROLE);

        bytes4[] memory guardianSig = new bytes4[](1);
        guardianSig[0] = IporFusionAccessManager.updateTargetClosed.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(address(accessManager_), guardianSig, Roles.GUARDIAN_ROLE);

        bytes4[] memory ownerSig = new bytes4[](1);
        ownerSig[0] = IporFusionAccessManager.setMinimalExecutionDelaysForRoles.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(address(accessManager_), ownerSig, Roles.OWNER_ROLE);

        bytes4[] memory publicSig = new bytes4[](4);
        publicSig[0] = PlasmaVault.deposit.selector;
        publicSig[1] = PlasmaVault.mint.selector;
        publicSig[2] = PlasmaVault.withdraw.selector;
        publicSig[3] = PlasmaVault.redeem.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(plasmaVault_, publicSig, Roles.PUBLIC_ROLE);
    }
}
