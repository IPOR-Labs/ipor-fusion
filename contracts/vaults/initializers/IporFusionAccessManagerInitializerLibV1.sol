// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {RoleToFunction, AdminRole, AccountToRole, InitializationData} from "../../managers/access/IporFusionAccessManagerInitializationLib.sol";
import {PlasmaVault} from "../PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../PlasmaVaultGovernance.sol";
import {PlasmaVaultBase} from "../PlasmaVaultBase.sol";
import {Roles} from "../../libraries/Roles.sol";
import {RewardsClaimManager} from "../../managers/rewards/RewardsClaimManager.sol";
import {IporFusionAccessManager} from "../../managers/access/IporFusionAccessManager.sol";
import {FeeManager} from "../../managers/fee/FeeManager.sol";
import {WithdrawManager} from "../../managers/withdraw/WithdrawManager.sol";
import {ContextClient} from "../../managers/context/ContextClient.sol";
import {ContextManager} from "../../managers/context/ContextManager.sol";

/// @notice Plasma Vault address struct.
struct PlasmaVaultAddress {
    /// @notice Address of the Plasma Vault.
    address plasmaVault;
    /// @notice Address of the Ipor Fusion Access Manager.
    address accessManager;
    /// @notice Address of the Rewards Claim Manager.
    address rewardsClaimManager;
    /// @notice Address of the Withdraw Manager.
    address withdrawManager;
    /// @notice Address of the Fee Manager.
    address feeManager;
    /// @notice Address of the Context Manager.
    address contextManager;
}

/// @notice Data for the initialization of the IPOR Fusion Plasma Vault, contain accounts involved in interactions with the Plasma Vault.
struct DataForInitialization {
    /// @notice Flag to determine if the Plasma Vault is public. If Plasma Vault is public then deposit and mint functions are available for everyone.
    /// @dev Notice! PUBLIC Plasma Vaults cannot be converted to PRIVATE Vault, but PRIVATE Vault can be converted to PUBLIC.
    bool isPublic;
    /// @notice Array of addresses of the DAO (Roles.TECH_IPOR_DAO_ROLE)
    address[] iporDaos;
    /// @notice Array of addresses of the Admins (Roles.ADMIN_ROLE)
    address[] admins;
    /// @notice Array of addresses of the Owners (Roles.OWNER_ROLE)
    address[] owners;
    /// @notice Array of addresses of the Atomists (Roles.ATOMIST_ROLE)
    address[] atomists;
    /// @notice Array of addresses of the Alphas (Roles.ALPHA_ROLE)
    address[] alphas;
    /// @notice Array of addresses of the Whitelist (Roles.WHITELIST_ROLE)
    address[] whitelist;
    /// @notice Array of addresses of the Guardians (Roles.GUARDIAN_ROLE)
    address[] guardians;
    /// @notice Array of addresses of the Fuse Managers (Roles.FUSE_MANAGER_ROLE)
    address[] fuseManagers;
    /// @notice Array of addresses of the Claim Rewards Managers (Roles.CLAIM_REWARDS_ROLE)
    address[] claimRewards;
    /// @notice Array of addresses of the Transfer Rewards Managers (Roles.TRANSFER_REWARDS_ROLE)
    address[] transferRewardsManagers;
    /// @notice Array of addresses of the Config Instant Withdrawal Fuses Managers (Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE)
    address[] configInstantWithdrawalFusesManagers;
    /// @notice Plasma Vault address struct.
    PlasmaVaultAddress plasmaVaultAddress;
}

struct Iterator {
    uint256 index;
}

