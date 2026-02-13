// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IporFusionAccessManager} from "../contracts/managers/access/IporFusionAccessManager.sol";
import {Vm} from "forge-std/Test.sol";
import {PlasmaVaultGovernance} from "../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVault} from "../contracts/vaults/PlasmaVault.sol";
import {Roles} from "../contracts/libraries/Roles.sol";
import {FeeManager} from "../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../contracts/managers/fee/FeeAccount.sol";
import {WithdrawManager} from "../contracts/managers/withdraw/WithdrawManager.sol";
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
    function createAccessManager(
        UsersToRoles memory usersWithRoles,
        uint256 redemptionDelay_,
        Vm vm
    ) public returns (IporFusionAccessManager) {
        IporFusionAccessManager accessManager = new IporFusionAccessManager(
            usersWithRoles.superAdmin,
            redemptionDelay_
        );

        vm.prank(usersWithRoles.superAdmin);
        accessManager.setRoleAdmin(Roles.ALPHA_ROLE, Roles.ATOMIST_ROLE);
        vm.prank(usersWithRoles.superAdmin);
        accessManager.setRoleAdmin(Roles.TECH_PERFORMANCE_FEE_MANAGER_ROLE, Roles.ATOMIST_ROLE);
        vm.prank(usersWithRoles.superAdmin);
        accessManager.setRoleAdmin(Roles.TECH_MANAGEMENT_FEE_MANAGER_ROLE, Roles.ATOMIST_ROLE);
        vm.prank(usersWithRoles.superAdmin);
        accessManager.setRoleAdmin(Roles.TECH_REWARDS_CLAIM_MANAGER_ROLE, Roles.ATOMIST_ROLE);

        vm.prank(usersWithRoles.superAdmin);
        accessManager.grantRole(Roles.ATOMIST_ROLE, usersWithRoles.atomist, 0);

        vm.prank(usersWithRoles.superAdmin);
        accessManager.grantRole(Roles.GUARDIAN_ROLE, usersWithRoles.atomist, 0);

        vm.prank(usersWithRoles.superAdmin);
        accessManager.grantRole(Roles.OWNER_ROLE, usersWithRoles.atomist, 0);

        vm.prank(usersWithRoles.superAdmin);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, usersWithRoles.atomist, 0);

        for (uint256 i; i < usersWithRoles.alphas.length; i++) {
            vm.prank(usersWithRoles.atomist);
            accessManager.grantRole(Roles.ALPHA_ROLE, usersWithRoles.alphas[i], 0);
        }

        for (uint256 i; i < usersWithRoles.performanceFeeManagers.length; i++) {
            vm.prank(usersWithRoles.atomist);
            accessManager.grantRole(
                Roles.TECH_PERFORMANCE_FEE_MANAGER_ROLE,
                usersWithRoles.performanceFeeManagers[i],
                usersWithRoles.feeTimelock
            );
        }

        for (uint256 i; i < usersWithRoles.managementFeeManagers.length; i++) {
            vm.prank(usersWithRoles.atomist);
            accessManager.grantRole(
                Roles.TECH_MANAGEMENT_FEE_MANAGER_ROLE,
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
        IporFusionAccessManager accessManager_,
        address withdrawManager_
    ) public {
        _setupBasicRoles(usersWithRoles_, vm_, plasmaVault_, accessManager_);
        _setupFeeManagerRoles(usersWithRoles_, vm_, plasmaVault_, accessManager_);
        _setupAtomistRoles(usersWithRoles_, vm_, plasmaVault_, accessManager_);
        _setupPlasmaVaultSpecificRoles(usersWithRoles_, vm_, plasmaVault_, accessManager_);
        _setupPublicRoles(usersWithRoles_, vm_, plasmaVault_, accessManager_);
        _setupWithdrawManagerRoles(usersWithRoles_, vm_, plasmaVault_, accessManager_, withdrawManager_);
    }

    function _setupBasicRoles(
        UsersToRoles memory usersWithRoles_,
        Vm vm_,
        address plasmaVault_,
        IporFusionAccessManager accessManager_
    ) private {
        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.grantRole(Roles.TECH_PLASMA_VAULT_ROLE, plasmaVault_, 0);

        bytes4[] memory performanceFeeSig = new bytes4[](1);
        performanceFeeSig[0] = PlasmaVaultGovernance.configurePerformanceFee.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(plasmaVault_, performanceFeeSig, Roles.TECH_PERFORMANCE_FEE_MANAGER_ROLE);

        bytes4[] memory managementFeeSig = new bytes4[](1);
        managementFeeSig[0] = PlasmaVaultGovernance.configureManagementFee.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(plasmaVault_, managementFeeSig, Roles.TECH_MANAGEMENT_FEE_MANAGER_ROLE);

        bytes4[] memory alphaSig = new bytes4[](1);
        alphaSig[0] = PlasmaVault.execute.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(plasmaVault_, alphaSig, Roles.ALPHA_ROLE);
    }

    function _setupFeeManagerRoles(
        UsersToRoles memory usersWithRoles_,
        Vm vm_,
        address plasmaVault_,
        IporFusionAccessManager accessManager_
    ) private {
        address feeManager = FeeAccount(PlasmaVaultGovernance(plasmaVault_).getPerformanceFeeData().feeAccount)
            .FEE_MANAGER();

        bytes4[] memory feeManagerSig = new bytes4[](1);
        feeManagerSig[0] = FeeManager.updateHighWaterMarkPerformanceFee.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(feeManager, feeManagerSig, Roles.ALPHA_ROLE);

        bytes4[] memory feeManagerSig2 = new bytes4[](2);
        feeManagerSig2[0] = FeeManager.updateManagementFee.selector;
        feeManagerSig2[1] = FeeManager.updatePerformanceFee.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(feeManager, feeManagerSig2, Roles.ATOMIST_ROLE);

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setRoleAdmin(Roles.TECH_PERFORMANCE_FEE_MANAGER_ROLE, Roles.ATOMIST_ROLE);

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setRoleAdmin(Roles.TECH_MANAGEMENT_FEE_MANAGER_ROLE, Roles.ATOMIST_ROLE);

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.grantRole(Roles.TECH_PERFORMANCE_FEE_MANAGER_ROLE, feeManager, 0);

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.grantRole(Roles.TECH_MANAGEMENT_FEE_MANAGER_ROLE, feeManager, 0);
    }

    function _setupAtomistRoles(
        UsersToRoles memory usersWithRoles_,
        Vm vm_,
        address plasmaVault_,
        IporFusionAccessManager accessManager_
    ) private {
        bytes4[] memory atomistsSig = new bytes4[](10);
        atomistsSig[0] = PlasmaVaultGovernance.addBalanceFuse.selector;
        atomistsSig[1] = PlasmaVaultGovernance.addFuses.selector;
        atomistsSig[2] = PlasmaVaultGovernance.removeFuses.selector;
        atomistsSig[3] = PlasmaVaultGovernance.setPriceOracleMiddleware.selector;
        atomistsSig[4] = PlasmaVaultGovernance.setupMarketsLimits.selector;
        atomistsSig[5] = PlasmaVaultGovernance.activateMarketsLimits.selector;
        atomistsSig[6] = PlasmaVaultGovernance.deactivateMarketsLimits.selector;
        atomistsSig[7] = PlasmaVaultGovernance.updateDependencyBalanceGraphs.selector;
        atomistsSig[8] = PlasmaVaultGovernance.convertToPublicVault.selector;
        atomistsSig[9] = PlasmaVaultGovernance.enableTransferShares.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(plasmaVault_, atomistsSig, Roles.ATOMIST_ROLE);
    }

    function _setupPlasmaVaultSpecificRoles(
        UsersToRoles memory usersWithRoles_,
        Vm vm_,
        address plasmaVault_,
        IporFusionAccessManager accessManager_
    ) private {
        bytes4[] memory plasmaVaultRoles = new bytes4[](4);
        plasmaVaultRoles[0] = IporFusionAccessManager.convertToPublicVault.selector;
        plasmaVaultRoles[1] = IporFusionAccessManager.enableTransferShares.selector;
        plasmaVaultRoles[2] = IporFusionAccessManager.setMinimalExecutionDelaysForRoles.selector;
        plasmaVaultRoles[3] = IporFusionAccessManager.canCallAndUpdate.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(address(accessManager_), plasmaVaultRoles, Roles.TECH_PLASMA_VAULT_ROLE);

        bytes4[] memory guardianSig = new bytes4[](1);
        guardianSig[0] = IporFusionAccessManager.updateTargetClosed.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(address(accessManager_), guardianSig, Roles.GUARDIAN_ROLE);

        bytes4[] memory ownerSig = new bytes4[](1);
        ownerSig[0] = PlasmaVaultGovernance.setMinimalExecutionDelaysForRoles.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(plasmaVault_, ownerSig, Roles.OWNER_ROLE);

        bytes4[] memory publicRedeemFromRequestSig = new bytes4[](1);
        publicRedeemFromRequestSig[0] = PlasmaVault.redeemFromRequest.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(plasmaVault_, publicRedeemFromRequestSig, Roles.PUBLIC_ROLE);
    }

    function _setupPublicRoles(
        UsersToRoles memory usersWithRoles_,
        Vm vm_,
        address plasmaVault_,
        IporFusionAccessManager accessManager_
    ) private {
        bytes4[] memory publicSig = new bytes4[](7);
        publicSig[0] = PlasmaVault.deposit.selector;
        publicSig[1] = PlasmaVault.mint.selector;
        publicSig[2] = PlasmaVault.withdraw.selector;
        publicSig[3] = PlasmaVault.redeem.selector;
        publicSig[4] = PlasmaVault.depositWithPermit.selector;
        publicSig[5] = PlasmaVault.transferFrom.selector;
        publicSig[6] = PlasmaVault.transfer.selector;

        vm_.prank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(plasmaVault_, publicSig, Roles.PUBLIC_ROLE);
    }

    function _setupWithdrawManagerRoles(
        UsersToRoles memory usersWithRoles_,
        Vm vm_,
        address plasmaVault_,
        IporFusionAccessManager accessManager_,
        address withdrawManager_
    ) private {
        bytes4[] memory withdrawManagerSig = new bytes4[](2);
        withdrawManagerSig[0] = WithdrawManager.canWithdrawFromUnallocated.selector;
        withdrawManagerSig[1] = WithdrawManager.canWithdrawFromRequest.selector;

        bytes4[] memory alphaRoleSig = new bytes4[](1);
        alphaRoleSig[0] = WithdrawManager.releaseFunds.selector;

        vm_.startPrank(usersWithRoles_.superAdmin);
        accessManager_.setTargetFunctionRole(withdrawManager_, withdrawManagerSig, Roles.TECH_PLASMA_VAULT_ROLE);
        accessManager_.setTargetFunctionRole(withdrawManager_, alphaRoleSig, Roles.ALPHA_ROLE);
        accessManager_.grantRole(Roles.TECH_PLASMA_VAULT_ROLE, plasmaVault_, 0);

        vm_.stopPrank();
    }
}
