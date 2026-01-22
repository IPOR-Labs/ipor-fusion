// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {RewardsManagerFactory} from "../RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "../WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "../ContextManagerFactory.sol";
import {PriceManagerFactory} from "../PriceManagerFactory.sol";
import {PlasmaVaultFactory} from "../PlasmaVaultFactory.sol";
import {AccessManagerFactory} from "../AccessManagerFactory.sol";
import {FusionFactoryStorageLib} from "./FusionFactoryStorageLib.sol";
import {FeeConfig} from "../../managers/fee/FeeManagerFactory.sol";
import {WithdrawManager} from "../../managers/withdraw/WithdrawManager.sol";
import {FeeManager} from "../../managers/fee/FeeManager.sol";
import {FeeAccount} from "../../managers/fee/FeeAccount.sol";
import {IporFusionAccessManager} from "../../managers/access/IporFusionAccessManager.sol";
import {PlasmaVaultInitData} from "../../vaults/PlasmaVault.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress} from "../../vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {IporFusionMarkets} from "../../libraries/IporFusionMarkets.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {IPlasmaVaultGovernance} from "../../interfaces/IPlasmaVaultGovernance.sol";
import {IRewardsClaimManager} from "../../interfaces/IRewardsClaimManager.sol";

/**
 * @title Fusion Factory Logic Library
 * @notice Library for managing Fusion Factory instance creation logic
 * @dev This library contains the core functionality for creating and cloning Fusion instances
 */
