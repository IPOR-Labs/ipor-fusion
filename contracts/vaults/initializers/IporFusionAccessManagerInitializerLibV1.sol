// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {RoleToFunction, AdminRole, AccountToRole, InitializationData} from "../../managers/IporFusionAccessManagerInitializationLib.sol";
import {PlasmaVault} from "../PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../PlasmaVaultGovernance.sol";
import {IporFusionRoles} from "../../libraries/IporFusionRoles.sol";
import {RewardsClaimManager} from "../../managers/RewardsClaimManager.sol";
import {IporFusionAccessManager} from "../../managers/IporFusionAccessManager.sol";

struct PlasmaVaultAddress {
    address plasmaVault;
    address accessManager;
    address rewardsClaimManager;
    address feeManager;
}

struct DataForInitialization {
    address[] admins;
    address[] owners;
    address[] atomists;
    address[] alphas;
    address[] whitelist;
    address[] guardians;
    address[] fuseManagers;
    address[] performanceFeeManagers;
    address[] managementFeeManagers;
    address[] claimRewards;
    address[] transferRewardsManagers;
    address[] configInstantWithdrawalFusesManagers;
    PlasmaVaultAddress plasmaVaultAddress;
    address claimRewardsManager;
}

library IporFusionAccessManagerInitializerLibV1 {
    function generateInitializeIporPlasmaVault(
        DataForInitialization memory data
    ) internal returns (InitializationData memory) {
        InitializationData memory initializeData;
        initializeData.roleToFunctions = _generateRoleToFunction(data.plasmaVaultAddress);
        initializeData.adminRoles = _generateAdminRoles();
        initializeData.accountToRoles = _generateAccountToRoles(data);
        initializeData.redemptionDelay = 0;
        return initializeData;
    }

    function _generateAccountToRoles(
        DataForInitialization memory data
    ) private returns (AccountToRole[] memory accountToRoles) {
        accountToRoles = new AccountToRole[](
            data.owners.length +
                data.admins.length +
                data.atomists.length +
                data.alphas.length +
                data.whitelist.length +
                data.guardians.length +
                data.fuseManagers.length +
                data.performanceFeeManagers.length +
                data.managementFeeManagers.length +
                data.claimRewards.length +
                data.transferRewardsManagers.length +
                data.configInstantWithdrawalFusesManagers.length +
                (data.claimRewardsManager == address(0) ? 0 : 1)
        );
        uint256 index;

        if (data.claimRewardsManager != address(0)) {
            accountToRoles[index] = AccountToRole({
                roleId: IporFusionRoles.CLAIM_REWARDS_MANAGER_ROLE,
                account: data.claimRewardsManager,
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data.admins.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: IporFusionRoles.ADMIN_ROLE,
                account: data.admins[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data.guardians.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: IporFusionRoles.GUARDIAN_ROLE,
                account: data.guardians[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data.fuseManagers.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: IporFusionRoles.FUSE_MANAGER_ROLE,
                account: data.fuseManagers[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data.performanceFeeManagers.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: IporFusionRoles.PERFORMANCE_FEE_MANAGER_ROLE,
                account: data.performanceFeeManagers[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data.managementFeeManagers.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: IporFusionRoles.MANAGEMENT_FEE_MANAGER_ROLE,
                account: data.managementFeeManagers[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data.claimRewards.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: IporFusionRoles.CLAIM_REWARDS_ROLE,
                account: data.claimRewards[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data.transferRewardsManagers.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: IporFusionRoles.TRANSFER_REWARDS_ROLE,
                account: data.transferRewardsManagers[i],
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data.owners.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: IporFusionRoles.OWNER_ROLE,
                account: data.owners[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data.atomists.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: IporFusionRoles.ATOMIST_ROLE,
                account: data.atomists[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data.alphas.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: IporFusionRoles.ALPHA_ROLE,
                account: data.alphas[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data.whitelist.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: IporFusionRoles.WHITELIST_ROLE,
                account: data.whitelist[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data.configInstantWithdrawalFusesManagers.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: IporFusionRoles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE,
                account: data.configInstantWithdrawalFusesManagers[i],
                executionDelay: 0
            });
            ++index;
        }
        return accountToRoles;
    }

    function _generateAdminRoles() private returns (AdminRole[] memory adminRoles) {
        adminRoles = new AdminRole[](12);
        adminRoles[0] = AdminRole({roleId: IporFusionRoles.OWNER_ROLE, adminRoleId: IporFusionRoles.ADMIN_ROLE});
        adminRoles[1] = AdminRole({roleId: IporFusionRoles.GUARDIAN_ROLE, adminRoleId: IporFusionRoles.OWNER_ROLE});
        adminRoles[2] = AdminRole({roleId: IporFusionRoles.ATOMIST_ROLE, adminRoleId: IporFusionRoles.OWNER_ROLE});
        adminRoles[3] = AdminRole({roleId: IporFusionRoles.ALPHA_ROLE, adminRoleId: IporFusionRoles.ATOMIST_ROLE});
        adminRoles[4] = AdminRole({roleId: IporFusionRoles.WHITELIST_ROLE, adminRoleId: IporFusionRoles.ATOMIST_ROLE});
        adminRoles[5] = AdminRole({
            roleId: IporFusionRoles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE,
            adminRoleId: IporFusionRoles.ATOMIST_ROLE
        });
        adminRoles[6] = AdminRole({
            roleId: IporFusionRoles.TRANSFER_REWARDS_ROLE,
            adminRoleId: IporFusionRoles.ATOMIST_ROLE
        });
        adminRoles[7] = AdminRole({
            roleId: IporFusionRoles.CLAIM_REWARDS_ROLE,
            adminRoleId: IporFusionRoles.ATOMIST_ROLE
        });
        adminRoles[8] = AdminRole({
            roleId: IporFusionRoles.FUSE_MANAGER_ROLE,
            adminRoleId: IporFusionRoles.ATOMIST_ROLE
        });
        adminRoles[9] = AdminRole({
            roleId: IporFusionRoles.PERFORMANCE_FEE_MANAGER_ROLE,
            adminRoleId: IporFusionRoles.PERFORMANCE_FEE_MANAGER_ROLE
        });
        adminRoles[10] = AdminRole({
            roleId: IporFusionRoles.MANAGEMENT_FEE_MANAGER_ROLE,
            adminRoleId: IporFusionRoles.MANAGEMENT_FEE_MANAGER_ROLE
        });
        adminRoles[11] = AdminRole({
            roleId: IporFusionRoles.CLAIM_REWARDS_MANAGER_ROLE,
            adminRoleId: IporFusionRoles.CLAIM_REWARDS_MANAGER_ROLE
        });
        return adminRoles;
    }

    function _generateRoleToFunction(
        PlasmaVaultAddress memory plasmaVaultAddress
    ) private returns (RoleToFunction[] memory rolesToFunction) {
        rolesToFunction = plasmaVaultAddress.rewardsClaimManager == address(0)
            ? new RoleToFunction[](26)
            : new RoleToFunction[](34);

        rolesToFunction[0] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.ALPHA_ROLE,
            functionSelector: PlasmaVault.execute.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[1] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.WHITELIST_ROLE,
            functionSelector: PlasmaVault.deposit.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[2] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.WHITELIST_ROLE,
            functionSelector: PlasmaVault.mint.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[3] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.PUBLIC_ROLE,
            functionSelector: PlasmaVault.redeem.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[4] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.PUBLIC_ROLE,
            functionSelector: PlasmaVault.withdraw.selector,
            minimalExecutionDelay: 0
        });
        // @dev The shares in this vault are transferable, hence we assign the PUBLIC_ROLE.
        rolesToFunction[5] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.PUBLIC_ROLE,
            functionSelector: PlasmaVault.transfer.selector,
            minimalExecutionDelay: 0
        });
        // @dev The shares in this vault are transferable, hence we assign the PUBLIC_ROLE.
        rolesToFunction[6] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.PUBLIC_ROLE,
            functionSelector: PlasmaVault.transferFrom.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[7] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.CLAIM_REWARDS_MANAGER_ROLE,
            functionSelector: PlasmaVault.claimRewards.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[8] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.FUSE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.addFuses.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[9] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.FUSE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.removeFuses.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[10] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.FUSE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.addBalanceFuse.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[11] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.FUSE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.removeBalanceFuse.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[12] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.MANAGEMENT_FEE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.configureManagementFee.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[13] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.PERFORMANCE_FEE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.configurePerformanceFee.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[14] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.deactivateMarketsLimits.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[15] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE,
            functionSelector: PlasmaVaultGovernance.configureInstantWithdrawalFuses.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[16] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.setPriceOracle.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[17] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.setupMarketsLimits.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[18] = RoleToFunction({
            target: plasmaVaultAddress.plasmaVault,
            roleId: IporFusionRoles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.activateMarketsLimits.selector,
            minimalExecutionDelay: 0
        });

        // IporFuseAccessManager
        rolesToFunction[19] = RoleToFunction({
            target: plasmaVaultAddress.accessManager,
            roleId: IporFusionRoles.OWNER_ROLE,
            functionSelector: IporFusionAccessManager.setMinimalExecutionDelaysForRoles.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[20] = RoleToFunction({
            target: plasmaVaultAddress.accessManager,
            roleId: IporFusionRoles.GUARDIAN_ROLE,
            functionSelector: AccessManager.cancel.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[21] = RoleToFunction({
            target: plasmaVaultAddress.accessManager,
            roleId: IporFusionRoles.ATOMIST_ROLE,
            functionSelector: IporFusionAccessManager.setRedemptionDelay.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[22] = RoleToFunction({
            target: plasmaVaultAddress.accessManager,
            roleId: IporFusionRoles.GUARDIAN_ROLE,
            functionSelector: IporFusionAccessManager.updateTargetClosed.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[23] = RoleToFunction({
            target: plasmaVaultAddress.accessManager,
            roleId: IporFusionRoles.ADMIN_ROLE,
            functionSelector: IporFusionAccessManager.initialize.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[24] = RoleToFunction({
            target: plasmaVaultAddress.accessManager,
            roleId: IporFusionRoles.ATOMIST_ROLE,
            functionSelector: IporFusionAccessManager.convertToPublicVault.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[25] = RoleToFunction({
            target: plasmaVaultAddress.accessManager,
            roleId: IporFusionRoles.ATOMIST_ROLE,
            functionSelector: IporFusionAccessManager.enableTransferShares.selector,
            minimalExecutionDelay: 0
        });

        // RewardsClaimManager
        if (plasmaVaultAddress.rewardsClaimManager == address(0)) {
            return rolesToFunction;
        }
        rolesToFunction[26] = RoleToFunction({
            target: plasmaVaultAddress.rewardsClaimManager,
            roleId: IporFusionRoles.FUSE_MANAGER_ROLE,
            functionSelector: RewardsClaimManager.addRewardFuses.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[27] = RoleToFunction({
            target: plasmaVaultAddress.rewardsClaimManager,
            roleId: IporFusionRoles.FUSE_MANAGER_ROLE,
            functionSelector: RewardsClaimManager.removeRewardFuses.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[28] = RoleToFunction({
            target: plasmaVaultAddress.rewardsClaimManager,
            roleId: IporFusionRoles.CLAIM_REWARDS_ROLE,
            functionSelector: RewardsClaimManager.claimRewards.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[29] = RoleToFunction({
            target: plasmaVaultAddress.rewardsClaimManager,
            roleId: IporFusionRoles.PUBLIC_ROLE,
            functionSelector: RewardsClaimManager.transferVestedTokensToVault.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[31] = RoleToFunction({
            target: plasmaVaultAddress.rewardsClaimManager,
            roleId: IporFusionRoles.TRANSFER_REWARDS_ROLE,
            functionSelector: RewardsClaimManager.transfer.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[32] = RoleToFunction({
            target: plasmaVaultAddress.rewardsClaimManager,
            roleId: IporFusionRoles.PUBLIC_ROLE,
            functionSelector: RewardsClaimManager.updateBalance.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[33] = RoleToFunction({
            target: plasmaVaultAddress.rewardsClaimManager,
            roleId: IporFusionRoles.ATOMIST_ROLE,
            functionSelector: RewardsClaimManager.setupVestingTime.selector,
            minimalExecutionDelay: 0
        });

        return rolesToFunction;
    }
}