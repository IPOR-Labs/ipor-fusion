// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PlazmaVaultStorageLib} from "./PlazmaVaultStorageLib.sol";

library PlazmaVaultLib {
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
    event PriceOracleChanged(address newPriceOracle);

    /// @notice Gets the total assets in the vault for all markets
    /// @return The total assets in the vault for all markets, represented in decimals of the underlying asset
    function getTotalAssetsInAllMarkets() internal view returns (uint256) {
        return PlazmaVaultStorageLib.getTotalAssets().value;
    }

    /// @notice Gets the total assets in the vault for a specific market
    /// @param marketId The market id
    /// @return The total assets in the vault for the market, represented in decimals of the underlying asset
    function getTotalAssetsInMarket(uint256 marketId) internal view returns (uint256) {
        return PlazmaVaultStorageLib.getMarketTotalAssets().value[marketId];
    }

    /// @notice Adds an amount to the total assets in the vault for all markets
    /// @param amount The amount to add, represented in decimals of the underlying asset
    function addToTotalAssetsInAllMarkets(int256 amount) internal {
        if (amount < 0) {
            PlazmaVaultStorageLib.getTotalAssets().value -= (-amount).toUint256();
        } else {
            PlazmaVaultStorageLib.getTotalAssets().value += amount.toUint256();
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
        uint256 oldTotalAssetsInUnderlying = PlazmaVaultStorageLib.getMarketTotalAssets().value[marketId];
        PlazmaVaultStorageLib.getMarketTotalAssets().value[marketId] = newTotalAssetsInUnderlying;
        deltaInUnderlying = newTotalAssetsInUnderlying.toInt256() - oldTotalAssetsInUnderlying.toInt256();

        emit TotalAssetsInMarketAdded(marketId, deltaInUnderlying);
    }

    function getInstantWithdrawalFuses() internal view returns (address[] memory) {
        return PlazmaVaultStorageLib.getInstantWithdrawalFusesArray().value;
    }

    function getInstantWithdrawalFusesParams(address fuse, uint256 index) internal view returns (bytes32[] memory) {
        return PlazmaVaultStorageLib.getInstantWithdrawalFusesParams().value[keccak256(abi.encodePacked(fuse, index))];
    }

    function updateInstantWithdrawalFuses(InstantWithdrawalFusesParamsStruct[] calldata fuses) internal {
        address[] memory fusesList = new address[](fuses.length);

        PlazmaVaultStorageLib.InstantWithdrawalFusesParams storage instantWithdrawalFusesParams = PlazmaVaultStorageLib
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

        delete PlazmaVaultStorageLib.getInstantWithdrawalFusesArray().value;

        PlazmaVaultStorageLib.getInstantWithdrawalFusesArray().value = fusesList;

        emit InstantWithdrawalFusesUpdated(fuses);
    }

    /// @notice Gets the price oracle address
    function getPriceOracle() internal view returns (address) {
        return PlazmaVaultStorageLib.getPriceOracle().value;
    }

    /// @notice Sets the price oracle address
    /// @param priceOracle The price oracle address
    function setPriceOracle(address priceOracle) internal {
        PlazmaVaultStorageLib.getPriceOracle().value = priceOracle;
        emit PriceOracleChanged(priceOracle);
    }
}