library FusionFactoryLogicLib {
    error InvalidBaseAddress();
    error InvalidDaoFeeRecipient();
    error DaoFeePackagesArrayEmpty();
    error DaoFeePackageIndexOutOfBounds(uint256 index, uint256 length);

    struct FusionInstance {
        uint256 index;
        uint256 version;
        string assetName;
        string assetSymbol;
        uint8 assetDecimals;
        address underlyingToken;
        string underlyingTokenSymbol;
        uint8 underlyingTokenDecimals;
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

    /// @notice Validates and retrieves a DAO fee package by index
    /// @param index_ Index of the DAO fee package
    /// @return DAO fee package at the specified index
    function _validateAndGetDaoFeePackage(
        uint256 index_
    ) internal view returns (FusionFactoryStorageLib.FeePackage memory) {
        uint256 length = FusionFactoryStorageLib.getDaoFeePackagesLength();
        if (length == 0) revert DaoFeePackagesArrayEmpty();
        if (index_ >= length) revert DaoFeePackageIndexOutOfBounds(index_, length);
        return FusionFactoryStorageLib.getDaoFeePackage(index_);
    }

    /// @notice Clones a Fusion instance
    /// @param fusionAddresses The fusion addresses struct to populate
    /// @param assetName_ The name of the asset
    /// @param assetSymbol_ The symbol of the asset
    /// @param underlyingToken_ The address of the underlying token
    /// @param redemptionDelayInSeconds_ The redemption delay in seconds
    /// @param owner_ The owner of the Fusion Vault
    /// @param withAdmin_ Whether to include admin role
    /// @param daoFeePackageIndex_ Index of the DAO fee package to use
    function doClone(
        FusionInstance memory fusionAddresses,
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        bool withAdmin_,
        uint256 daoFeePackageIndex_
    ) public returns (FusionInstance memory) {
        FusionFactoryStorageLib.FeePackage memory daoFeePackage = _validateAndGetDaoFeePackage(daoFeePackageIndex_);

        fusionAddresses = _cloneManagers(fusionAddresses, redemptionDelayInSeconds_);

        fusionAddresses = _clonePlasmaVaultAndRewards(
            fusionAddresses,
            daoFeePackage,
            assetName_,
            assetSymbol_,
            underlyingToken_
        );

        return setupFinalConfiguration(fusionAddresses, owner_, withAdmin_, daoFeePackage.feeRecipient, false);
    }

    function _cloneManagers(
        FusionInstance memory fusionAddresses,
        uint256 redemptionDelayInSeconds_
    ) private returns (FusionInstance memory) {
        FusionFactoryStorageLib.BaseAddresses memory baseAddresses = FusionFactoryStorageLib.getBaseAddresses();
        _validateBaseAddresses(baseAddresses);

        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = FusionFactoryStorageLib
            .getFactoryAddresses();

        fusionAddresses.accessManager = AccessManagerFactory(factoryAddresses.accessManagerFactory).clone(
            baseAddresses.accessManagerBase,
            fusionAddresses.index,
            address(this),
            redemptionDelayInSeconds_
        );

        fusionAddresses.priceManager = PriceManagerFactory(factoryAddresses.priceManagerFactory).clone(
            baseAddresses.priceManagerBase,
            fusionAddresses.index,
            fusionAddresses.accessManager,
            FusionFactoryStorageLib.getPriceOracleMiddleware()
        );

        fusionAddresses.withdrawManager = WithdrawManagerFactory(factoryAddresses.withdrawManagerFactory).clone(
            baseAddresses.withdrawManagerBase,
            fusionAddresses.index,
            fusionAddresses.accessManager
        );

        return fusionAddresses;
    }

    function _clonePlasmaVaultAndRewards(
        FusionInstance memory fusionAddresses,
        FusionFactoryStorageLib.FeePackage memory daoFeePackage_,
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_
    ) private returns (FusionInstance memory) {
        FusionFactoryStorageLib.BaseAddresses memory baseAddresses = FusionFactoryStorageLib.getBaseAddresses();
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = FusionFactoryStorageLib
            .getFactoryAddresses();

        fusionAddresses = _clonePlasmaVault(
            fusionAddresses,
            baseAddresses,
            factoryAddresses,
            daoFeePackage_,
            assetName_,
            assetSymbol_,
            underlyingToken_
        );

        fusionAddresses.assetDecimals = IERC20Metadata(fusionAddresses.plasmaVault).decimals();

        fusionAddresses.rewardsManager = RewardsManagerFactory(factoryAddresses.rewardsManagerFactory).clone(
            baseAddresses.rewardsManagerBase,
            fusionAddresses.index,
            fusionAddresses.accessManager,
            fusionAddresses.plasmaVault
        );

        return fusionAddresses;
    }

    function _validateBaseAddresses(FusionFactoryStorageLib.BaseAddresses memory baseAddresses) private pure {
        if (baseAddresses.plasmaVaultCoreBase == address(0)) revert InvalidBaseAddress();
        if (baseAddresses.accessManagerBase == address(0)) revert InvalidBaseAddress();
        if (baseAddresses.priceManagerBase == address(0)) revert InvalidBaseAddress();
        if (baseAddresses.withdrawManagerBase == address(0)) revert InvalidBaseAddress();
        if (baseAddresses.rewardsManagerBase == address(0)) revert InvalidBaseAddress();
        if (baseAddresses.contextManagerBase == address(0)) revert InvalidBaseAddress();
    }

    function _clonePlasmaVault(
        FusionInstance memory fusionAddresses,
        FusionFactoryStorageLib.BaseAddresses memory baseAddresses,
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses,
        FusionFactoryStorageLib.FeePackage memory daoFeePackage_,
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_
    ) private returns (FusionInstance memory) {
        PlasmaVaultInitData memory initData = PlasmaVaultInitData({
            assetName: assetName_,
            assetSymbol: assetSymbol_,
            underlyingToken: underlyingToken_,
            priceOracleMiddleware: fusionAddresses.priceManager,
            feeConfig: FeeConfig({
                feeFactory: factoryAddresses.feeManagerFactory,
                iporDaoManagementFee: daoFeePackage_.managementFee,
                iporDaoPerformanceFee: daoFeePackage_.performanceFee,
                iporDaoFeeRecipientAddress: daoFeePackage_.feeRecipient
            }),
            accessManager: fusionAddresses.accessManager,
            plasmaVaultBase: fusionAddresses.plasmaVaultBase,
            withdrawManager: fusionAddresses.withdrawManager
        });

        fusionAddresses.plasmaVault = PlasmaVaultFactory(factoryAddresses.plasmaVaultFactory).clone(
            baseAddresses.plasmaVaultCoreBase,
            fusionAddresses.index,
            initData
        );

        return fusionAddresses;
    }

    /// @notice Sets up the final configuration for a Fusion instance
    /// @param fusionAddresses The fusion addresses struct
    /// @param owner_ The owner of the Fusion Vault
    /// @param withAdmin_ Whether to include admin role
    /// @param daoFeeRecipientAddress The address of the DAO fee recipient
    /// @param isCreate_ Whether this is a creation or clone
    function setupFinalConfiguration(
        FusionInstance memory fusionAddresses,
        address owner_,
        bool withAdmin_,
        address daoFeeRecipientAddress,
        bool isCreate_
    ) public returns (FusionInstance memory) {
        PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData = IPlasmaVaultGovernance(
            fusionAddresses.plasmaVault
        ).getPerformanceFeeData();

        fusionAddresses.feeManager = FeeAccount(performanceFeeData.feeAccount).FEE_MANAGER();

        address[] memory approvedAddresses = new address[](5);
        approvedAddresses[0] = fusionAddresses.plasmaVault;
        approvedAddresses[1] = fusionAddresses.withdrawManager;
        approvedAddresses[2] = fusionAddresses.priceManager;
        approvedAddresses[3] = fusionAddresses.rewardsManager;
        approvedAddresses[4] = fusionAddresses.feeManager;

        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = FusionFactoryStorageLib
            .getFactoryAddresses();

        if (isCreate_) {
            fusionAddresses.contextManager = ContextManagerFactory(factoryAddresses.contextManagerFactory).create(
                fusionAddresses.index,
                fusionAddresses.accessManager,
                approvedAddresses
            );
        } else {
            FusionFactoryStorageLib.BaseAddresses memory baseAddresses = FusionFactoryStorageLib.getBaseAddresses();

            fusionAddresses.contextManager = ContextManagerFactory(factoryAddresses.contextManagerFactory).clone(
                baseAddresses.contextManagerBase,
                fusionAddresses.index,
                fusionAddresses.accessManager,
                approvedAddresses
            );
        }

        IRewardsClaimManager(fusionAddresses.rewardsManager).setupVestingTime(
            FusionFactoryStorageLib.getVestingPeriodInSeconds()
        );

        IPlasmaVaultGovernance(fusionAddresses.plasmaVault).setRewardsClaimManagerAddress(
            fusionAddresses.rewardsManager
        );

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

        IporFusionAccessManager(fusionAddresses.accessManager).initialize(
            IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(accessData)
        );

        return fusionAddresses;
    }
}
