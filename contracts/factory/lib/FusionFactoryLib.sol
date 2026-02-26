// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {FusionFactoryStorageLib} from "./FusionFactoryStorageLib.sol";
import {FusionFactoryLogicLib} from "./FusionFactoryLogicLib.sol";
import {FusionFactoryLazyDeployLib} from "./FusionFactoryLazyDeployLib.sol";
import {FusionFactoryCreate3Lib} from "./FusionFactoryCreate3Lib.sol";
import {VaultInstanceAddresses, Component} from "./FusionFactoryStorageLib.sol";

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

    /// @notice Thrown when the vault was not created by the factory
    error VaultNotCreatedByFactory();

    /// @notice Thrown when the component has already been deployed
    error ComponentAlreadyDeployed();

    /// @notice Thrown when the caller is not authorized to deploy the component
    error UnauthorizedComponentDeployer();

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

        bytes32 derivedMasterSalt = FusionFactoryCreate3Lib.deriveAutoMasterSalt(fusionAddresses.index);

        fusionAddresses = FusionFactoryLogicLib.doCloneDeterministicFullStack(
            fusionAddresses,
            assetName_,
            assetSymbol_,
            underlyingToken_,
            redemptionDelayInSeconds_,
            owner_,
            withAdmin_,
            daoFeePackageIndex_,
            derivedMasterSalt
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

    /// @notice Creates a new Fusion Vault with explicit salt for cross-chain deterministic deployment
    /// @dev Phase 1 components are deployed atomically, Phase 2 components are pre-computed for lazy deployment
    /// @param assetName_ The name of the asset
    /// @param assetSymbol_ The symbol of the asset
    /// @param underlyingToken_ The address of the underlying token
    /// @param redemptionDelayInSeconds_ The redemption delay in seconds
    /// @param owner_ The owner of the Fusion Vault
    /// @param withAdmin_ Whether to include admin role
    /// @param daoFeePackageIndex_ Index of the DAO fee package to use
    /// @param masterSalt_ User-provided master salt for cross-chain deterministic deployment
    /// @return fusionAddresses The Fusion Vault instance with Phase 1 deployed and Phase 2 pre-computed
    function cloneWithSalt(
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        bool withAdmin_,
        uint256 daoFeePackageIndex_,
        bytes32 masterSalt_
    ) public returns (FusionFactoryLogicLib.FusionInstance memory fusionAddresses) {
        if (underlyingToken_ == address(0)) revert InvalidUnderlyingToken();
        if (owner_ == address(0)) revert InvalidOwner();

        bytes32 derivedMasterSalt = FusionFactoryCreate3Lib.deriveExplicitMasterSalt(masterSalt_);

        fusionAddresses.version = FusionFactoryStorageLib.getFusionFactoryVersion();
        fusionAddresses.index = _increaseFusionFactoryIndex();
        fusionAddresses.assetName = assetName_;
        fusionAddresses.assetSymbol = assetSymbol_;
        fusionAddresses.underlyingToken = underlyingToken_;
        fusionAddresses.underlyingTokenSymbol = IERC20Metadata(underlyingToken_).symbol();
        fusionAddresses.underlyingTokenDecimals = IERC20Metadata(underlyingToken_).decimals();
        fusionAddresses.initialOwner = owner_;
        fusionAddresses.plasmaVaultBase = FusionFactoryStorageLib.getPlasmaVaultBaseAddress();

        fusionAddresses = FusionFactoryLogicLib.doCloneDeterministic(
            fusionAddresses,
            assetName_,
            assetSymbol_,
            underlyingToken_,
            redemptionDelayInSeconds_,
            owner_,
            withAdmin_,
            daoFeePackageIndex_,
            derivedMasterSalt
        );

        _emitEvent(fusionAddresses);
        return fusionAddresses;
    }

    /// @notice Deploys a Phase 2 component (RewardsManager or ContextManager) at its pre-computed address
    /// @param plasmaVault_ The address of the plasma vault
    /// @param component_ The component to deploy
    /// @return deployedAddress The address of the deployed component
    function deployComponent(
        address plasmaVault_,
        Component component_
    ) public returns (address deployedAddress) {
        return FusionFactoryLazyDeployLib.deployLazyComponent(plasmaVault_, component_);
    }

    /// @notice Predicts all component addresses for a given master salt
    /// @param masterSalt_ The master salt to predict addresses for
    /// @return vault Predicted PlasmaVault address
    /// @return accessManager Predicted AccessManager address
    /// @return priceManager Predicted PriceManager address
    /// @return withdrawManager Predicted WithdrawManager address
    /// @return rewardsManager Predicted RewardsManager address
    /// @return contextManager Predicted ContextManager address
    function predictAddresses(
        bytes32 masterSalt_
    )
        public
        view
        returns (
            address vault,
            address accessManager,
            address priceManager,
            address withdrawManager,
            address rewardsManager,
            address contextManager
        )
    {
        bytes32 derivedMasterSalt = FusionFactoryCreate3Lib.deriveExplicitMasterSalt(masterSalt_);
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = FusionFactoryStorageLib.getFactoryAddresses();
        return FusionFactoryCreate3Lib.predictAllAddresses(derivedMasterSalt, factoryAddresses);
    }

    /// @notice Predicts all component addresses for the next auto-deployment
    /// @return vault Predicted PlasmaVault address
    /// @return accessManager Predicted AccessManager address
    /// @return priceManager Predicted PriceManager address
    /// @return withdrawManager Predicted WithdrawManager address
    /// @return rewardsManager Predicted RewardsManager address
    /// @return contextManager Predicted ContextManager address
    function predictNextAddresses()
        public
        view
        returns (
            address vault,
            address accessManager,
            address priceManager,
            address withdrawManager,
            address rewardsManager,
            address contextManager
        )
    {
        uint256 nextIndex = FusionFactoryStorageLib.getFusionFactoryIndex() + 1;
        bytes32 masterSalt = FusionFactoryCreate3Lib.deriveAutoMasterSalt(nextIndex);
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = FusionFactoryStorageLib.getFactoryAddresses();
        return FusionFactoryCreate3Lib.predictAllAddresses(masterSalt, factoryAddresses);
    }
}
