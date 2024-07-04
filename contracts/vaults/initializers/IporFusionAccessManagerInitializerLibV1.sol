// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {RoleToFunction, AdminRole, AccountToRole, InitializationData} from "../../managers/access/IporFusionAccessManagerInitializationLib.sol";
import {PlasmaVault} from "../PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../PlasmaVaultGovernance.sol";
import {Roles} from "../../libraries/Roles.sol";
import {RewardsClaimManager} from "../../managers/rewards/RewardsClaimManager.sol";
import {IporFusionAccessManager} from "../../managers/access/IporFusionAccessManager.sol";

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

/// @title IPOR Fusion Plasma Vault Initializer V1 for IPOR Protocol AMM.
library IporFusionAccessManagerInitializerLibV1 {
    function generateInitializeIporPlasmaVault(
        DataForInitialization memory data_
    ) internal returns (InitializationData memory) {
        InitializationData memory initializeData;
        initializeData.roleToFunctions = _generateRoleToFunction(data_.plasmaVaultAddress);
        initializeData.adminRoles = _generateAdminRoles();
        initializeData.accountToRoles = _generateAccountToRoles(data_);
        initializeData.redemptionDelay = 0;
        return initializeData;
    }

    function _generateAccountToRoles(
        DataForInitialization memory data_
    ) private returns (AccountToRole[] memory accountToRoles) {
        accountToRoles = new AccountToRole[](
            data_.owners.length +
                data_.admins.length +
                data_.atomists.length +
                data_.alphas.length +
                data_.whitelist.length +
                data_.guardians.length +
                data_.fuseManagers.length +
                data_.performanceFeeManagers.length +
                data_.managementFeeManagers.length +
                data_.claimRewards.length +
                data_.transferRewardsManagers.length +
                data_.configInstantWithdrawalFusesManagers.length +
                (data_.claimRewardsManager == address(0) ? 0 : 1)
        );
        uint256 index;

        if (data_.claimRewardsManager != address(0)) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.REWARDS_CLAIM_MANAGER_ROLE,
                account: data_.claimRewardsManager,
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data_.admins.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.ADMIN_ROLE,
                account: data_.admins[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data_.guardians.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.GUARDIAN_ROLE,
                account: data_.guardians[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data_.fuseManagers.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.FUSE_MANAGER_ROLE,
                account: data_.fuseManagers[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data_.performanceFeeManagers.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.PERFORMANCE_FEE_MANAGER_ROLE,
                account: data_.performanceFeeManagers[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data_.managementFeeManagers.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.MANAGEMENT_FEE_MANAGER_ROLE,
                account: data_.managementFeeManagers[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data_.claimRewards.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.CLAIM_REWARDS_ROLE,
                account: data_.claimRewards[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data_.transferRewardsManagers.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.TRANSFER_REWARDS_ROLE,
                account: data_.transferRewardsManagers[i],
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data_.owners.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.OWNER_ROLE,
                account: data_.owners[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data_.atomists.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.ATOMIST_ROLE,
                account: data_.atomists[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data_.alphas.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.ALPHA_ROLE,
                account: data_.alphas[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data_.whitelist.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.WHITELIST_ROLE,
                account: data_.whitelist[i],
                executionDelay: 0
            });
            ++index;
        }
        for (uint256 i; i < data_.configInstantWithdrawalFusesManagers.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE,
                account: data_.configInstantWithdrawalFusesManagers[i],
                executionDelay: 0
            });
            ++index;
        }
        return accountToRoles;
    }

    function _generateAdminRoles() private returns (AdminRole[] memory adminRoles_) {
        adminRoles_ = new AdminRole[](12);
        adminRoles_[0] = AdminRole({roleId: Roles.OWNER_ROLE, adminRoleId: Roles.ADMIN_ROLE});
        adminRoles_[1] = AdminRole({roleId: Roles.GUARDIAN_ROLE, adminRoleId: Roles.OWNER_ROLE});
        adminRoles_[2] = AdminRole({roleId: Roles.ATOMIST_ROLE, adminRoleId: Roles.OWNER_ROLE});
        adminRoles_[3] = AdminRole({roleId: Roles.ALPHA_ROLE, adminRoleId: Roles.ATOMIST_ROLE});
        adminRoles_[4] = AdminRole({roleId: Roles.WHITELIST_ROLE, adminRoleId: Roles.ATOMIST_ROLE});
        adminRoles_[5] = AdminRole({
            roleId: Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE,
            adminRoleId: Roles.ATOMIST_ROLE
        });
        adminRoles_[6] = AdminRole({roleId: Roles.TRANSFER_REWARDS_ROLE, adminRoleId: Roles.ATOMIST_ROLE});
        adminRoles_[7] = AdminRole({roleId: Roles.CLAIM_REWARDS_ROLE, adminRoleId: Roles.ATOMIST_ROLE});
        adminRoles_[8] = AdminRole({roleId: Roles.FUSE_MANAGER_ROLE, adminRoleId: Roles.ATOMIST_ROLE});
        adminRoles_[9] = AdminRole({
            roleId: Roles.PERFORMANCE_FEE_MANAGER_ROLE,
            adminRoleId: Roles.PERFORMANCE_FEE_MANAGER_ROLE
        });
        adminRoles_[10] = AdminRole({
            roleId: Roles.MANAGEMENT_FEE_MANAGER_ROLE,
            adminRoleId: Roles.MANAGEMENT_FEE_MANAGER_ROLE
        });
        adminRoles_[11] = AdminRole({
            roleId: Roles.REWARDS_CLAIM_MANAGER_ROLE,
            adminRoleId: Roles.REWARDS_CLAIM_MANAGER_ROLE
        });
        return adminRoles_;
    }

    function _generateRoleToFunction(
        PlasmaVaultAddress memory plasmaVaultAddress_
    ) private returns (RoleToFunction[] memory rolesToFunction) {
        rolesToFunction = plasmaVaultAddress_.rewardsClaimManager == address(0)
            ? new RoleToFunction[](27)
            : new RoleToFunction[](35);

        rolesToFunction[0] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ALPHA_ROLE,
            functionSelector: PlasmaVault.execute.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[1] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.WHITELIST_ROLE,
            functionSelector: PlasmaVault.deposit.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[2] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.WHITELIST_ROLE,
            functionSelector: PlasmaVault.mint.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[3] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.PUBLIC_ROLE,
            functionSelector: PlasmaVault.redeem.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[4] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.PUBLIC_ROLE,
            functionSelector: PlasmaVault.withdraw.selector,
            minimalExecutionDelay: 0
        });
        // @dev The shares in this vault are transferable, hence we assign the PUBLIC_ROLE.
        rolesToFunction[5] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.PUBLIC_ROLE,
            functionSelector: PlasmaVault.transfer.selector,
            minimalExecutionDelay: 0
        });
        // @dev The shares in this vault are transferable, hence we assign the PUBLIC_ROLE.
        rolesToFunction[6] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.PUBLIC_ROLE,
            functionSelector: PlasmaVault.transferFrom.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[7] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.REWARDS_CLAIM_MANAGER_ROLE,
            functionSelector: PlasmaVault.claimRewards.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[8] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.FUSE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.addFuses.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[9] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.FUSE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.removeFuses.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[10] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.FUSE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.addBalanceFuse.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[11] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.FUSE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.removeBalanceFuse.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[12] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.MANAGEMENT_FEE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.configureManagementFee.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[13] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.PERFORMANCE_FEE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.configurePerformanceFee.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[14] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.deactivateMarketsLimits.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[15] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE,
            functionSelector: PlasmaVaultGovernance.configureInstantWithdrawalFuses.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[16] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.setPriceOracle.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[17] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.setupMarketsLimits.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[18] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.activateMarketsLimits.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[19] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.REWARDS_CLAIM_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.setRewardsClaimManagerAddress.selector,
            minimalExecutionDelay: 0
        });

        // IporFuseAccessManager
        rolesToFunction[20] = RoleToFunction({
            target: plasmaVaultAddress_.accessManager,
            roleId: Roles.GUARDIAN_ROLE,
            functionSelector: AccessManager.cancel.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[21] = RoleToFunction({
            target: plasmaVaultAddress_.accessManager,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: IporFusionAccessManager.setRedemptionDelay.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[22] = RoleToFunction({
            target: plasmaVaultAddress_.accessManager,
            roleId: Roles.GUARDIAN_ROLE,
            functionSelector: IporFusionAccessManager.updateTargetClosed.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[23] = RoleToFunction({
            target: plasmaVaultAddress_.accessManager,
            roleId: Roles.ADMIN_ROLE,
            functionSelector: IporFusionAccessManager.initialize.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[24] = RoleToFunction({
            target: plasmaVaultAddress_.accessManager,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: IporFusionAccessManager.convertToPublicVault.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[25] = RoleToFunction({
            target: plasmaVaultAddress_.accessManager,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: IporFusionAccessManager.enableTransferShares.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[26] = RoleToFunction({
            target: plasmaVaultAddress_.accessManager,
            roleId: Roles.OWNER_ROLE,
            functionSelector: IporFusionAccessManager.setMinimalExecutionDelaysForRoles.selector,
            minimalExecutionDelay: 0
        });

        // RewardsClaimManager
        if (plasmaVaultAddress_.rewardsClaimManager == address(0)) {
            return rolesToFunction;
        }
        rolesToFunction[26] = RoleToFunction({
            target: plasmaVaultAddress_.rewardsClaimManager,
            roleId: Roles.FUSE_MANAGER_ROLE,
            functionSelector: RewardsClaimManager.addRewardFuses.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[27] = RoleToFunction({
            target: plasmaVaultAddress_.rewardsClaimManager,
            roleId: Roles.FUSE_MANAGER_ROLE,
            functionSelector: RewardsClaimManager.removeRewardFuses.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[28] = RoleToFunction({
            target: plasmaVaultAddress_.rewardsClaimManager,
            roleId: Roles.CLAIM_REWARDS_ROLE,
            functionSelector: RewardsClaimManager.claimRewards.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[29] = RoleToFunction({
            target: plasmaVaultAddress_.rewardsClaimManager,
            roleId: Roles.PUBLIC_ROLE,
            functionSelector: RewardsClaimManager.transferVestedTokensToVault.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[31] = RoleToFunction({
            target: plasmaVaultAddress_.rewardsClaimManager,
            roleId: Roles.TRANSFER_REWARDS_ROLE,
            functionSelector: RewardsClaimManager.transfer.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[32] = RoleToFunction({
            target: plasmaVaultAddress_.rewardsClaimManager,
            roleId: Roles.PUBLIC_ROLE,
            functionSelector: RewardsClaimManager.updateBalance.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[33] = RoleToFunction({
            target: plasmaVaultAddress_.rewardsClaimManager,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: RewardsClaimManager.setupVestingTime.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[34] = RoleToFunction({
            target: plasmaVaultAddress_.rewardsClaimManager,
            roleId: Roles.FUSE_MANAGER_ROLE,
            functionSelector: RewardsClaimManager.addRewardFuses.selector,
            minimalExecutionDelay: 0
        });

        return rolesToFunction;
    }
}
