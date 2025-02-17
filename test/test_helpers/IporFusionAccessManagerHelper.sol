// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {TestAddresses} from "./TestAddresses.sol";
import {IporFusionAccessManagerInitializerLibV1, InitializationData, DataForInitialization, PlasmaVaultAddress} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";

/// @title IporFusionAccessManagerHelper
/// @notice Helper library for setting up roles in IporFusionAccessManager
/// @dev Contains utility functions to assist with access management testing
library IporFusionAccessManagerHelper {
    struct RoleAddresses {
        address[] daos;
        address[] admins;
        address[] owners;
        address[] atomists;
        address[] alphas;
        address[] guardians;
        address[] fuseManagers;
        address[] claimRewards;
        address[] transferRewardsManagers;
        address[] configInstantWithdrawalFusesManagers;
        address[] updateMarketsBalancesAccounts;
        address[] updateRewardsBalanceAccounts;
        address[] whitelist;
    }

    /// @notice Creates default role addresses using TestAddresses
    function createDefaultRoleAddresses() internal pure returns (RoleAddresses memory roles) {
        // Create arrays with single address for each role
        roles.daos = new address[](1);
        roles.daos[0] = TestAddresses.DAO;

        roles.admins = new address[](1);
        roles.admins[0] = TestAddresses.ADMIN;

        roles.owners = new address[](1);
        roles.owners[0] = TestAddresses.OWNER;

        roles.atomists = new address[](1);
        roles.atomists[0] = TestAddresses.ATOMIST;

        roles.alphas = new address[](1);
        roles.alphas[0] = TestAddresses.ALPHA;

        roles.guardians = new address[](1);
        roles.guardians[0] = TestAddresses.GUARDIAN;

        roles.fuseManagers = new address[](1);
        roles.fuseManagers[0] = TestAddresses.FUSE_MANAGER;

        roles.claimRewards = new address[](1);
        roles.claimRewards[0] = TestAddresses.CLAIM_REWARDS;

        roles.transferRewardsManagers = new address[](1);
        roles.transferRewardsManagers[0] = TestAddresses.TRANSFER_REWARDS_MANAGER;

        roles.configInstantWithdrawalFusesManagers = new address[](1);
        roles.configInstantWithdrawalFusesManagers[0] = TestAddresses.CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER;

        roles.whitelist = new address[](0);

        return roles;
    }

    /// @notice Sets up initial roles for the PlasmaVault's AccessManager
    /// @param accessManager_ The access manager to initialize
    /// @param plasmaVault_ The plasma vault to set up roles for
    /// @param roles_ The role addresses to set up
    function setupInitRoles(
        IporFusionAccessManager accessManager_,
        PlasmaVault plasmaVault_,
        RoleAddresses memory roles_,
        address withdrawManager_
    ) internal returns (ContextManager contextManager) {
        address[] memory approvedAddresses = new address[](1);
        approvedAddresses[0] = address(plasmaVault_);
        contextManager = new ContextManager(address(accessManager_), approvedAddresses);

        // Prepare initialization data
        DataForInitialization memory data = DataForInitialization({
            isPublic: true,
            iporDaos: roles_.daos,
            admins: roles_.admins,
            owners: roles_.owners,
            atomists: roles_.atomists,
            alphas: roles_.alphas,
            whitelist: roles_.whitelist,
            guardians: roles_.guardians,
            fuseManagers: roles_.fuseManagers,
            claimRewards: roles_.claimRewards,
            transferRewardsManagers: roles_.transferRewardsManagers,
            configInstantWithdrawalFusesManagers: roles_.configInstantWithdrawalFusesManagers,
            updateMarketsBalancesAccounts: roles_.updateMarketsBalancesAccounts,
            updateRewardsBalanceAccounts: roles_.updateRewardsBalanceAccounts,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: address(plasmaVault_),
                accessManager: address(accessManager_),
                rewardsClaimManager: PlasmaVaultGovernance(address(plasmaVault_)).getRewardsClaimManagerAddress(),
                withdrawManager: withdrawManager_,
                feeManager: FeeAccount(PlasmaVaultGovernance(address(plasmaVault_)).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER(),
                contextManager: address(contextManager)
            })
        });

        // Generate and apply initialization data
        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);

        accessManager_.initialize(initializationData);
    }

    /// @notice Sets up initial roles with default addresses
    /// @param accessManager_ The access manager to initialize
    /// @param plasmaVault_ The plasma vault to set up roles for
    function setupInitRoles(
        IporFusionAccessManager accessManager_,
        PlasmaVault plasmaVault_,
        address withdrawManager_
    ) internal returns (ContextManager contextManager) {
        return setupInitRoles(accessManager_, plasmaVault_, createDefaultRoleAddresses(), withdrawManager_);
    }
}
