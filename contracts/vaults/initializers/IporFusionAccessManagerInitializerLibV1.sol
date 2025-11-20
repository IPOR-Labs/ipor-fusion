// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPlasmaVault} from "../../interfaces/IPlasmaVault.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {RoleToFunction, AdminRole, AccountToRole, InitializationData} from "../../managers/access/IporFusionAccessManagerInitializationLib.sol";
import {PlasmaVaultGovernance} from "../PlasmaVaultGovernance.sol";
import {PlasmaVaultBase} from "../PlasmaVaultBase.sol";
import {Roles} from "../../libraries/Roles.sol";
import {RewardsClaimManager} from "../../managers/rewards/RewardsClaimManager.sol";
import {IporFusionAccessManager} from "../../managers/access/IporFusionAccessManager.sol";
import {FeeManager} from "../../managers/fee/FeeManager.sol";
import {WithdrawManager} from "../../managers/withdraw/WithdrawManager.sol";
import {ContextClient} from "../../managers/context/ContextClient.sol";
import {ContextManager} from "../../managers/context/ContextManager.sol";
import {PriceOracleMiddlewareManager} from "../../managers/price/PriceOracleMiddlewareManager.sol";

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
    /// @notice Address of the Price Oracle Middleware Manager.
    address priceOracleMiddlewareManager;
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
    /// @notice Array of addresses of the Update Markets Balances Managers (Roles.UPDATE_MARKETS_BALANCES_ROLE)
    address[] updateMarketsBalancesAccounts;
    /// @notice Array of addresses of the Update Rewards Balance Managers (Roles.UPDATE_REWARDS_BALANCE_ROLE)
    address[] updateRewardsBalanceAccounts;
    /// @notice Array of addresses of the Withdraw Manager Request Fee Managers (Roles.WITHDRAW_MANAGER_REQUEST_FEE_ROLE)
    address[] withdrawManagerRequestFeeManagers;
    /// @notice Array of addresses of the Withdraw Manager Withdraw Fee Managers (Roles.WITHDRAW_MANAGER_WITHDRAW_FEE_ROLE)
    address[] withdrawManagerWithdrawFeeManagers;
    /// @notice Array of addresses of the Price Oracle Middleware Manager (Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE)
    address[] priceOracleMiddlewareManagers;
    /// @notice Array of addresses of the Pre Hooks Manager (Roles.PRE_HOOKS_MANAGER_ROLE)
    address[] preHooksManagers;
    /// @notice Plasma Vault address struct.
    PlasmaVaultAddress plasmaVaultAddress;
}

struct Iterator {
    uint256 index;
}

