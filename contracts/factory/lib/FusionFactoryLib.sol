// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {RewardsManagerFactory} from "../RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "../WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "../ContextManagerFactory.sol";
import {PriceManagerFactory} from "../PriceManagerFactory.sol";
import {PlasmaVaultFactory} from "../PlasmaVaultFactory.sol";
import {ClonePlasmaVaultFactory} from "../ClonePlasmaVaultFactory.sol";
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
import {PlasmaVaultAddress} from "../../vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";

/**
 * @title Fusion Factory Library
 * @notice Library for managing Fusion Factory initialization and instance creation
 * @dev This library contains the core functionality for initializing and creating Fusion instances
 */
library FusionFactoryLib {
    event FusionInstanceCreated(
        uint256 index,
        uint256 version,
        string assetName,
        string assetSymbol,
        uint8 assetDecimals,
        address underlyingToken,
        string underlyingTokenSymbol,
        uint8 underlyingTokenDecimals,
        address initialOwner,
        address plasmaVault,
        address plasmaVaultBase,
        address feeManager
    );

    error InvalidFactoryAddress();
    error InvalidFeeValue();
    error InvalidAddress();
    error InvalidBaseAddress();
    error InvalidDaoFeeRecipient();
    error BurnRequestFeeFuseNotSet();
    error BalanceFuseBurnRequestFeeNotSet();
    error InvalidAssetName();
    error InvalidAssetSymbol();
    error InvalidUnderlyingToken();
    error InvalidOwner();
    error InvalidPlasmaVaultAdmin();
    error InvalidWithdrawWindow();
    error InvalidIporDaoFeeRecipient();

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

    function initialize(
        address[] memory initialPlasmaVaultAdminArray_,
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses_,
        address plasmaVaultBase_,
        address priceOracleMiddleware_,
        address burnRequestFeeFuse_,
        address burnRequestFeeBalanceFuse_
    ) internal {
        if (initialPlasmaVaultAdminArray_.length > 0) {
            for (uint256 i = 0; i < initialPlasmaVaultAdminArray_.length; i++) {
                if (initialPlasmaVaultAdminArray_[i] == address(0)) revert InvalidAddress();
            }
            FusionFactoryStorageLib.setPlasmaVaultAdminArray(initialPlasmaVaultAdminArray_);
        }

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

        /// @dev default vesting period is 1 weeks
        FusionFactoryStorageLib.setVestingPeriodInSeconds(1 weeks);
        /// @dev default withdraw window is 24 hours
        FusionFactoryStorageLib.setWithdrawWindowInSeconds(24 hours);

        FusionFactoryStorageLib.setPlasmaVaultFactoryAddress(factoryAddresses_.plasmaVaultFactory);
        FusionFactoryStorageLib.setAccessManagerFactoryAddress(factoryAddresses_.accessManagerFactory);
        FusionFactoryStorageLib.setFeeManagerFactoryAddress(factoryAddresses_.feeManagerFactory);
        FusionFactoryStorageLib.setWithdrawManagerFactoryAddress(factoryAddresses_.withdrawManagerFactory);
        FusionFactoryStorageLib.setRewardsManagerFactoryAddress(factoryAddresses_.rewardsManagerFactory);
        FusionFactoryStorageLib.setContextManagerFactoryAddress(factoryAddresses_.contextManagerFactory);
        FusionFactoryStorageLib.setPriceManagerFactoryAddress(factoryAddresses_.priceManagerFactory);

        FusionFactoryStorageLib.setPlasmaVaultBaseAddress(plasmaVaultBase_);
        FusionFactoryStorageLib.setPriceOracleMiddlewareAddress(priceOracleMiddleware_);

        FusionFactoryStorageLib.setBurnRequestFeeFuseAddress(burnRequestFeeFuse_);
        FusionFactoryStorageLib.setBurnRequestFeeBalanceFuseAddress(burnRequestFeeBalanceFuse_);
    }

    function create(
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        bool withAdmin_
    ) public returns (FusionInstance memory fusionAddresses) {
        _initializeCommonFields(fusionAddresses, assetName_, assetSymbol_, underlyingToken_, owner_);
        _create(
            fusionAddresses,
            assetName_,
            assetSymbol_,
            underlyingToken_,
            redemptionDelayInSeconds_,
            owner_,
            withAdmin_
        );
        _emitEvent(fusionAddresses);
        return fusionAddresses;
    }

    function clone(
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        bool withAdmin_
    ) public returns (FusionInstance memory fusionAddresses) {
        _initializeCommonFields(fusionAddresses, assetName_, assetSymbol_, underlyingToken_, owner_);
        _clone(
            fusionAddresses,
            assetName_,
            assetSymbol_,
            underlyingToken_,
            redemptionDelayInSeconds_,
            owner_,
            withAdmin_
        );
        _emitEvent(fusionAddresses);
        return fusionAddresses;
    }

    function _initializeCommonFields(
        FusionInstance memory fusionAddresses,
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        address owner_
    ) internal {
        if (underlyingToken_ == address(0)) revert InvalidUnderlyingToken();
        if (owner_ == address(0)) revert InvalidOwner();

        fusionAddresses.version = FusionFactoryStorageLib.getFusionFactoryVersion();
        fusionAddresses.index = _increaseFusionFactoryIndex();
        fusionAddresses.assetName = assetName_;
        fusionAddresses.assetSymbol = assetSymbol_;
        fusionAddresses.underlyingToken = underlyingToken_;
        fusionAddresses.underlyingTokenSymbol = IERC20Metadata(underlyingToken_).symbol();
        fusionAddresses.underlyingTokenDecimals = IERC20Metadata(underlyingToken_).decimals();
        fusionAddresses.initialOwner = owner_;
        fusionAddresses.plasmaVaultBase = FusionFactoryStorageLib.getPlasmaVaultBaseAddress();
    }

    function _create(
        FusionInstance memory fusionAddresses,
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        bool withAdmin_
    ) internal {
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = FusionFactoryStorageLib
            .getFactoryAddresses();

        fusionAddresses.accessManager = AccessManagerFactory(factoryAddresses.accessManagerFactory).create(
            fusionAddresses.index,
            address(this),
            redemptionDelayInSeconds_
        );

        fusionAddresses.withdrawManager = WithdrawManagerFactory(factoryAddresses.withdrawManagerFactory).create(
            fusionAddresses.index,
            fusionAddresses.accessManager
        );

        fusionAddresses.priceManager = PriceManagerFactory(factoryAddresses.priceManagerFactory).create(
            fusionAddresses.index,
            fusionAddresses.accessManager,
            FusionFactoryStorageLib.getPriceOracleMiddleware()
        );

        address daoFeeRecipientAddress = FusionFactoryStorageLib.getDaoFeeRecipientAddress();
        if (daoFeeRecipientAddress == address(0)) {
            revert InvalidDaoFeeRecipient();
        }

        fusionAddresses.plasmaVault = PlasmaVaultFactory(factoryAddresses.plasmaVaultFactory).create(
            fusionAddresses.index,
            PlasmaVaultInitData({
                assetName: assetName_,
                assetSymbol: assetSymbol_,
                underlyingToken: underlyingToken_,
                priceOracleMiddleware: fusionAddresses.priceManager,
                feeConfig: FeeConfig({
                    feeFactory: factoryAddresses.feeManagerFactory,
                    iporDaoManagementFee: FusionFactoryStorageLib.getDaoManagementFee(),
                    iporDaoPerformanceFee: FusionFactoryStorageLib.getDaoPerformanceFee(),
                    iporDaoFeeRecipientAddress: daoFeeRecipientAddress
                }),
                accessManager: fusionAddresses.accessManager,
                plasmaVaultBase: fusionAddresses.plasmaVaultBase,
                withdrawManager: fusionAddresses.withdrawManager
            })
        );

        fusionAddresses.assetDecimals = IERC20Metadata(fusionAddresses.plasmaVault).decimals();

        fusionAddresses.rewardsManager = RewardsManagerFactory(factoryAddresses.rewardsManagerFactory).create(
            fusionAddresses.index,
            fusionAddresses.accessManager,
            fusionAddresses.plasmaVault
        );

        _setupFinalConfiguration(fusionAddresses, owner_, withAdmin_, daoFeeRecipientAddress, true);
    }

    function _clone(
        FusionInstance memory fusionAddresses,
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        bool withAdmin_
    ) internal {
        FusionFactoryStorageLib.BaseAddresses memory baseAddresses = FusionFactoryStorageLib.getBaseAddresses();

        if (baseAddresses.plasmaVaultCoreBase == address(0)) revert InvalidBaseAddress();
        if (baseAddresses.accessManagerBase == address(0)) revert InvalidBaseAddress();
        if (baseAddresses.priceManagerBase == address(0)) revert InvalidBaseAddress();
        if (baseAddresses.withdrawManagerBase == address(0)) revert InvalidBaseAddress();
        if (baseAddresses.rewardsManagerBase == address(0)) revert InvalidBaseAddress();
        if (baseAddresses.contextManagerBase == address(0)) revert InvalidBaseAddress();

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

        address daoFeeRecipientAddress = FusionFactoryStorageLib.getDaoFeeRecipientAddress();
        if (daoFeeRecipientAddress == address(0)) {
            revert InvalidDaoFeeRecipient();
        }

        fusionAddresses.plasmaVault = ClonePlasmaVaultFactory(factoryAddresses.plasmaVaultFactory).clone(
            baseAddresses.plasmaVaultCoreBase,
            fusionAddresses.index,
            PlasmaVaultInitData({
                assetName: assetName_,
                assetSymbol: assetSymbol_,
                underlyingToken: underlyingToken_,
                priceOracleMiddleware: fusionAddresses.priceManager,
                feeConfig: FeeConfig({
                    feeFactory: factoryAddresses.feeManagerFactory,
                    iporDaoManagementFee: FusionFactoryStorageLib.getDaoManagementFee(),
                    iporDaoPerformanceFee: FusionFactoryStorageLib.getDaoPerformanceFee(),
                    iporDaoFeeRecipientAddress: daoFeeRecipientAddress
                }),
                accessManager: fusionAddresses.accessManager,
                plasmaVaultBase: fusionAddresses.plasmaVaultBase,
                withdrawManager: fusionAddresses.withdrawManager
            })
        );

        fusionAddresses.assetDecimals = IERC20Metadata(fusionAddresses.plasmaVault).decimals();

        fusionAddresses.rewardsManager = RewardsManagerFactory(factoryAddresses.rewardsManagerFactory).clone(
            baseAddresses.rewardsManagerBase,
            fusionAddresses.index,
            fusionAddresses.accessManager,
            fusionAddresses.plasmaVault
        );

        _setupFinalConfiguration(fusionAddresses, owner_, withAdmin_, daoFeeRecipientAddress, false);
    }

    function _setupFinalConfiguration(
        FusionInstance memory fusionAddresses,
        address owner_,
        bool withAdmin_,
        address daoFeeRecipientAddress,
        bool isCreate_
    ) internal {
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
    }

    function _increaseFusionFactoryIndex() internal returns (uint256) {
        uint256 fusionFactoryIndex = FusionFactoryStorageLib.getFusionFactoryIndex();
        fusionFactoryIndex++;
        FusionFactoryStorageLib.setFusionFactoryIndex(fusionFactoryIndex);
        return fusionFactoryIndex;
    }

    function _emitEvent(FusionInstance memory fusionAddresses) internal {
        emit FusionInstanceCreated(
            fusionAddresses.index,
            fusionAddresses.version,
            fusionAddresses.assetName,
            fusionAddresses.assetSymbol,
            fusionAddresses.assetDecimals,
            fusionAddresses.underlyingToken,
            fusionAddresses.underlyingTokenSymbol,
            fusionAddresses.underlyingTokenDecimals,
            fusionAddresses.initialOwner,
            fusionAddresses.plasmaVault,
            fusionAddresses.plasmaVaultBase,
            fusionAddresses.feeManager
        );
    }
}
