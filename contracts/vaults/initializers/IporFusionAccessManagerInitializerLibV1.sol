// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPlasmaVault} from "../../interfaces/IPlasmaVault.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {
    RoleToFunction,
    AdminRole,
    AccountToRole,
    InitializationData
} from "../../managers/access/IporFusionAccessManagerInitializationLib.sol";
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

    uint256 private constant ADMIN_ROLES_ARRAY_LENGTH = 21;
    uint256 private constant ROLES_TO_FUNCTION_INITIAL_ARRAY_LENGTH = 42;
    uint256 private constant ROLES_TO_FUNCTION_CLAIM_MANAGER = 8;
    uint256 private constant ROLES_TO_FUNCTION_WITHDRAW_MANAGER = 7;
    uint256 private constant ROLES_TO_FUNCTION_FEE_MANAGER = 6;
    uint256 private constant ROLES_TO_FUNCTION_CONTEXT_MANAGER = 2 + 2 + 2 + 2 + 2; // 2 for context manager functions, 2 for plasmaVault technical function, +2 for fee manager functions, 2 for withdraw manager functions + 2 for rewards claim manager functions
    uint256 private constant ROLES_TO_FUNCTION_PRICE_ORACLE_MIDDLEWARE_MANAGER = 9;

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
        PlasmaVaultAddress memory addresses = data_.plasmaVaultAddress;

        if (
            addresses.plasmaVault == address(0) ||
            addresses.accessManager == address(0) ||
            addresses.rewardsClaimManager == address(0) ||
            addresses.feeManager == address(0) ||
            addresses.contextManager == address(0) ||
            addresses.withdrawManager == address(0) ||
            addresses.priceOracleMiddlewareManager == address(0)
        ) {
            revert InvalidAddress();
        }

        accountToRoles = _prepareAccountToRoles(data_);

        uint256 index;

        if (addresses.rewardsClaimManager != address(0)) {
            index = _appendAccount(
                accountToRoles,
                index,
                Roles.TECH_REWARDS_CLAIM_MANAGER_ROLE,
                addresses.rewardsClaimManager
            );
        }

        index = _appendAccounts(accountToRoles, index, Roles.IPOR_DAO_ROLE, data_.iporDaos);
        index = _appendAccounts(accountToRoles, index, Roles.ADMIN_ROLE, data_.admins);
        index = _appendAccounts(accountToRoles, index, Roles.OWNER_ROLE, data_.owners);
        index = _appendAccounts(accountToRoles, index, Roles.GUARDIAN_ROLE, data_.guardians);
        index = _appendAccounts(accountToRoles, index, Roles.ATOMIST_ROLE, data_.atomists);
        index = _appendAccounts(accountToRoles, index, Roles.ALPHA_ROLE, data_.alphas);
        index = _appendAccounts(accountToRoles, index, Roles.FUSE_MANAGER_ROLE, data_.fuseManagers);
        index = _appendAccounts(accountToRoles, index, Roles.CLAIM_REWARDS_ROLE, data_.claimRewards);
        index = _appendAccounts(accountToRoles, index, Roles.TRANSFER_REWARDS_ROLE, data_.transferRewardsManagers);
        index = _appendAccounts(accountToRoles, index, Roles.WHITELIST_ROLE, data_.whitelist);
        index = _appendAccounts(
            accountToRoles,
            index,
            Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE,
            data_.configInstantWithdrawalFusesManagers
        );
        index = _appendAccounts(
            accountToRoles,
            index,
            Roles.UPDATE_MARKETS_BALANCES_ROLE,
            data_.updateMarketsBalancesAccounts
        );
        index = _appendAccounts(accountToRoles, index, Roles.PRE_HOOKS_MANAGER_ROLE, data_.preHooksManagers);

        /// @dev Always add UPDATE_MARKETS_BALANCES_ROLE to the Plasma Vault
        index = _appendAccount(accountToRoles, index, Roles.UPDATE_MARKETS_BALANCES_ROLE, addresses.plasmaVault);

        index = _appendAccounts(
            accountToRoles,
            index,
            Roles.UPDATE_REWARDS_BALANCE_ROLE,
            data_.updateRewardsBalanceAccounts
        );
        index = _appendAccounts(
            accountToRoles,
            index,
            Roles.WITHDRAW_MANAGER_REQUEST_FEE_ROLE,
            data_.withdrawManagerRequestFeeManagers
        );
        index = _appendAccounts(
            accountToRoles,
            index,
            Roles.WITHDRAW_MANAGER_WITHDRAW_FEE_ROLE,
            data_.withdrawManagerWithdrawFeeManagers
        );

        index = _appendAccount(accountToRoles, index, Roles.TECH_PLASMA_VAULT_ROLE, addresses.plasmaVault);

        if (addresses.feeManager != address(0)) {
            index = _appendAccount(accountToRoles, index, Roles.TECH_MANAGEMENT_FEE_MANAGER_ROLE, addresses.feeManager);
            index = _appendAccount(
                accountToRoles,
                index,
                Roles.TECH_PERFORMANCE_FEE_MANAGER_ROLE,
                addresses.feeManager
            );
            index = _appendAccount(accountToRoles, index, Roles.TECH_VAULT_TRANSFER_SHARES_ROLE, addresses.feeManager);
        }

        if (addresses.contextManager != address(0)) {
            index = _appendAccount(accountToRoles, index, Roles.TECH_CONTEXT_MANAGER_ROLE, addresses.contextManager);
        }

        if (addresses.withdrawManager != address(0)) {
            index = _appendAccount(accountToRoles, index, Roles.TECH_WITHDRAW_MANAGER_ROLE, addresses.withdrawManager);
        }

        if (addresses.priceOracleMiddlewareManager != address(0)) {
            index = _appendAccounts(
                accountToRoles,
                index,
                Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE,
                data_.priceOracleMiddlewareManagers
            );
        }
        return accountToRoles;
    }

    /// @dev Appends one AccountToRole entry (execution delay 0) per account, reverts on the zero address.
    /// Shared by every role list to keep the generated bytecode small - the library is inlined into FusionFactoryLogicLib
    /// @return The next free index in accountToRoles_
    function _appendAccounts(
        AccountToRole[] memory accountToRoles_,
        uint256 index_,
        uint64 roleId_,
        address[] memory accounts_
    ) private pure returns (uint256) {
        uint256 length = accounts_.length;
        for (uint256 i; i < length; ++i) {
            if (accounts_[i] == address(0)) {
                revert InvalidAddress();
            }
            index_ = _appendAccount(accountToRoles_, index_, roleId_, accounts_[i]);
        }
        return index_;
    }

    /// @dev Appends a single AccountToRole entry with execution delay 0
    /// @return The next free index in accountToRoles_
    function _appendAccount(
        AccountToRole[] memory accountToRoles_,
        uint256 index_,
        uint64 roleId_,
        address account_
    ) private pure returns (uint256) {
        accountToRoles_[index_] = AccountToRole({roleId: roleId_, account: account_, executionDelay: 0});
        return index_ + 1;
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
        adminRoles_[_next(iterator)] = AdminRole({roleId: Roles.PAUSER_ROLE, adminRoleId: Roles.OWNER_ROLE});
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

        /// @dev Only the vault (TECH_PLASMA_VAULT_ROLE) writes the redemption delay on the access manager - the
        /// owner-facing entry point is PlasmaVaultGovernance.setRedemptionDelay below. That entry point can be timelocked
        /// only through the OWNER_ROLE execution delay: this initializer grants OWNER_ROLE with executionDelay 0 and sets no
        /// minimalExecutionDelay (per-role granularity, a non-zero value here would apply to every OWNER_ROLE function and
        /// break the executionDelay: 0 grants above), so by default the owner changes the redemption delay immediately
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.accessManager,
            roleId: Roles.TECH_PLASMA_VAULT_ROLE,
            functionSelector: IporFusionAccessManager.setRedemptionDelay.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.OWNER_ROLE,
            functionSelector: PlasmaVaultGovernance.setMinimalExecutionDelaysForRoles.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.plasmaVault,
            roleId: Roles.OWNER_ROLE,
            functionSelector: PlasmaVaultGovernance.setRedemptionDelay.selector,
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

        /// @dev One-way emergency pause for automated pausers (PlasmaVaultPauser): PAUSER_ROLE can only close a target,
        /// it can neither reopen it nor cancel scheduled operations. Nobody holds it after initialization - the
        /// OWNER_ROLE (admin of PAUSER_ROLE) grants it to the pauser contract explicitly
        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.accessManager,
            roleId: Roles.PAUSER_ROLE,
            functionSelector: IporFusionAccessManager.closeTarget.selector,
            minimalExecutionDelay: 0
        });

        rolesToFunction[_next(iterator)] = RoleToFunction({
            target: plasmaVaultAddress_.accessManager,
            roleId: Roles.TECH_PLASMA_VAULT_ROLE,
            functionSelector: IporFusionAccessManager.canCallAndUpdate.selector,
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
                roleId: Roles.ATOMIST_ROLE,
                functionSelector: RewardsClaimManager.rescheduleVesting.selector,
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
                roleId: Roles.TECH_CONTEXT_MANAGER_ROLE,
                functionSelector: ContextClient.setupContext.selector,
                minimalExecutionDelay: 0
            });
            rolesToFunction[_next(iterator)] = RoleToFunction({
                target: plasmaVaultAddress_.priceOracleMiddlewareManager,
                roleId: Roles.TECH_CONTEXT_MANAGER_ROLE,
                functionSelector: ContextClient.clearContext.selector,
                minimalExecutionDelay: 0
            });
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
