// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {PlasmaVaultAccessManager} from "../contracts/managers/PlasmaVaultAccessManager.sol";
import {Vm} from "forge-std/Test.sol";
import {PlasmaVaultGovernance} from "../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVault} from "../contracts/vaults/PlasmaVault.sol";

struct UsersToRoles {
    address superAdmin;
    address atomist;
    address[] alphas;
    address[] performanceFeeManagers;
    address[] managementFeeManagers;
}

uint64 constant SUPER_ADMIN_ROLE = 0;
uint64 constant ATOMIST_ROLE = 10;
uint64 constant ALPHA_ROLE = 100;
uint64 constant PERFORMANCE_FEE_MANAGER_ROLE = 101;
uint64 constant MANAGEMENT_FEE_MANAGER_ROLE = 102;
uint64 constant WHITELIST_DEPOSIT_ROLE = 1000;
uint64 constant PUBLIC_ROLE = type(uint64).max;

/// @title Storage
library RoleLib {
    function createAccessManager(UsersToRoles memory usersWithRoles, Vm vm) public returns (PlasmaVaultAccessManager) {
        PlasmaVaultAccessManager accessManager = new PlasmaVaultAccessManager(usersWithRoles.superAdmin);

        vm.prank(usersWithRoles.superAdmin);
        accessManager.setRoleAdmin(ALPHA_ROLE, ATOMIST_ROLE);
        vm.prank(usersWithRoles.superAdmin);
        accessManager.setRoleAdmin(PERFORMANCE_FEE_MANAGER_ROLE, ATOMIST_ROLE);
        vm.prank(usersWithRoles.superAdmin);
        accessManager.setRoleAdmin(MANAGEMENT_FEE_MANAGER_ROLE, ATOMIST_ROLE);

        vm.prank(usersWithRoles.superAdmin);
        accessManager.grantRole(ATOMIST_ROLE, usersWithRoles.atomist, 0);

        for (uint256 i; i < usersWithRoles.alphas.length; i++) {
            vm.prank(usersWithRoles.atomist);
            accessManager.grantRole(ALPHA_ROLE, usersWithRoles.alphas[i], 0);
        }

        for (uint256 i; i < usersWithRoles.performanceFeeManagers.length; i++) {
            vm.prank(usersWithRoles.atomist);
            accessManager.grantRole(PERFORMANCE_FEE_MANAGER_ROLE, usersWithRoles.performanceFeeManagers[i], 0);
        }

        for (uint256 i; i < usersWithRoles.managementFeeManagers.length; i++) {
            vm.prank(usersWithRoles.atomist);
            accessManager.grantRole(MANAGEMENT_FEE_MANAGER_ROLE, usersWithRoles.managementFeeManagers[i], 0);
        }

        return accessManager;
    }

    function setupPlasmaVaultRoles(
        UsersToRoles memory usersWithRoles_,
        Vm vm_,
        address plasmaVault_,
        PlasmaVaultAccessManager accessManager_
    ) public {
        bytes4[] memory performanceFeeSig = new bytes4[](1);
        performanceFeeSig[0] = PlasmaVaultGovernance.configurePerformanceFee.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(plasmaVault_, performanceFeeSig, PERFORMANCE_FEE_MANAGER_ROLE);

        bytes4[] memory managementFeeSig = new bytes4[](1);
        managementFeeSig[0] = PlasmaVaultGovernance.configureManagementFee.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(plasmaVault_, managementFeeSig, MANAGEMENT_FEE_MANAGER_ROLE);

        bytes4[] memory alphaSig = new bytes4[](1);
        alphaSig[0] = PlasmaVault.execute.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(plasmaVault_, alphaSig, ALPHA_ROLE);

        bytes4[] memory atomistsSig = new bytes4[](6);
        atomistsSig[0] = PlasmaVaultGovernance.addBalanceFuse.selector;
        atomistsSig[1] = PlasmaVaultGovernance.addFuse.selector;
        atomistsSig[2] = PlasmaVaultGovernance.addFuses.selector;
        atomistsSig[3] = PlasmaVaultGovernance.removeFuse.selector;
        atomistsSig[4] = PlasmaVaultGovernance.removeFuses.selector;
        atomistsSig[5] = PlasmaVaultGovernance.setPriceOracle.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(plasmaVault_, atomistsSig, ATOMIST_ROLE);

        bytes4[] memory publicSig = new bytes4[](2);
        publicSig[0] = PlasmaVault.deposit.selector;
        publicSig[1] = PlasmaVault.mint.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(plasmaVault_, publicSig, PUBLIC_ROLE);
    }
}