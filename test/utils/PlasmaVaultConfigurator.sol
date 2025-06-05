// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {MarketBalanceFuseConfig, MarketSubstratesConfig} from "../../contracts/vaults/PlasmaVault.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {RecipientFee} from "../../contracts/managers/fee/FeeManager.sol";
import {PlasmaVaultStorageLib} from "../../contracts/libraries/PlasmaVaultStorageLib.sol";
<<<<<<< HEAD
import {FEE_MANAGER_ID} from "../../contracts/managers/ManagerIds.sol";
=======
>>>>>>> develop

library PlasmaVaultConfigurator {
    function setupPlasmaVault(
        Vm vm,
        address msgSender,
        address plasmaVault,
        address[] memory fuses,
        MarketBalanceFuseConfig[] memory balanceFuses,
<<<<<<< HEAD
        MarketSubstratesConfig[] memory marketConfigs,
        bool initializeFeeManager
=======
        MarketSubstratesConfig[] memory marketConfigs
>>>>>>> develop
    ) external {
        vm.startPrank(msgSender);
        IPlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);

        for (uint256 i = 0; i < balanceFuses.length; i++) {
            IPlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(balanceFuses[i].marketId, balanceFuses[i].fuse);
        }

        for (uint256 i = 0; i < marketConfigs.length; i++) {
            IPlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(
                marketConfigs[i].marketId,
                marketConfigs[i].substrates
            );
        }

<<<<<<< HEAD
        address feeManager = IPlasmaVaultGovernance(plasmaVault).getManager(FEE_MANAGER_ID);

        if (initializeFeeManager) {
            FeeManager(feeManager).initialize();
        }
=======
        PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData = IPlasmaVaultGovernance(plasmaVault)
            .getPerformanceFeeData();

        address feeManager = FeeAccount(performanceFeeData.feeAccount).FEE_MANAGER();

        FeeManager(feeManager).initialize();
>>>>>>> develop

        vm.stopPrank();
    }

    function setupRecipientFees(
        Vm vm,
        address msgSender,
        address plasmaVault,
        RecipientFee[] memory recipientManagementFees,
        RecipientFee[] memory recipientPerformanceFees
    ) external {
        vm.startPrank(msgSender);
<<<<<<< HEAD

        address feeManager = IPlasmaVaultGovernance(plasmaVault).getManager(FEE_MANAGER_ID);
=======
        PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData = IPlasmaVaultGovernance(plasmaVault)
            .getPerformanceFeeData();

        address feeManager = FeeAccount(performanceFeeData.feeAccount).FEE_MANAGER();
>>>>>>> develop

        FeeManager(feeManager).updateManagementFee(recipientManagementFees);
        FeeManager(feeManager).updatePerformanceFee(recipientPerformanceFees);
        vm.stopPrank();
    }
}