/// @title IPOR Fusion Plasma Vault Initializer V1 for IPOR Protocol AMM. Responsible for define access to the Plasma Vault for a given addresses.
library IporFusionAccessManagerInitializerLibV1 {
    uint256 private constant ADMIN_ROLES_ARRAY_LENGTH = 14;
    uint256 private constant ROLES_TO_FUNCTION_ARRAY_LENGTH_WHEN_NO_REWARDS_CLAIM_MANAGER = 37;
    uint256 private constant ROLES_TO_FUNCTION_CLAIM_MANAGER = 7;
    uint256 private constant ROLES_TO_FUNCTION_WITHDRAW_MANAGER = 7;
    uint256 private constant ROLES_TO_FUNCTION_FEE_MANAGER = 3;
    uint256 private constant ROLES_TO_FUNCTION_CONTEXT_MANAGER = 2 + 2 + 2 + 2 + 2; // 2 for context manager functions, 2 for plasmaVault technical function, +2 for fee manager functions, 2 for withdraw manager functions + 2 for rewards claim manager functions

    /// @notice Generates the data for the initialization of the IPOR Fusion Plasma Vault.
    /// @param data_ Data for the initialization of the IPOR Fusion Plasma Vault.
    function generateInitializeIporPlasmaVault(
        DataForInitialization memory data_
    ) internal returns (InitializationData memory) {
        InitializationData memory initializeData;
        initializeData.roleToFunctions = _generateRoleToFunction(data_.isPublic, data_.plasmaVaultAddress);
        initializeData.adminRoles = _generateAdminRoles();
        initializeData.accountToRoles = _generateAccountToRoles(data_);
        return initializeData;
    }

    function _generateAccountToRoles(
        DataForInitialization memory data_
    ) private pure returns (AccountToRole[] memory accountToRoles) {
        accountToRoles = new AccountToRole[](
            data_.iporDaos.length +
                data_.admins.length +
                data_.owners.length +
                data_.guardians.length +
                data_.atomists.length +
                data_.alphas.length +
                data_.fuseManagers.length +
                data_.claimRewards.length +
                data_.transferRewardsManagers.length +
                data_.whitelist.length +
                data_.configInstantWithdrawalFusesManagers.length +
                (data_.plasmaVaultAddress.contextManager == address(0) ? 0 : 1) +
                (data_.plasmaVaultAddress.rewardsClaimManager == address(0) ? 0 : 1) +
                (data_.plasmaVaultAddress.feeManager == address(0) ? 0 : 2) +
                1 + // Plasma Vault
                (data_.plasmaVaultAddress.withdrawManager == address(0) ? 0 : 1) // Withdraw Manager
        );
        uint256 index;

        if (data_.plasmaVaultAddress.rewardsClaimManager != address(0)) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.TECH_REWARDS_CLAIM_MANAGER_ROLE,
                account: data_.plasmaVaultAddress.rewardsClaimManager,
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data_.iporDaos.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.IPOR_DAO_ROLE,
                account: data_.iporDaos[i],
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

        for (uint256 i; i < data_.owners.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.OWNER_ROLE,
                account: data_.owners[i],
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

        for (uint256 i; i < data_.fuseManagers.length; ++i) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.FUSE_MANAGER_ROLE,
                account: data_.fuseManagers[i],
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
        accountToRoles[index] = AccountToRole({
            roleId: Roles.TECH_PLASMA_VAULT_ROLE,
            account: data_.plasmaVaultAddress.plasmaVault,
            executionDelay: 0
        });
        ++index;

        if (data_.plasmaVaultAddress.feeManager != address(0)) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.TECH_MANAGEMENT_FEE_MANAGER_ROLE,
                account: data_.plasmaVaultAddress.feeManager,
                executionDelay: 0
            });
            ++index;
            accountToRoles[index] = AccountToRole({
                roleId: Roles.TECH_PERFORMANCE_FEE_MANAGER_ROLE,
                account: data_.plasmaVaultAddress.feeManager,
                executionDelay: 0
            });
            ++index;
        }

        if (data_.plasmaVaultAddress.contextManager != address(0)) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.TECH_CONTEXT_MANAGER_ROLE,
                account: data_.plasmaVaultAddress.contextManager,
                executionDelay: 0
            });
            ++index;
        }

        if (data_.plasmaVaultAddress.withdrawManager != address(0)) {
            accountToRoles[index] = AccountToRole({
                roleId: Roles.TECH_WITHDRAW_MANAGER_ROLE,
                account: data_.plasmaVaultAddress.withdrawManager,
                executionDelay: 0
            });
        }
        return accountToRoles;
    }

    function _generateAdminRoles() private pure returns (AdminRole[] memory adminRoles_) {
        adminRoles_ = new AdminRole[](ADMIN_ROLES_ARRAY_LENGTH);
        Iterator memory iterator;
        adminRoles_[iterator.index] = AdminRole({roleId: Roles.OWNER_ROLE, adminRoleId: Roles.ADMIN_ROLE});
        adminRoles_[_next(iterator)] = AdminRole({roleId: Roles.GUARDIAN_ROLE, adminRoleId: Roles.OWNER_ROLE});
        adminRoles_[_next(iterator)] = AdminRole({roleId: Roles.ATOMIST_ROLE, adminRoleId: Roles.OWNER_ROLE});
        adminRoles_[_next(iterator)] = AdminRole({roleId: Roles.ALPHA_ROLE, adminRoleId: Roles.ATOMIST_ROLE});
        adminRoles_[_next(iterator)] = AdminRole({roleId: Roles.WHITELIST_ROLE, adminRoleId: Roles.ATOMIST_ROLE});
        adminRoles_[_next(iterator)] = AdminRole({
            roleId: Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE,
            adminRoleId: Roles.ATOMIST_ROLE
        });
        adminRoles_[_next(iterator)] = AdminRole({
            roleId: Roles.TRANSFER_REWARDS_ROLE,
            adminRoleId: Roles.ATOMIST_ROLE
        });
        adminRoles_[_next(iterator)] = AdminRole({roleId: Roles.CLAIM_REWARDS_ROLE, adminRoleId: Roles.ATOMIST_ROLE});
        adminRoles_[_next(iterator)] = AdminRole({roleId: Roles.FUSE_MANAGER_ROLE, adminRoleId: Roles.ATOMIST_ROLE});
        adminRoles_[_next(iterator)] = AdminRole({
            roleId: Roles.TECH_PERFORMANCE_FEE_MANAGER_ROLE,
            adminRoleId: Roles.TECH_PERFORMANCE_FEE_MANAGER_ROLE
        });
        adminRoles_[_next(iterator)] = AdminRole({
            roleId: Roles.TECH_MANAGEMENT_FEE_MANAGER_ROLE,
            adminRoleId: Roles.TECH_MANAGEMENT_FEE_MANAGER_ROLE
        });
        adminRoles_[_next(iterator)] = AdminRole({
            roleId: Roles.TECH_REWARDS_CLAIM_MANAGER_ROLE,
            adminRoleId: Roles.ADMIN_ROLE
        });
        adminRoles_[_next(iterator)] = AdminRole({roleId: Roles.IPOR_DAO_ROLE, adminRoleId: Roles.IPOR_DAO_ROLE});
        adminRoles_[_next(iterator)] = AdminRole({
            roleId: Roles.TECH_CONTEXT_MANAGER_ROLE,
            adminRoleId: Roles.TECH_CONTEXT_MANAGER_ROLE
        });
        return adminRoles_;
    }

    function _generateRoleToFunction(
        bool isPublic_,
        PlasmaVaultAddress memory plasmaVaultAddress_
    ) private returns (RoleToFunction[] memory rolesToFunction) {
        Iterator memory iterator;

        uint64 depositAndMintWithPermitRole = isPublic_ ? Roles.PUBLIC_ROLE : Roles.WHITELIST_ROLE;

        uint256 length = ROLES_TO_FUNCTION_ARRAY_LENGTH_WHEN_NO_REWARDS_CLAIM_MANAGER;
        length += plasmaVaultAddress_.rewardsClaimManager == address(0) ? 0 : ROLES_TO_FUNCTION_CLAIM_MANAGER;
        length += plasmaVaultAddress_.withdrawManager == address(0) ? 0 : ROLES_TO_FUNCTION_WITHDRAW_MANAGER;
        length += plasmaVaultAddress_.feeManager == address(0) ? 0 : ROLES_TO_FUNCTION_FEE_MANAGER;
        length += plasmaVaultAddress_.contextManager == address(0) ? 0 : ROLES_TO_FUNCTION_CONTEXT_MANAGER;

        rolesToFunction = new RoleToFunction[](length);

        rolesToFunction[iterator.index] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ALPHA_ROLE,
            functionSelector: PlasmaVault.execute.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: depositAndMintWithPermitRole,
            functionSelector: PlasmaVault.deposit.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: depositAndMintWithPermitRole,
            functionSelector: PlasmaVault.mint.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: depositAndMintWithPermitRole,
            functionSelector: PlasmaVault.depositWithPermit.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.PUBLIC_ROLE,
            functionSelector: PlasmaVault.redeem.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.PUBLIC_ROLE,
            functionSelector: PlasmaVault.redeemFromRequest.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.PUBLIC_ROLE,
            functionSelector: PlasmaVault.withdraw.selector,
            minimalExecutionDelay: 0
        });
        // @dev The shares in this vault are transferable, hence we assign the PUBLIC_ROLE.
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.PUBLIC_ROLE,
            functionSelector: PlasmaVault.transfer.selector,
            minimalExecutionDelay: 0
        });
        // @dev The shares in this vault are transferable, hence we assign the PUBLIC_ROLE.
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.PUBLIC_ROLE,
            functionSelector: PlasmaVault.transferFrom.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.TECH_REWARDS_CLAIM_MANAGER_ROLE,
            functionSelector: PlasmaVault.claimRewards.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.FUSE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.addFuses.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.FUSE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.removeFuses.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.setPreHookImplementations.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.FUSE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.addBalanceFuse.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.FUSE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.removeBalanceFuse.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.TECH_MANAGEMENT_FEE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.configureManagementFee.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.TECH_PERFORMANCE_FEE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.configurePerformanceFee.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.deactivateMarketsLimits.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE,
            functionSelector: PlasmaVaultGovernance.configureInstantWithdrawalFuses.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.setPriceOracleMiddleware.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.setupMarketsLimits.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.activateMarketsLimits.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.TECH_REWARDS_CLAIM_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.setRewardsClaimManagerAddress.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.updateDependencyBalanceGraphs.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.setTotalSupplyCap.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.updateCallbackHandler.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.grantMarketSubstrates.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.TECH_WITHDRAW_MANAGER_ROLE,
            functionSelector: PlasmaVaultBase.transferRequestFee.selector,
            minimalExecutionDelay: 0
        });

        // IporFuseAccessManager
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.accessManager,
            roleId: Roles.ADMIN_ROLE,
            functionSelector: IporFusionAccessManager.initialize.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.accessManager,
            roleId: Roles.TECH_PLASMA_VAULT_ROLE,
            functionSelector: IporFusionAccessManager.convertToPublicVault.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.convertToPublicVault.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.accessManager,
            roleId: Roles.TECH_PLASMA_VAULT_ROLE,
            functionSelector: IporFusionAccessManager.enableTransferShares.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ATOMIST_ROLE,
            functionSelector: PlasmaVaultGovernance.enableTransferShares.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.accessManager,
            roleId: Roles.TECH_PLASMA_VAULT_ROLE,
            functionSelector: IporFusionAccessManager.setMinimalExecutionDelaysForRoles.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.OWNER_ROLE,
            functionSelector: PlasmaVaultGovernance.setMinimalExecutionDelaysForRoles.selector,
            minimalExecutionDelay: 0
        });
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.accessManager,
            roleId: Roles.GUARDIAN_ROLE,
            functionSelector: AccessManager.cancel.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.accessManager,
            roleId: Roles.GUARDIAN_ROLE,
            functionSelector: IporFusionAccessManager.updateTargetClosed.selector,
            minimalExecutionDelay: 0
        });

        // RewardsClaimManager
        if (plasmaVaultAddress_.rewardsClaimManager != address(0)) {
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.rewardsClaimManager,
                roleId: Roles.CLAIM_REWARDS_ROLE,
                functionSelector: RewardsClaimManager.claimRewards.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.rewardsClaimManager,
                roleId: Roles.TRANSFER_REWARDS_ROLE,
                functionSelector: RewardsClaimManager.transfer.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.rewardsClaimManager,
                roleId: Roles.PUBLIC_ROLE,
                functionSelector: RewardsClaimManager.updateBalance.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.rewardsClaimManager,
                roleId: Roles.ATOMIST_ROLE,
                functionSelector: RewardsClaimManager.setupVestingTime.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.rewardsClaimManager,
                roleId: Roles.FUSE_MANAGER_ROLE,
                functionSelector: RewardsClaimManager.addRewardFuses.selector,
                minimalExecutionDelay: 0
            });

            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.rewardsClaimManager,
                roleId: Roles.FUSE_MANAGER_ROLE,
                functionSelector: RewardsClaimManager.removeRewardFuses.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.rewardsClaimManager,
                roleId: Roles.PUBLIC_ROLE,
                functionSelector: RewardsClaimManager.transferVestedTokensToVault.selector,
                minimalExecutionDelay: 0
            });
        }

        if (plasmaVaultAddress_.withdrawManager != address(0)) {
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.withdrawManager,
                roleId: Roles.ALPHA_ROLE,
                functionSelector: WithdrawManager.releaseFunds.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.withdrawManager,
                roleId: Roles.ATOMIST_ROLE,
                functionSelector: WithdrawManager.updateWithdrawWindow.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.withdrawManager,
                roleId: Roles.TECH_PLASMA_VAULT_ROLE,
                functionSelector: WithdrawManager.canWithdrawFromRequest.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.withdrawManager,
                roleId: Roles.TECH_PLASMA_VAULT_ROLE,
                functionSelector: WithdrawManager.canWithdrawFromUnallocated.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.withdrawManager,
                roleId: Roles.ATOMIST_ROLE,
                functionSelector: WithdrawManager.updateWithdrawFee.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.withdrawManager,
                roleId: Roles.ATOMIST_ROLE,
                functionSelector: WithdrawManager.updateRequestFee.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.withdrawManager,
                roleId: Roles.ATOMIST_ROLE,
                functionSelector: WithdrawManager.updatePlasmaVaultAddress.selector,
                minimalExecutionDelay: 0
            });
        }

        if (plasmaVaultAddress_.feeManager != address(0)) {
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.feeManager,
                roleId: Roles.ATOMIST_ROLE,
                functionSelector: FeeManager.updatePerformanceFee.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.feeManager,
                roleId: Roles.ATOMIST_ROLE,
                functionSelector: FeeManager.updateManagementFee.selector,
                minimalExecutionDelay: 0
            });

            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.feeManager,
                roleId: Roles.IPOR_DAO_ROLE,
                functionSelector: FeeManager.setIporDaoFeeRecipientAddress.selector,
                minimalExecutionDelay: 0
            });
        }

        if (plasmaVaultAddress_.contextManager != address(0)) {
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.contextManager,
                roleId: Roles.ATOMIST_ROLE,
                functionSelector: ContextManager.addApprovedTargets.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.contextManager,
                roleId: Roles.ATOMIST_ROLE,
                functionSelector: ContextManager.removeApprovedTargets.selector,
                minimalExecutionDelay: 0
            });

            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.plasmaVault,
                roleId: Roles.TECH_CONTEXT_MANAGER_ROLE,
                functionSelector: ContextClient.setupContext.selector,
                minimalExecutionDelay: 0
            });

            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.plasmaVault,
                roleId: Roles.TECH_CONTEXT_MANAGER_ROLE,
                functionSelector: ContextClient.clearContext.selector,
                minimalExecutionDelay: 0
            });

            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.feeManager,
                roleId: Roles.TECH_CONTEXT_MANAGER_ROLE,
                functionSelector: ContextClient.setupContext.selector,
                minimalExecutionDelay: 0
            });

            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.feeManager,
                roleId: Roles.TECH_CONTEXT_MANAGER_ROLE,
                functionSelector: ContextClient.clearContext.selector,
                minimalExecutionDelay: 0
            });

            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.withdrawManager,
                roleId: Roles.TECH_CONTEXT_MANAGER_ROLE,
                functionSelector: ContextClient.setupContext.selector,
                minimalExecutionDelay: 0
            });

            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.withdrawManager,
                roleId: Roles.TECH_CONTEXT_MANAGER_ROLE,
                functionSelector: ContextClient.clearContext.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.rewardsClaimManager,
                roleId: Roles.TECH_CONTEXT_MANAGER_ROLE,
                functionSelector: ContextClient.setupContext.selector,
                minimalExecutionDelay: 0
            });

            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.rewardsClaimManager,
                roleId: Roles.TECH_CONTEXT_MANAGER_ROLE,
                functionSelector: ContextClient.clearContext.selector,
                minimalExecutionDelay: 0
            });
        }

        return rolesToFunction;
    }

    function _next(Iterator memory iterator_) private pure returns (uint256) {
        iterator_.index++;
        return iterator_.index;
    }
}
