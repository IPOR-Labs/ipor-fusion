// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {AccessManagerFactory} from "../AccessManagerFactory.sol";
import {PlasmaVaultFactory} from "../PlasmaVaultFactory.sol";
import {PriceManagerFactory} from "../PriceManagerFactory.sol";
import {RewardsManagerFactory} from "../RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "../WithdrawManagerFactory.sol";
import {FeeConfig} from "../../managers/fee/FeeManagerFactory.sol";
import {PlasmaVaultInitData} from "../../vaults/PlasmaVault.sol";
import {FusionFactoryStorageLib} from "./FusionFactoryStorageLib.sol";
import {FusionFactoryLogicLib} from "./FusionFactoryLogicLib.sol";

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
    error InvalidAddress();
    error InvalidFeeValue();
    error InvalidUnderlyingToken();
    error InvalidOwner();
    error InvalidWithdrawWindow();
    error InvalidIporDaoFeeRecipient();

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
    ) public returns (FusionFactoryLogicLib.FusionInstance memory fusionAddresses) {
        _initializeCommonFields(fusionAddresses, assetName_, assetSymbol_, underlyingToken_, owner_);
        fusionAddresses = _create(
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
    ) public returns (FusionFactoryLogicLib.FusionInstance memory fusionAddresses) {
        _initializeCommonFields(fusionAddresses, assetName_, assetSymbol_, underlyingToken_, owner_);
        fusionAddresses = FusionFactoryLogicLib.doClone(
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
        FusionFactoryLogicLib.FusionInstance memory fusionAddresses,
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
        FusionFactoryLogicLib.FusionInstance memory fusionAddresses,
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        bool withAdmin_
    ) internal returns (FusionFactoryLogicLib.FusionInstance memory) {
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
            revert InvalidIporDaoFeeRecipient();
        }

        fusionAddresses.plasmaVault = PlasmaVaultFactory(factoryAddresses.plasmaVaultFactory).clone(
            FusionFactoryStorageLib.getPlasmaVaultCoreBaseAddress(),
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
                plasmaVaultERC4626: address(0),
                withdrawManager: fusionAddresses.withdrawManager
            })
        );

        fusionAddresses.assetDecimals = IERC20Metadata(fusionAddresses.plasmaVault).decimals();

        fusionAddresses.rewardsManager = RewardsManagerFactory(factoryAddresses.rewardsManagerFactory).create(
            fusionAddresses.index,
            fusionAddresses.accessManager,
            fusionAddresses.plasmaVault
        );

        return
            FusionFactoryLogicLib.setupFinalConfiguration(
                fusionAddresses,
                owner_,
                withAdmin_,
                daoFeeRecipientAddress,
                true
            );
    }

    function _increaseFusionFactoryIndex() internal returns (uint256) {
        uint256 fusionFactoryIndex = FusionFactoryStorageLib.getFusionFactoryIndex();
        fusionFactoryIndex++;
        FusionFactoryStorageLib.setFusionFactoryIndex(fusionFactoryIndex);
        return fusionFactoryIndex;
    }

    function _emitEvent(FusionFactoryLogicLib.FusionInstance memory fusionAddresses) internal {
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
