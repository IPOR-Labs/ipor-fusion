// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {RewardsManagerFactory} from "../RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "../WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "../ContextManagerFactory.sol";
import {PriceManagerFactory} from "../PriceManagerFactory.sol";
import {PlasmaVaultFactory} from "../PlasmaVaultFactory.sol";
import {AccessManagerFactory} from "../AccessManagerFactory.sol";
import {FusionFactoryStorageLib} from "./FusionFactoryStorageLib.sol";
import {PlasmaVaultInitData} from "../../vaults/PlasmaVault.sol";
import {FeeConfig} from "../../managers/fee/FeeManagerFactory.sol";
import {IporFusionMarkets} from "../../libraries/IporFusionMarkets.sol";
import {DataForInitialization} from "../../vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {IporFusionAccessManagerInitializerLibV1} from "../../vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {IPlasmaVaultGovernance} from "../../interfaces/IPlasmaVaultGovernance.sol";
import {IRewardsClaimManager} from "../../interfaces/IRewardsClaimManager.sol";
import {WithdrawManager} from "../../managers/withdraw/WithdrawManager.sol";
import {FeeManager} from "../../managers/fee/FeeManager.sol";
import {IporFusionAccessManager} from "../../managers/access/IporFusionAccessManager.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {FeeAccount} from "../../managers/fee/FeeAccount.sol";

/**
 * @title Fusion Factory Library
 * @notice Library for managing Fusion Factory initialization and instance creation
 * @dev This library contains the core functionality for initializing and creating Fusion instances
 */