/// @title IPOR Fusion Plasma Vault Initializer V1 for IPOR Protocol AMM. Responsible for define access to the Plasma Vault for a given addresses.
library IporFusionAccessManagerInitializerLibV1 {
    error InvalidAddress();

    uint256 private constant ADMIN_ROLES_ARRAY_LENGTH = 20;
    uint256 private constant ROLES_TO_FUNCTION_INITIAL_ARRAY_LENGTH = 39;
    uint256 private constant ROLES_TO_FUNCTION_CLAIM_MANAGER = 7;
    uint256 private constant ROLES_TO_FUNCTION_WITHDRAW_MANAGER = 7;
    uint256 private constant ROLES_TO_FUNCTION_FEE_MANAGER = 6;
    uint256 private constant ROLES_TO_FUNCTION_CONTEXT_MANAGER = 2 + 2 + 2 + 2 + 2; // 2 for context manager functions, 2 for plasmaVault technical function, +2 for fee manager functions, 2 for withdraw manager functions + 2 for rewards claim manager functions
    uint256 private constant ROLES_TO_FUNCTION_PRICE_ORACLE_MIDDLEWARE_MANAGER = 7;

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
        if (data_.plasmaVaultAddress.plasmaVault == address(0)) {
            revert InvalidAddress();
        }
        if (data_.plasmaVaultAddress.accessManager == address(0)) {
            revert InvalidAddress();
        }
        if (data_.plasmaVaultAddress.rewardsClaimManager == address(0)) {
            revert InvalidAddress();
        }
        if (data_.plasmaVaultAddress.feeManager == address(0)) {
            revert InvalidAddress();
        }
        if (data_.plasmaVaultAddress.contextManager == address(0)) {
            revert InvalidAddress();
        }
        if (data_.plasmaVaultAddress.withdrawManager == address(0)) {
            revert InvalidAddress();
        }
        if (data_.plasmaVaultAddress.priceOracleMiddlewareManager == address(0)) {
            revert InvalidAddress();
        }

        accountToRoles = _prepareAccountToRoles(data_);

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
            if (data_.iporDaos[i] == address(0)) {
                revert InvalidAddress();
            }
            accountToRoles[index] = AccountToRole({
                roleId: Roles.IPOR_DAO_ROLE,
                account: data_.iporDaos[i],
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data_.admins.length; ++i) {
            if (data_.admins[i] == address(0)) {
                revert InvalidAddress();
            }
            accountToRoles[index] = AccountToRole({
                roleId: Roles.ADMIN_ROLE,
                account: data_.admins[i],
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data_.owners.length; ++i) {
            if (data_.owners[i] == address(0)) {
                revert InvalidAddress();
            }
            accountToRoles[index] = AccountToRole({
                roleId: Roles.OWNER_ROLE,
                account: data_.owners[i],
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data_.guardians.length; ++i) {
            if (data_.guardians[i] == address(0)) {
                revert InvalidAddress();
            }
            accountToRoles[index] = AccountToRole({
                roleId: Roles.GUARDIAN_ROLE,
                account: data_.guardians[i],
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data_.atomists.length; ++i) {
            if (data_.atomists[i] == address(0)) {
                revert InvalidAddress();
            }
            accountToRoles[index] = AccountToRole({
                roleId: Roles.ATOMIST_ROLE,
                account: data_.atomists[i],
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data_.alphas.length; ++i) {
            if (data_.alphas[i] == address(0)) {
                revert InvalidAddress();
            }
            accountToRoles[index] = AccountToRole({
                roleId: Roles.ALPHA_ROLE,
                account: data_.alphas[i],
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data_.fuseManagers.length; ++i) {
            if (data_.fuseManagers[i] == address(0)) {
                revert InvalidAddress();
            }
            accountToRoles[index] = AccountToRole({
                roleId: Roles.FUSE_MANAGER_ROLE,
                account: data_.fuseManagers[i],
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data_.claimRewards.length; ++i) {
            if (data_.claimRewards[i] == address(0)) {
                revert InvalidAddress();
            }
            accountToRoles[index] = AccountToRole({
                roleId: Roles.CLAIM_REWARDS_ROLE,
                account: data_.claimRewards[i],
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data_.transferRewardsManagers.length; ++i) {
            if (data_.transferRewardsManagers[i] == address(0)) {
                revert InvalidAddress();
            }
            accountToRoles[index] = AccountToRole({
                roleId: Roles.TRANSFER_REWARDS_ROLE,
                account: data_.transferRewardsManagers[i],
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data_.whitelist.length; ++i) {
            if (data_.whitelist[i] == address(0)) {
                revert InvalidAddress();
            }
            accountToRoles[index] = AccountToRole({
                roleId: Roles.WHITELIST_ROLE,
                account: data_.whitelist[i],
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data_.configInstantWithdrawalFusesManagers.length; ++i) {
            if (data_.configInstantWithdrawalFusesManagers[i] == address(0)) {
                revert InvalidAddress();
            }
            accountToRoles[index] = AccountToRole({
                roleId: Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE,
                account: data_.configInstantWithdrawalFusesManagers[i],
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data_.updateMarketsBalancesAccounts.length; ++i) {
            if (data_.updateMarketsBalancesAccounts[i] == address(0)) {
                revert InvalidAddress();
            }
            accountToRoles[index] = AccountToRole({
                roleId: Roles.UPDATE_MARKETS_BALANCES_ROLE,
                account: data_.updateMarketsBalancesAccounts[i],
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data_.preHooksManagers.length; ++i) {
            if (data_.preHooksManagers[i] == address(0)) {
                revert InvalidAddress();
            }
            accountToRoles[index] = AccountToRole({
                roleId: Roles.PRE_HOOKS_MANAGER_ROLE,
                account: data_.preHooksManagers[i],
                executionDelay: 0
            });
            ++index;
        }

        /// @dev Always add UPDATE_MARKETS_BALANCES_ROLE to the Plasma Vault

        accountToRoles[index] = AccountToRole({
            roleId: Roles.UPDATE_MARKETS_BALANCES_ROLE,
            account: data_.plasmaVaultAddress.plasmaVault,
            executionDelay: 0
        });
        ++index;

        for (uint256 i; i < data_.updateRewardsBalanceAccounts.length; ++i) {
            if (data_.updateRewardsBalanceAccounts[i] == address(0)) {
                revert InvalidAddress();
            }
            accountToRoles[index] = AccountToRole({
                roleId: Roles.UPDATE_REWARDS_BALANCE_ROLE,
                account: data_.updateRewardsBalanceAccounts[i],
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data_.withdrawManagerRequestFeeManagers.length; ++i) {
            if (data_.withdrawManagerRequestFeeManagers[i] == address(0)) {
                revert InvalidAddress();
            }
            accountToRoles[index] = AccountToRole({
                roleId: Roles.WITHDRAW_MANAGER_REQUEST_FEE_ROLE,
                account: data_.withdrawManagerRequestFeeManagers[i],
                executionDelay: 0
            });
            ++index;
        }

        for (uint256 i; i < data_.withdrawManagerWithdrawFeeManagers.length; ++i) {
            if (data_.withdrawManagerWithdrawFeeManagers[i] == address(0)) {
                revert InvalidAddress();
            }
            accountToRoles[index] = AccountToRole({
                roleId: Roles.WITHDRAW_MANAGER_WITHDRAW_FEE_ROLE,
                account: data_.withdrawManagerWithdrawFeeManagers[i],
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

            accountToRoles[index] = AccountToRole({
                roleId: Roles.TECH_VAULT_TRANSFER_SHARES_ROLE,
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
            ++index;
        }

        if (data_.plasmaVaultAddress.priceOracleMiddlewareManager != address(0)) {
            for (uint256 i; i < data_.priceOracleMiddlewareManagers.length; ++i) {
                accountToRoles[index] = AccountToRole({
                    roleId: Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE,
                    account: data_.priceOracleMiddlewareManagers[i],
                    executionDelay: 0
                });
                ++index;
            }
        }
        return accountToRoles;
    }

    function _prepareAccountToRoles(
        DataForInitialization memory data_
    ) private pure returns (AccountToRole[] memory accountToRoles_) {
        accountToRoles_ = new AccountToRole[](
            _prepareAdminRolesLengthPatch1(data_) + _prepareAdminRolesLengthPatch2(data_)
        );
    }

    function _prepareAdminRolesLengthPatch1(DataForInitialization memory data_) private pure returns (uint256) {
        return
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
            data_.priceOracleMiddlewareManagers.length +
            data_.preHooksManagers.length;
    }

    function _prepareAdminRolesLengthPatch2(DataForInitialization memory data_) private pure returns (uint256) {
        return
            data_.updateMarketsBalancesAccounts.length +
            data_.updateRewardsBalanceAccounts.length +
            data_.withdrawManagerRequestFeeManagers.length +
            data_.withdrawManagerWithdrawFeeManagers.length +
            (data_.plasmaVaultAddress.contextManager == address(0) ? 0 : 1) + /// @dev +1 TECH_CONTEXT_MANAGER_ROLE
            (data_.plasmaVaultAddress.rewardsClaimManager == address(0) ? 0 : 1) + /// @dev +1 TECH_REWARDS_CLAIM_MANAGER_ROLE
            (data_.plasmaVaultAddress.feeManager == address(0) ? 0 : 3) + /// @dev +2 TECH_PERFORMANCE_FEE_MANAGER_ROLE, TECH_MANAGEMENT_FEE_MANAGER_ROLE, TECH_VAULT_TRANSFER_SHARES_ROLE
            2 + /// @dev +2 - UPDATE_MARKETS_BALANCES_ROLE, TECH_PLASMA_VAULT_ROLE for Plasma Vault
            (data_.plasmaVaultAddress.withdrawManager == address(0) ? 0 : 1); /// @dev +1 TECH_WITHDRAW_MANAGER_ROLE
    }

    function _generateAdminRoles() private pure returns (AdminRole[] memory adminRoles_) {
        adminRoles_ = new AdminRole[](ADMIN_ROLES_ARRAY_LENGTH);
        Iterator memory iterator;
        adminRoles_[iterator.index] = AdminRole({roleId: Roles.OWNER_ROLE, adminRoleId: Roles.OWNER_ROLE});
        adminRoles_[_next(iterator)] = AdminRole({roleId: Roles.GUARDIAN_ROLE, adminRoleId: Roles.OWNER_ROLE});
        adminRoles_[_next(iterator)] = AdminRole({roleId: Roles.PRE_HOOKS_MANAGER_ROLE, adminRoleId: Roles.OWNER_ROLE});
        adminRoles_[_next(iterator)] = AdminRole({roleId: Roles.ATOMIST_ROLE, adminRoleId: Roles.OWNER_ROLE});
        adminRoles_[_next(iterator)] = AdminRole({roleId: Roles.ALPHA_ROLE, adminRoleId: Roles.ATOMIST_ROLE});
        adminRoles_[_next(iterator)] = AdminRole({roleId: Roles.WHITELIST_ROLE, adminRoleId: Roles.ATOMIST_ROLE});
        adminRoles_[_next(iterator)] = AdminRole({
            roleId: Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE,
            adminRoleId: Roles.ATOMIST_ROLE
        });
        adminRoles_[_next(iterator)] = AdminRole({
            roleId: Roles.WITHDRAW_MANAGER_REQUEST_FEE_ROLE,
            adminRoleId: Roles.ATOMIST_ROLE
        });
        adminRoles_[_next(iterator)] = AdminRole({
            roleId: Roles.WITHDRAW_MANAGER_WITHDRAW_FEE_ROLE,
            adminRoleId: Roles.ATOMIST_ROLE
        });
        adminRoles_[_next(iterator)] = AdminRole({
            roleId: Roles.UPDATE_MARKETS_BALANCES_ROLE,
            adminRoleId: Roles.ATOMIST_ROLE
        });
        adminRoles_[_next(iterator)] = AdminRole({
            roleId: Roles.UPDATE_REWARDS_BALANCE_ROLE,
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
        adminRoles_[_next(iterator)] = AdminRole({
            roleId: Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE,
            adminRoleId: Roles.ATOMIST_ROLE
        });
        return adminRoles_;
    }

    function _generateRoleToFunction(
        bool isPublic_,
        PlasmaVaultAddress memory plasmaVaultAddress_
    ) private pure returns (RoleToFunction[] memory rolesToFunction) {
        Iterator memory iterator;

        uint64 depositAndMintWithPermitRole = isPublic_ ? Roles.PUBLIC_ROLE : Roles.WHITELIST_ROLE;

        uint256 length = ROLES_TO_FUNCTION_INITIAL_ARRAY_LENGTH;
        length += plasmaVaultAddress_.rewardsClaimManager == address(0) ? 0 : ROLES_TO_FUNCTION_CLAIM_MANAGER;
        length += plasmaVaultAddress_.withdrawManager == address(0) ? 0 : ROLES_TO_FUNCTION_WITHDRAW_MANAGER;
        length += plasmaVaultAddress_.feeManager == address(0) ? 0 : ROLES_TO_FUNCTION_FEE_MANAGER;
        length += plasmaVaultAddress_.contextManager == address(0) ? 0 : ROLES_TO_FUNCTION_CONTEXT_MANAGER;
        length += plasmaVaultAddress_.priceOracleMiddlewareManager == address(0)
            ? 0
            : ROLES_TO_FUNCTION_PRICE_ORACLE_MIDDLEWARE_MANAGER;

        rolesToFunction = new RoleToFunction[](length);

        rolesToFunction[iterator.index] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.ALPHA_ROLE,
            functionSelector: IPlasmaVault.execute.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: depositAndMintWithPermitRole,
            functionSelector: IERC4626.deposit.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: depositAndMintWithPermitRole,
            functionSelector: IERC4626.mint.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: depositAndMintWithPermitRole,
            functionSelector: IPlasmaVault.depositWithPermit.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.PUBLIC_ROLE,
            functionSelector: IERC4626.redeem.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.PUBLIC_ROLE,
            functionSelector: IPlasmaVault.redeemFromRequest.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.PUBLIC_ROLE,
            functionSelector: IERC4626.withdraw.selector,
            minimalExecutionDelay: 0
        });

        /// @dev The shares in this vault are transferable, hence we assign the PUBLIC_ROLE.
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.TECH_VAULT_TRANSFER_SHARES_ROLE,
            functionSelector: IERC20.transfer.selector,
            minimalExecutionDelay: 0
        });

        /// @dev The shares in this vault are transferable, hence we assign the PUBLIC_ROLE.
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.TECH_VAULT_TRANSFER_SHARES_ROLE,
            functionSelector: IERC20.transferFrom.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.TECH_REWARDS_CLAIM_MANAGER_ROLE,
            functionSelector: IPlasmaVault.claimRewards.selector,
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
            roleId: Roles.PRE_HOOKS_MANAGER_ROLE,
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
            roleId: Roles.UPDATE_MARKETS_BALANCES_ROLE,
            functionSelector: IPlasmaVault.updateMarketsBalances.selector,
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
            roleId: Roles.FUSE_MANAGER_ROLE,
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
            roleId: Roles.FUSE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.updateCallbackHandler.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.FUSE_MANAGER_ROLE,
            functionSelector: PlasmaVaultGovernance.grantMarketSubstrates.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.TECH_WITHDRAW_MANAGER_ROLE,
            functionSelector: PlasmaVaultBase.transferRequestSharesFee.selector,
            minimalExecutionDelay: 0
        });

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
                roleId: Roles.UPDATE_REWARDS_BALANCE_ROLE,
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
                roleId: Roles.WITHDRAW_MANAGER_WITHDRAW_FEE_ROLE,
                functionSelector: WithdrawManager.updateWithdrawFee.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.withdrawManager,
                roleId: Roles.WITHDRAW_MANAGER_REQUEST_FEE_ROLE,
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
                roleId: Roles.ATOMIST_ROLE,
                functionSelector: FeeManager.setDepositFee.selector,
                minimalExecutionDelay: 0
            });

            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.feeManager,
                roleId: Roles.IPOR_DAO_ROLE,
                functionSelector: FeeManager.setIporDaoFeeRecipientAddress.selector,
                minimalExecutionDelay: 0
            });

            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.feeManager,
                roleId: Roles.OWNER_ROLE,
                functionSelector: FeeManager.updateHighWaterMarkPerformanceFee.selector,
                minimalExecutionDelay: 0
            });

            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.feeManager,
                roleId: Roles.OWNER_ROLE,
                functionSelector: FeeManager.updateIntervalHighWaterMarkPerformanceFee.selector,
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

        if (plasmaVaultAddress_.priceOracleMiddlewareManager != address(0)) {
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.priceOracleMiddlewareManager,
                roleId: Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE,
                functionSelector: PriceOracleMiddlewareManager.setAssetsPriceSources.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.priceOracleMiddlewareManager,
                roleId: Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE,
                functionSelector: PriceOracleMiddlewareManager.removeAssetsPriceSources.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.priceOracleMiddlewareManager,
                roleId: Roles.ATOMIST_ROLE,
                functionSelector: PriceOracleMiddlewareManager.setPriceOracleMiddleware.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.priceOracleMiddlewareManager,
                roleId: Roles.ATOMIST_ROLE,
                functionSelector: PriceOracleMiddlewareManager.updatePriceValidation.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.priceOracleMiddlewareManager,
                roleId: Roles.ATOMIST_ROLE,
                functionSelector: PriceOracleMiddlewareManager.removePriceValidation.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.priceOracleMiddlewareManager,
                roleId: Roles.TECH_PLASMA_VAULT_ROLE,
                functionSelector: PriceOracleMiddlewareManager.validateAllAssetsPrices.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.priceOracleMiddlewareManager,
                roleId: Roles.TECH_PLASMA_VAULT_ROLE,
                functionSelector: PriceOracleMiddlewareManager.validateAssetsPrices.selector,
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
