// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FusesLib} from "../libraries/FusesLib.sol";
import {PlasmaVaultConfigLib} from "../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib, InstantWithdrawalFusesParamsStruct} from "../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../price_oracle/IPriceOracleMiddleware.sol";
import {Errors} from "../libraries/errors/Errors.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";
import {AssetDistributionProtectionLib, MarketLimit} from "../libraries/AssetDistributionProtectionLib.sol";
import {AccessManagedUpgradeable} from "../managers/access/AccessManagedUpgradeable.sol";
import {CallbackHandlerLib} from "../libraries/CallbackHandlerLib.sol";
import {IPlasmaVaultGovernance} from "../interfaces/IPlasmaVaultGovernance.sol";

/// @title Plasma Vault Governance part of the Plasma Vault including Access Manager. Allows to manage the vault configuration like fuses, price oracle, fees, etc.
abstract contract PlasmaVaultGovernance is IPlasmaVaultGovernance, AccessManagedUpgradeable {
    function isMarketSubstrateGranted(uint256 marketId_, bytes32 substrate_) external view override returns (bool) {
        return PlasmaVaultConfigLib.isMarketSubstrateGranted(marketId_, substrate_);
    }

    function isFuseSupported(address fuse_) external view override returns (bool) {
        return FusesLib.isFuseSupported(fuse_);
    }

    function isBalanceFuseSupported(uint256 marketId_, address fuse_) external view override returns (bool) {
        return FusesLib.isBalanceFuseSupported(marketId_, fuse_);
    }

    function isMarketsLimitsActivated() public view override returns (bool) {
        return AssetDistributionProtectionLib.isMarketsLimitsActivated();
    }

    function getMarketSubstrates(uint256 marketId_) external view override returns (bytes32[] memory) {
        return PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
    }

    function getFuses() external view override returns (address[] memory) {
        return FusesLib.getFusesArray();
    }

    function getPriceOracleMiddleware() external view override returns (address) {
        return PlasmaVaultLib.getPriceOracleMiddleware();
    }

    function getPerformanceFeeData()
        external
        view
        override
        returns (PlasmaVaultStorageLib.PerformanceFeeData memory feeData)
    {
        feeData = PlasmaVaultLib.getPerformanceFeeData();
    }

    function getManagementFeeData()
        external
        view
        override
        returns (PlasmaVaultStorageLib.ManagementFeeData memory feeData)
    {
        feeData = PlasmaVaultLib.getManagementFeeData();
    }

    function getAccessManagerAddress() external view override returns (address) {
        return authority();
    }

    function getRewardsClaimManagerAddress() external view override returns (address) {
        return PlasmaVaultLib.getRewardsClaimManagerAddress();
    }

    function getInstantWithdrawalFuses() external view override returns (address[] memory) {
        return PlasmaVaultLib.getInstantWithdrawalFuses();
    }

    function getInstantWithdrawalFusesParams(
        address fuse_,
        uint256 index_
    ) external view override returns (bytes32[] memory) {
        return PlasmaVaultLib.getInstantWithdrawalFusesParams(fuse_, index_);
    }

    function getMarketLimit(uint256 marketId_) external view override returns (uint256) {
        return PlasmaVaultStorageLib.getMarketsLimits().limitInPercentage[marketId_];
    }

    function getDependencyBalanceGraph(uint256 marketId_) external view override returns (uint256[] memory) {
        return PlasmaVaultStorageLib.getDependencyBalanceGraph().dependencyGraph[marketId_];
    }

    function getTotalSupplyCap() external view override returns (uint256) {
        return PlasmaVaultLib.getTotalSupplyCap();
    }

    function addBalanceFuse(uint256 marketId_, address fuse_) external override restricted {
        _addBalanceFuse(marketId_, fuse_);
    }

    function removeBalanceFuse(uint256 marketId_, address fuse_) external override restricted {
        FusesLib.removeBalanceFuse(marketId_, fuse_);
    }

    function grantMarketSubstrates(uint256 marketId_, bytes32[] calldata substrates_) external override restricted {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    function updateDependencyBalanceGraphs(
        uint256[] memory marketIds_,
        uint256[][] memory dependencies_
    ) external override restricted {
        uint256 marketIdsLength = marketIds_.length;
        if (marketIdsLength != dependencies_.length) {
            revert Errors.WrongArrayLength();
        }
        for (uint256 i; i < marketIdsLength; ++i) {
            PlasmaVaultStorageLib.getDependencyBalanceGraph().dependencyGraph[marketIds_[i]] = dependencies_[i];
        }
    }

    /// @notice Configures the instant withdrawal fuses. Order of the fuse is important, as it will be used in the same order during the instant withdrawal process
    /// @dev Order of the fuses is important, the same fuse can be used multiple times with different parameters (for example different assets, markets or any other substrate specific for the fuse)
    function configureInstantWithdrawalFuses(
        InstantWithdrawalFusesParamsStruct[] calldata fuses_
    ) external override restricted {
        PlasmaVaultLib.configureInstantWithdrawalFuses(fuses_);
    }

    function addFuses(address[] calldata fuses_) external override restricted {
        for (uint256 i; i < fuses_.length; ++i) {
            FusesLib.addFuse(fuses_[i]);
        }
    }

    function removeFuses(address[] calldata fuses_) external override restricted {
        for (uint256 i; i < fuses_.length; ++i) {
            FusesLib.removeFuse(fuses_[i]);
        }
    }

    function setPriceOracleMiddleware(address priceOracleMiddleware_) external override restricted {
        IPriceOracleMiddleware oldPriceOracleMiddleware = IPriceOracleMiddleware(
            PlasmaVaultLib.getPriceOracleMiddleware()
        );
        IPriceOracleMiddleware newPriceOracleMiddleware = IPriceOracleMiddleware(priceOracleMiddleware_);

        if (
            oldPriceOracleMiddleware.QUOTE_CURRENCY() != newPriceOracleMiddleware.QUOTE_CURRENCY() ||
            oldPriceOracleMiddleware.QUOTE_CURRENCY_DECIMALS() != newPriceOracleMiddleware.QUOTE_CURRENCY_DECIMALS()
        ) {
            revert Errors.UnsupportedPriceOracleMiddleware();
        }

        PlasmaVaultLib.setPriceOracleMiddleware(priceOracleMiddleware_);
    }

    function configurePerformanceFee(address feeManager_, uint256 feeInPercentage_) external override restricted {
        PlasmaVaultLib.configurePerformanceFee(feeManager_, feeInPercentage_);
    }

    function configureManagementFee(address feeManager_, uint256 feeInPercentage_) external override restricted {
        PlasmaVaultLib.configureManagementFee(feeManager_, feeInPercentage_);
    }

    function setRewardsClaimManagerAddress(address rewardsClaimManagerAddress_) public override restricted {
        PlasmaVaultLib.setRewardsClaimManagerAddress(rewardsClaimManagerAddress_);
    }

    function setupMarketsLimits(MarketLimit[] calldata marketsLimits_) external override restricted {
        AssetDistributionProtectionLib.setupMarketsLimits(marketsLimits_);
    }

    /// @notice Activates the markets limits protection, by default it is deactivated. After activation the limits
    /// is setup for each market separately.
    function activateMarketsLimits() public override restricted {
        AssetDistributionProtectionLib.activateMarketsLimits();
    }

    /// @notice Deactivates the markets limits protection.
    function deactivateMarketsLimits() public override restricted {
        AssetDistributionProtectionLib.deactivateMarketsLimits();
    }

    function updateCallbackHandler(address handler_, address sender_, bytes4 sig_) external override restricted {
        CallbackHandlerLib.updateCallbackHandler(handler_, sender_, sig_);
    }

    function setTotalSupplyCap(uint256 cap_) external override restricted {
        PlasmaVaultLib.setTotalSupplyCap(cap_);
    }

    function _addFuse(address fuse_) internal {
        if (fuse_ == address(0)) {
            revert Errors.WrongAddress();
        }
        FusesLib.addFuse(fuse_);
    }

    function _addBalanceFuse(uint256 marketId_, address fuse_) internal {
        if (fuse_ == address(0)) {
            revert Errors.WrongAddress();
        }
        FusesLib.addBalanceFuse(marketId_, fuse_);
    }
}