library FusionFactoryLib {
    error InvalidFactoryAddress();
    error InvalidFeeValue();
    error InvalidAddress();
    error BurnRequestFeeFuseNotSet();
    error BalanceFuseBurnRequestFeeNotSet();
    error InvalidAssetName();
    error InvalidAssetSymbol();
    error InvalidUnderlyingToken();
    error InvalidOwner();
    error InvalidRedemptionDelay();
    error InvalidWithdrawWindow();
    error InvalidIporDaoFeeRecipient();

    struct FusionInstance {
        string assetName;
        string assetSymbol;
        address underlyingToken;
        address initialOwner;
        address plasmaVault;
        address plasmaVaultBase;
        address accessManager;
        address feeManager;
        address rewardsManager;
        address withdrawManager;
        address contextManager;
        address priceManager;
    }

    struct FactoryAddresses {
        address accessManagerFactory;
        address plasmaVaultFactory;
        address feeManagerFactory;
        address withdrawManagerFactory;
        address rewardsManagerFactory;
        address contextManagerFactory;
        address priceManagerFactory;
    }

    function initialize(
        FactoryAddresses memory factoryAddresses_,
        address plasmaVaultBase_,
        address priceOracleMiddleware_,
        address burnRequestFeeFuse_,
        address burnRequestFeeBalanceFuse_
    ) internal {
        if (factoryAddresses_.accessManagerFactory == address(0)) revert InvalidFactoryAddress();
        if (factoryAddresses_.plasmaVaultFactory == address(0)) revert InvalidFactoryAddress();
        if (factoryAddresses_.feeManagerFactory == address(0)) revert InvalidFactoryAddress();
        if (factoryAddresses_.withdrawManagerFactory == address(0)) revert InvalidFactoryAddress();
        if (factoryAddresses_.rewardsManagerFactory == address(0)) revert InvalidFactoryAddress();
        if (factoryAddresses_.contextManagerFactory == address(0)) revert InvalidFactoryAddress();
        if (factoryAddresses_.priceManagerFactory == address(0)) revert InvalidFactoryAddress();

        if (plasmaVaultBase_ == address(0)) revert InvalidAddress();
        if (priceOracleMiddleware_ == address(0)) revert InvalidAddress();
        if (burnRequestFeeFuse_ == address(0)) revert InvalidAddress();
        if (burnRequestFeeBalanceFuse_ == address(0)) revert InvalidAddress();

        /// @dev default redemption delay is 1 seconds
        FusionFactoryStorageLib.getRedemptionDelayInSecondsSlot().value = 1 seconds;
        /// @dev default vesting period is 1 weeks
        FusionFactoryStorageLib.getVestingPeriodInSecondsSlot().value = 1 weeks;
        /// @dev default withdraw window is 24 hours
        FusionFactoryStorageLib.getWithdrawWindowInSecondsSlot().value = 24 hours;

        FusionFactoryStorageLib.getPlasmaVaultFactoryAddressSlot().value = factoryAddresses_.plasmaVaultFactory;
        FusionFactoryStorageLib.getAccessManagerFactoryAddressSlot().value = factoryAddresses_.accessManagerFactory;
        FusionFactoryStorageLib.getFeeManagerFactoryAddressSlot().value = factoryAddresses_.feeManagerFactory;
        FusionFactoryStorageLib.getWithdrawManagerFactoryAddressSlot().value = factoryAddresses_.withdrawManagerFactory;
        FusionFactoryStorageLib.getRewardsManagerFactoryAddressSlot().value = factoryAddresses_.rewardsManagerFactory;
        FusionFactoryStorageLib.getContextManagerFactoryAddressSlot().value = factoryAddresses_.contextManagerFactory;
        FusionFactoryStorageLib.getPriceManagerFactoryAddressSlot().value = factoryAddresses_.priceManagerFactory;

        FusionFactoryStorageLib.getPlasmaVaultBaseAddressSlot().value = plasmaVaultBase_;
        FusionFactoryStorageLib.getPriceOracleMiddlewareSlot().value = priceOracleMiddleware_;

        FusionFactoryStorageLib.getBurnRequestFeeFuseAddressSlot().value = burnRequestFeeFuse_;
        FusionFactoryStorageLib.getBurnRequestFeeBalanceFuseAddressSlot().value = burnRequestFeeBalanceFuse_;
    }

    function create(
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        address owner_
    ) public returns (FusionInstance memory fusionAddresses) {
        if (underlyingToken_ == address(0)) revert InvalidUnderlyingToken();
        if (owner_ == address(0)) revert InvalidOwner();

        fusionAddresses.assetName = assetName_;
        fusionAddresses.assetSymbol = assetSymbol_;
        fusionAddresses.underlyingToken = underlyingToken_;
        fusionAddresses.initialOwner = owner_;

        fusionAddresses.plasmaVaultBase = getPlasmaVaultBaseAddress();

        fusionAddresses.accessManager = AccessManagerFactory(
            FusionFactoryStorageLib.getAccessManagerFactoryAddressSlot().value
        ).create(address(this), getRedemptionDelayInSeconds());

        fusionAddresses.withdrawManager = WithdrawManagerFactory(
            FusionFactoryStorageLib.getWithdrawManagerFactoryAddressSlot().value
        ).create(fusionAddresses.accessManager);

        fusionAddresses.priceManager = PriceManagerFactory(
            FusionFactoryStorageLib.getPriceManagerFactoryAddressSlot().value
        ).create(fusionAddresses.accessManager, getPriceOracleMiddleware());

        address iporDaoFeeRecipientAddress = getIporDaoFeeRecipientAddress();

        if (iporDaoFeeRecipientAddress == address(0)) {
            revert InvalidAddress();
        }

        fusionAddresses.plasmaVault = PlasmaVaultFactory(
            FusionFactoryStorageLib.getPlasmaVaultFactoryAddressSlot().value
        ).create(
                PlasmaVaultInitData({
                    assetName: assetName_,
                    assetSymbol: assetSymbol_,
                    underlyingToken: underlyingToken_,
                    priceOracleMiddleware: getPriceOracleMiddleware(),
                    feeConfig: FeeConfig({
                        feeFactory: FusionFactoryStorageLib.getFeeManagerFactoryAddressSlot().value,
                        iporDaoManagementFee: getIporDaoManagementFee(),
                        iporDaoPerformanceFee: getIporDaoPerformanceFee(),
                        iporDaoFeeRecipientAddress: iporDaoFeeRecipientAddress
                    }),
                    accessManager: fusionAddresses.accessManager,
                    plasmaVaultBase: fusionAddresses.plasmaVaultBase,
                    withdrawManager: fusionAddresses.withdrawManager
                })
            );

        fusionAddresses.rewardsManager = RewardsManagerFactory(
            FusionFactoryStorageLib.getRewardsManagerFactoryAddressSlot().value
        ).create(fusionAddresses.accessManager, fusionAddresses.plasmaVault);

        address[] memory approvedAddresses = new address[](1);
        approvedAddresses[0] = fusionAddresses.plasmaVault;

        fusionAddresses.contextManager = ContextManagerFactory(
            FusionFactoryStorageLib.getContextManagerFactoryAddressSlot().value
        ).create(fusionAddresses.accessManager, approvedAddresses);

        PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData = IPlasmaVaultGovernance(
            fusionAddresses.plasmaVault
        ).getPerformanceFeeData();

        fusionAddresses.feeManager = FeeAccount(performanceFeeData.feeAccount).FEE_MANAGER();

        IRewardsClaimManager(fusionAddresses.rewardsManager).setupVestingTime(
            getVestingPeriodInSeconds()
        );

        IPlasmaVaultGovernance(fusionAddresses.plasmaVault).setRewardsClaimManagerAddress(
            fusionAddresses.rewardsManager
        );

        WithdrawManager(fusionAddresses.withdrawManager).updateWithdrawWindow(
            getWithdrawWindowInSeconds()
        );
        WithdrawManager(fusionAddresses.withdrawManager).updatePlasmaVaultAddress(fusionAddresses.plasmaVault);

        address[] memory fuses = new address[](1);
        fuses[0] = getBurnRequestFeeFuseAddress();
        IPlasmaVaultGovernance(fusionAddresses.plasmaVault).addFuses(fuses);

        IPlasmaVaultGovernance(fusionAddresses.plasmaVault).addBalanceFuse(
            IporFusionMarkets.ZERO_BALANCE_MARKET,
            getBurnRequestFeeBalanceFuseAddress()
        );

        FeeManager(fusionAddresses.feeManager).initialize();

        DataForInitialization memory accessData;
        accessData.isPublic = false;
        accessData.owners = new address[](1);
        accessData.owners[0] = owner_;

        IporFusionAccessManager(fusionAddresses.accessManager).initialize(
            IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(accessData)
        );

        return fusionAddresses;
    }

    function getFactoryAddresses() internal view returns (FactoryAddresses memory) {
        return
            FactoryAddresses({
                accessManagerFactory: FusionFactoryStorageLib.getAccessManagerFactoryAddressSlot().value,
                plasmaVaultFactory: FusionFactoryStorageLib.getPlasmaVaultFactoryAddressSlot().value,
                feeManagerFactory: FusionFactoryStorageLib.getFeeManagerFactoryAddressSlot().value,
                withdrawManagerFactory: FusionFactoryStorageLib.getWithdrawManagerFactoryAddressSlot().value,
                rewardsManagerFactory: FusionFactoryStorageLib.getRewardsManagerFactoryAddressSlot().value,
                contextManagerFactory: FusionFactoryStorageLib.getContextManagerFactoryAddressSlot().value,
                priceManagerFactory: FusionFactoryStorageLib.getPriceManagerFactoryAddressSlot().value
            });
    }

    function getPlasmaVaultBaseAddress() internal view returns (address) {
        return FusionFactoryStorageLib.getPlasmaVaultBaseAddressSlot().value;
    }

    function getPriceOracleMiddleware() internal view returns (address) {
        return FusionFactoryStorageLib.getPriceOracleMiddlewareSlot().value;
    }

    function getBurnRequestFeeBalanceFuseAddress() internal view returns (address) {
        return FusionFactoryStorageLib.getBurnRequestFeeBalanceFuseAddressSlot().value;
    }

    function getBurnRequestFeeFuseAddress() internal view returns (address) {
        return FusionFactoryStorageLib.getBurnRequestFeeFuseAddressSlot().value;
    }

    function getIporDaoFeeRecipientAddress() internal view returns (address) {
        return FusionFactoryStorageLib.getIporDaoFeeRecipientAddressSlot().value;
    }

    function getIporDaoManagementFee() internal view returns (uint256) {
        return FusionFactoryStorageLib.getIporDaoManagementFeeSlot().value;
    }

    function getIporDaoPerformanceFee() internal view returns (uint256) {
        return FusionFactoryStorageLib.getIporDaoPerformanceFeeSlot().value;
    }

    function getRedemptionDelayInSeconds() internal view returns (uint256) {
        return FusionFactoryStorageLib.getRedemptionDelayInSecondsSlot().value;
    }

    function getWithdrawWindowInSeconds() internal view returns (uint256) {
        return FusionFactoryStorageLib.getWithdrawWindowInSecondsSlot().value;
    }

    function getVestingPeriodInSeconds() internal view returns (uint256) {
        return FusionFactoryStorageLib.getVestingPeriodInSecondsSlot().value;
    }
}
