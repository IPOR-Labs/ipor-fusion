// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {FusionFactoryStorageLib} from "./FusionFactoryStorageLib.sol";
import {FusionFactoryLogicLib} from "./FusionFactoryLogicLib.sol";
import {IporFusionAccessManager} from "../../managers/access/IporFusionAccessManager.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress} from "../../vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {AccountToRole, InitializationData} from "../../managers/access/IporFusionAccessManagerInitializationLib.sol";
import {Roles} from "../../libraries/Roles.sol";

/// @title Fusion Factory Access Manager Initialization Library
/// @notice Handles building AccessManager initialization data and calling initialize()
library FusionFactoryAccessInitLib {
    /// @dev Builds initialization data and initializes the AccessManager
    /// @param fusionAddresses The fusion addresses struct
    /// @param owner_ The owner of the Fusion Vault
    /// @param withAdmin_ Whether to include admin role
    /// @param daoFeeRecipientAddress The DAO fee recipient address
    /// @param isLazyDeploy_ true = re-grant factory ADMIN_ROLE for lazy Phase 2 deployment
    function initializeAccessManager(
        FusionFactoryLogicLib.FusionInstance memory fusionAddresses,
        address owner_,
        bool withAdmin_,
        address daoFeeRecipientAddress,
        bool isLazyDeploy_
    ) public {
        DataForInitialization memory accessData;
        accessData.isPublic = false;
        accessData.iporDaos = new address[](1);
        accessData.iporDaos[0] = daoFeeRecipientAddress;

        if (withAdmin_) {
            accessData.admins = FusionFactoryStorageLib.getPlasmaVaultAdminArray();
        }

        accessData.owners = new address[](1);
        accessData.owners[0] = owner_;

        accessData.plasmaVaultAddress = PlasmaVaultAddress({
            plasmaVault: fusionAddresses.plasmaVault,
            accessManager: fusionAddresses.accessManager,
            rewardsClaimManager: fusionAddresses.rewardsManager,
            withdrawManager: fusionAddresses.withdrawManager,
            feeManager: fusionAddresses.feeManager,
            contextManager: fusionAddresses.contextManager,
            priceOracleMiddlewareManager: fusionAddresses.priceManager
        });

        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(accessData);

        if (isLazyDeploy_) {
            // Re-grant ADMIN_ROLE to factory after initialize() revokes it.
            // Factory needs ADMIN_ROLE to configure Phase 2 components during lazy deployment.
            uint256 originalLength = initData.accountToRoles.length;
            AccountToRole[] memory extendedRoles = new AccountToRole[](originalLength + 1);
            for (uint256 i; i < originalLength; ++i) {
                extendedRoles[i] = initData.accountToRoles[i];
            }
            extendedRoles[originalLength] = AccountToRole({
                roleId: Roles.ADMIN_ROLE,
                account: address(this),
                executionDelay: 0
            });
            initData.accountToRoles = extendedRoles;
        }

        IporFusionAccessManager(fusionAddresses.accessManager).initialize(initData);
    }
}
