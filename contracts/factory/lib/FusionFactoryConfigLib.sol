// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {FusionFactoryStorageLib} from "./FusionFactoryStorageLib.sol";
import {VaultInstanceAddresses} from "./FusionFactoryStorageLib.sol";
import {FusionFactoryLogicLib} from "./FusionFactoryLogicLib.sol";
import {FusionFactoryAccessInitLib} from "./FusionFactoryAccessInitLib.sol";
import {WithdrawManager} from "../../managers/withdraw/WithdrawManager.sol";
import {FeeManager} from "../../managers/fee/FeeManager.sol";
import {IporFusionMarkets} from "../../libraries/IporFusionMarkets.sol";
import {IPlasmaVaultGovernance} from "../../interfaces/IPlasmaVaultGovernance.sol";
import {IRewardsClaimManager} from "../../interfaces/IRewardsClaimManager.sol";

/// @title Fusion Factory Configuration Library
/// @notice Handles post-deployment configuration: components setup, AccessManager init, vault storage
library FusionFactoryConfigLib {
    /// @dev Unified configuration for both full-stack and lazy deployment modes
    /// @param isLazyDeploy_ true = Phase 2 not yet deployed (factory keeps ADMIN_ROLE for later lazy deploy)
    function setupConfiguration(
        FusionFactoryLogicLib.FusionInstance memory fusionAddresses,
        address owner_,
        bool withAdmin_,
        address daoFeeRecipientAddress,
        bytes32 masterSalt_,
        bool isLazyDeploy_
    ) public {
        // Full-stack: configure RewardsManager immediately (already deployed)
        if (!isLazyDeploy_) {
            IRewardsClaimManager(fusionAddresses.rewardsManager).setupVestingTime(
                FusionFactoryStorageLib.getVestingPeriodInSeconds()
            );
            IPlasmaVaultGovernance(fusionAddresses.plasmaVault).setRewardsClaimManagerAddress(
                fusionAddresses.rewardsManager
            );
        }

        WithdrawManager(fusionAddresses.withdrawManager).updateWithdrawWindow(
            FusionFactoryStorageLib.getWithdrawWindowInSeconds()
        );
        WithdrawManager(fusionAddresses.withdrawManager).updatePlasmaVaultAddress(fusionAddresses.plasmaVault);

        address[] memory fuses = new address[](1);
        fuses[0] = FusionFactoryStorageLib.getBurnRequestFeeFuseAddress();
        IPlasmaVaultGovernance(fusionAddresses.plasmaVault).addFuses(fuses);

        IPlasmaVaultGovernance(fusionAddresses.plasmaVault).addBalanceFuse(
            IporFusionMarkets.ZERO_BALANCE_MARKET,
            FusionFactoryStorageLib.getBurnRequestFeeBalanceFuseAddress()
        );

        FeeManager(fusionAddresses.feeManager).initialize();

        FusionFactoryAccessInitLib.initializeAccessManager(
            fusionAddresses, owner_, withAdmin_, daoFeeRecipientAddress, isLazyDeploy_
        );

        FusionFactoryStorageLib.setVaultInstanceAddresses(
            fusionAddresses.plasmaVault,
            VaultInstanceAddresses({
                masterSalt: masterSalt_,
                plasmaVault: fusionAddresses.plasmaVault,
                accessManager: fusionAddresses.accessManager,
                priceManager: fusionAddresses.priceManager,
                withdrawManager: fusionAddresses.withdrawManager,
                feeManager: fusionAddresses.feeManager,
                rewardsManager: fusionAddresses.rewardsManager,
                contextManager: fusionAddresses.contextManager,
                rewardsManagerDeployed: !isLazyDeploy_,
                contextManagerDeployed: !isLazyDeploy_,
                owner: owner_,
                withAdmin: withAdmin_,
                daoFeeRecipientAddress: daoFeeRecipientAddress
            })
        );

        FusionFactoryStorageLib.setVaultByIndex(fusionAddresses.index, fusionAddresses.plasmaVault);
    }
}
