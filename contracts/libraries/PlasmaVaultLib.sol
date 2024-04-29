// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";

library PlasmaVaultLib {
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice Technical struct used to pass parameters in the `updateInstantWithdrawalFuses` function
    struct InstantWithdrawalFusesParamsStruct {
        /// @notice The address of the fuse
        address fuse;
        /// @notice The parameters of the fuse, first element is an amount, second element is an address of the asset or a market id or other substrate specific for the fuse
        bytes32[] params;
    }

    event TotalAssetsInAllMarketsAdded(int256 amount);
    event TotalAssetsInMarketAdded(uint256 marketId, int256 amount);
    event InstantWithdrawalFusesUpdated(InstantWithdrawalFusesParamsStruct[] fuses);

    /// @notice Gets the total assets in the vault for all markets
    /// @return The total assets in the vault for all markets, represented in decimals of the underlying asset
    function getTotalAssetsInAllMarkets() internal view returns (uint256) {
        return PlasmaVaultStorageLib.getTotalAssets().value;
    }

    /// @notice Gets the total assets in the vault for a specific market
    /// @param marketId The market id
    /// @return The total assets in the vault for the market, represented in decimals of the underlying asset
    function getTotalAssetsInMarket(uint256 marketId) internal view returns (uint256) {
        return PlasmaVaultStorageLib.getMarketTotalAssets().value[marketId];
    }

    /// @notice Adds an amount to the total assets in the vault for all markets
    /// @param amount The amount to add, represented in decimals of the underlying asset
    function addToTotalAssetsInAllMarkets(int256 amount) internal {
        if (amount < 0) {
            PlasmaVaultStorageLib.getTotalAssets().value -= (-amount).toUint256();
        } else {
            PlasmaVaultStorageLib.getTotalAssets().value += amount.toUint256();
        }

        emit TotalAssetsInAllMarketsAdded(amount);
    }

    /// @notice Updates the total assets in the vault for a specific market
    /// @param marketId The market id
    /// @param newTotalAssetsInUnderlying The new total assets in the vault for the market, represented in decimals of the underlying asset
    function updateTotalAssetsInMarket(
        uint256 marketId,
        uint256 newTotalAssetsInUnderlying
    ) internal returns (int256 deltaInUnderlying) {
        uint256 oldTotalAssetsInUnderlying = PlasmaVaultStorageLib.getMarketTotalAssets().value[marketId];
        PlasmaVaultStorageLib.getMarketTotalAssets().value[marketId] = newTotalAssetsInUnderlying;
        deltaInUnderlying = newTotalAssetsInUnderlying.toInt256() - oldTotalAssetsInUnderlying.toInt256();

        emit TotalAssetsInMarketAdded(marketId, deltaInUnderlying);
    }

    function getFees() internal view returns (PlasmaVaultStorageLib.Fees memory fees) {
        return PlasmaVaultStorageLib.getFees().value;
    }

    function setFeeManager(address newFeeManager) internal {
        PlasmaVaultStorageLib.getFees().value.manager = newFeeManager;
    }

    function setFeeConfiguration(uint256 newPerformanceFeeInPercentage, uint256 newManagementFeeInPercentage) internal {
        PlasmaVaultStorageLib.getFees().value.cfgPerformanceFeeInPercentage = newPerformanceFeeInPercentage.toUint16();
        PlasmaVaultStorageLib.getFees().value.cfgManagementFeeInPercentage = newManagementFeeInPercentage.toUint16();
    }

    function addFeeBalance(uint256 newPerformanceFeeBalance, uint256 newManagementFeeBalance) internal {
        PlasmaVaultStorageLib.getFees().value.performanceFeeBalance += newPerformanceFeeBalance.toUint32();
        PlasmaVaultStorageLib.getFees().value.managementFeeBalance += newManagementFeeBalance.toUint32();
    }

    function getInstantWithdrawalFuses() internal view returns (address[] memory) {
        return PlasmaVaultStorageLib.getInstantWithdrawalFusesArray().value;
    }

    function getInstantWithdrawalFusesParams(address fuse, uint256 index) internal view returns (bytes32[] memory) {
        return PlasmaVaultStorageLib.getInstantWithdrawalFusesParams().value[keccak256(abi.encodePacked(fuse, index))];
    }

    function updateInstantWithdrawalFuses(InstantWithdrawalFusesParamsStruct[] calldata fuses) internal {
        address[] memory fusesList = new address[](fuses.length);

        PlasmaVaultStorageLib.InstantWithdrawalFusesParams storage instantWithdrawalFusesParams = PlasmaVaultStorageLib
            .getInstantWithdrawalFusesParams();

        bytes32 key;

        for (uint256 i; i < fuses.length; ++i) {
            fusesList[i] = fuses[i].fuse;
            key = keccak256(abi.encodePacked(fuses[i].fuse, i));

            delete instantWithdrawalFusesParams.value[key];

            for (uint256 j; j < fuses[i].params.length; ++j) {
                instantWithdrawalFusesParams.value[key].push(fuses[i].params[j]);
            }
        }

        delete PlasmaVaultStorageLib.getInstantWithdrawalFusesArray().value;

        PlasmaVaultStorageLib.getInstantWithdrawalFusesArray().value = fusesList;

        emit InstantWithdrawalFusesUpdated(fuses);
    }
}
