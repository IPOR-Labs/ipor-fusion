// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {RewardsManagerFactory} from "../RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "../WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "../ContextManagerFactory.sol";
import {PriceManagerFactory} from "../PriceManagerFactory.sol";
import {PlasmaVaultFactory} from "../PlasmaVaultFactory.sol";
import {AccessManagerFactory} from "../AccessManagerFactory.sol";
import {FusionFactoryStorageLib} from "./FusionFactoryStorageLib.sol";
import {FusionFactoryCreate3Lib} from "./FusionFactoryCreate3Lib.sol";
import {FusionFactoryConfigLib} from "./FusionFactoryConfigLib.sol";
import {FeeConfig} from "../../managers/fee/FeeManagerFactory.sol";
import {FeeAccount} from "../../managers/fee/FeeAccount.sol";
import {PlasmaVaultInitData} from "../../vaults/PlasmaVault.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {IPlasmaVaultGovernance} from "../../interfaces/IPlasmaVaultGovernance.sol";

/**
 * @title Fusion Factory Logic Library
 * @notice Library for deploying Fusion instances deterministically using CREATE3
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
    function _validateAndGetDaoFeePackage(
        uint256 index_
    ) internal view returns (FusionFactoryStorageLib.FeePackage memory) {
        uint256 length = FusionFactoryStorageLib.getDaoFeePackagesLength();
        if (length == 0) revert DaoFeePackagesArrayEmpty();
        if (index_ >= length) revert DaoFeePackageIndexOutOfBounds(index_, length);
        return FusionFactoryStorageLib.getDaoFeePackage(index_);
    }

    function _validateBaseAddresses(FusionFactoryStorageLib.BaseAddresses memory baseAddresses) private pure {
        if (baseAddresses.plasmaVaultCoreBase == address(0)) revert InvalidBaseAddress();
        if (baseAddresses.accessManagerBase == address(0)) revert InvalidBaseAddress();
        if (baseAddresses.priceManagerBase == address(0)) revert InvalidBaseAddress();
        if (baseAddresses.withdrawManagerBase == address(0)) revert InvalidBaseAddress();
        if (baseAddresses.rewardsManagerBase == address(0)) revert InvalidBaseAddress();
        if (baseAddresses.contextManagerBase == address(0)) revert InvalidBaseAddress();
    }

    /// @notice Deploys a Fusion instance deterministically using CREATE3 (lazy Phase 2)
    function doCloneDeterministic(
        FusionInstance memory fusionAddresses,
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        bool withAdmin_,
        uint256 daoFeePackageIndex_,
        bytes32 masterSalt_
    ) public returns (FusionInstance memory) {
        FusionFactoryStorageLib.FeePackage memory daoFeePackage = _validateAndGetDaoFeePackage(daoFeePackageIndex_);

        fusionAddresses = _deployManagersDeterministic(fusionAddresses, masterSalt_, redemptionDelayInSeconds_);

        fusionAddresses = _deployPlasmaVaultDeterministic(
            fusionAddresses, daoFeePackage, masterSalt_, assetName_, assetSymbol_, underlyingToken_
        );

        FusionFactoryConfigLib.setupConfiguration(
            fusionAddresses, owner_, withAdmin_, daoFeePackage.feeRecipient, masterSalt_, true
        );

        return fusionAddresses;
    }

    /// @notice Deploys a full-stack Fusion instance deterministically using CREATE3
    function doCloneDeterministicFullStack(
        FusionInstance memory fusionAddresses,
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        bool withAdmin_,
        uint256 daoFeePackageIndex_,
        bytes32 masterSalt_
    ) public returns (FusionInstance memory) {
        FusionFactoryStorageLib.FeePackage memory daoFeePackage = _validateAndGetDaoFeePackage(daoFeePackageIndex_);

        fusionAddresses = _deployManagersDeterministic(fusionAddresses, masterSalt_, redemptionDelayInSeconds_);

        fusionAddresses = _deployPlasmaVaultAndPhase2Deterministic(
            fusionAddresses, daoFeePackage, masterSalt_, assetName_, assetSymbol_, underlyingToken_
        );

        FusionFactoryConfigLib.setupConfiguration(
            fusionAddresses, owner_, withAdmin_, daoFeePackage.feeRecipient, masterSalt_, false
        );

        return fusionAddresses;
    }

    function _deployManagersDeterministic(
        FusionInstance memory fusionAddresses,
        bytes32 masterSalt_,
        uint256 redemptionDelayInSeconds_
    ) private returns (FusionInstance memory) {
        FusionFactoryStorageLib.BaseAddresses memory baseAddresses = FusionFactoryStorageLib.getBaseAddresses();
        _validateBaseAddresses(baseAddresses);
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = FusionFactoryStorageLib.getFactoryAddresses();

        (, bytes32 accessSalt, bytes32 priceSalt, bytes32 withdrawSalt, , ) = FusionFactoryCreate3Lib
            .deriveAllComponentSalts(masterSalt_);

        fusionAddresses.accessManager = AccessManagerFactory(factoryAddresses.accessManagerFactory)
            .deployDeterministic(baseAddresses.accessManagerBase, accessSalt, address(this), redemptionDelayInSeconds_);

        fusionAddresses.priceManager = PriceManagerFactory(factoryAddresses.priceManagerFactory).deployDeterministic(
            baseAddresses.priceManagerBase, priceSalt, fusionAddresses.accessManager,
            FusionFactoryStorageLib.getPriceOracleMiddleware()
        );

        fusionAddresses.withdrawManager = WithdrawManagerFactory(factoryAddresses.withdrawManagerFactory)
            .deployDeterministic(baseAddresses.withdrawManagerBase, withdrawSalt, fusionAddresses.accessManager);

        return fusionAddresses;
    }

    function _deployPlasmaVaultDeterministic(
        FusionInstance memory fusionAddresses,
        FusionFactoryStorageLib.FeePackage memory daoFeePackage_,
        bytes32 masterSalt_,
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_
    ) private returns (FusionInstance memory) {
        FusionFactoryStorageLib.BaseAddresses memory baseAddresses = FusionFactoryStorageLib.getBaseAddresses();
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = FusionFactoryStorageLib.getFactoryAddresses();

        (bytes32 vaultSalt, , , , bytes32 rewardsSalt, bytes32 contextSalt) = FusionFactoryCreate3Lib
            .deriveAllComponentSalts(masterSalt_);

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
            withdrawManager: fusionAddresses.withdrawManager,
            plasmaVaultVotesPlugin: address(0)
        });

        fusionAddresses.plasmaVault = PlasmaVaultFactory(factoryAddresses.plasmaVaultFactory).deployDeterministic(
            baseAddresses.plasmaVaultCoreBase, vaultSalt, initData
        );

        fusionAddresses.assetDecimals = IERC20Metadata(fusionAddresses.plasmaVault).decimals();

        PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData = IPlasmaVaultGovernance(
            fusionAddresses.plasmaVault
        ).getPerformanceFeeData();
        fusionAddresses.feeManager = FeeAccount(performanceFeeData.feeAccount).FEE_MANAGER();

        // Phase 2: Pre-compute addresses (don't deploy yet)
        fusionAddresses.rewardsManager = FusionFactoryCreate3Lib.predictAddress(rewardsSalt, factoryAddresses.rewardsManagerFactory);
        fusionAddresses.contextManager = FusionFactoryCreate3Lib.predictAddress(contextSalt, factoryAddresses.contextManagerFactory);

        return fusionAddresses;
    }

    function _deployPlasmaVaultAndPhase2Deterministic(
        FusionInstance memory fusionAddresses,
        FusionFactoryStorageLib.FeePackage memory daoFeePackage_,
        bytes32 masterSalt_,
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_
    ) private returns (FusionInstance memory) {
        fusionAddresses = _deployPlasmaVaultDeterministic(
            fusionAddresses, daoFeePackage_, masterSalt_, assetName_, assetSymbol_, underlyingToken_
        );

        fusionAddresses.rewardsManager = _deployRewardsManagerDeterministic(fusionAddresses, masterSalt_);
        fusionAddresses.contextManager = _deployContextManagerDeterministic(fusionAddresses, masterSalt_);

        return fusionAddresses;
    }

    function _deployRewardsManagerDeterministic(
        FusionInstance memory fusionAddresses,
        bytes32 masterSalt_
    ) private returns (address) {
        bytes32 rewardsSalt = FusionFactoryCreate3Lib.deriveComponentSalt(masterSalt_, "rewards");
        return RewardsManagerFactory(FusionFactoryStorageLib.getFactoryAddresses().rewardsManagerFactory)
            .deployDeterministic(
                FusionFactoryStorageLib.getBaseAddresses().rewardsManagerBase,
                rewardsSalt,
                fusionAddresses.accessManager,
                fusionAddresses.plasmaVault
            );
    }

    function _deployContextManagerDeterministic(
        FusionInstance memory fusionAddresses,
        bytes32 masterSalt_
    ) private returns (address) {
        bytes32 contextSalt = FusionFactoryCreate3Lib.deriveComponentSalt(masterSalt_, "context");

        address[] memory approvedAddresses = new address[](5);
        approvedAddresses[0] = fusionAddresses.plasmaVault;
        approvedAddresses[1] = fusionAddresses.withdrawManager;
        approvedAddresses[2] = fusionAddresses.priceManager;
        approvedAddresses[3] = fusionAddresses.rewardsManager;
        approvedAddresses[4] = fusionAddresses.feeManager;

        return ContextManagerFactory(FusionFactoryStorageLib.getFactoryAddresses().contextManagerFactory)
            .deployDeterministic(
                FusionFactoryStorageLib.getBaseAddresses().contextManagerBase,
                contextSalt,
                fusionAddresses.accessManager,
                approvedAddresses
            );
    }
}
