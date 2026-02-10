// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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
    error InvalidUnderlyingToken();
    error InvalidOwner();
    error InvalidWithdrawWindow();

    /// @notice Thrown when DAO fee package index is out of bounds
    /// @param index Requested index
    /// @param length Array length
    error DaoFeePackageIndexOutOfBounds(uint256 index, uint256 length);

    /// @notice Thrown when DAO fee packages array is empty
    error DaoFeePackagesArrayEmpty();

    /// @notice Thrown when fee exceeds maximum allowed value
    /// @param fee The invalid fee value
    /// @param maxFee Maximum allowed fee
    error FeeExceedsMaximum(uint256 fee, uint256 maxFee);

    /// @notice Thrown when fee recipient is zero address
    error FeeRecipientZeroAddress();

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

    function clone(
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        bool withAdmin_,
        uint256 daoFeePackageIndex_
    ) public returns (FusionFactoryLogicLib.FusionInstance memory fusionAddresses) {
        _initializeCommonFields(fusionAddresses, assetName_, assetSymbol_, underlyingToken_, owner_);
        fusionAddresses = FusionFactoryLogicLib.doClone(
            fusionAddresses,
            assetName_,
            assetSymbol_,
            underlyingToken_,
            redemptionDelayInSeconds_,
            owner_,
            withAdmin_,
            daoFeePackageIndex_
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
