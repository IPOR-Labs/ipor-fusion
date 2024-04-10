// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PlazmaVaultStorageLib} from "./PlazmaVaultStorageLib.sol";

library PlazmaVaultLib {
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice Gets the total assets in the vault for all markets
    /// @return The total assets in the vault for all markets, represented in decimals of the underlying asset
    function getTotalAssetsInAllMarkets() internal view returns (uint256) {
        return PlazmaVaultStorageLib.getVaultTotalAssets().value;
    }

    /// @notice Gets the total assets in the vault for a specific market
    /// @param marketId The market id
    /// @return The total assets in the vault for the market, represented in decimals of the underlying asset
    function getTotalAssetsInMarket(uint256 marketId) internal view returns (uint256) {
        return PlazmaVaultStorageLib.getVaultMarketTotalAssets().value[marketId];
    }

    /// @notice Adds an amount to the total assets in the vault for all markets
    /// @param amount The amount to add, represented in decimals of the underlying asset
    function addToTotalAssetsInMarkets(int256 amount) internal {
        if (amount < 0) {
            PlazmaVaultStorageLib.getVaultTotalAssets().value -= (-amount).toUint256();
        } else {
            PlazmaVaultStorageLib.getVaultTotalAssets().value += amount.toUint256();
        }
    }

    /// @notice Updates the total assets in the vault for a specific market
    /// @param marketId The market id
    /// @param newTotalAssetsInUnderlying The new total assets in the vault for the market, represented in decimals of the underlying asset
    function updateTotalAssetsInMarket(
        uint256 marketId,
        uint256 newTotalAssetsInUnderlying
    ) internal returns (int256 deltaInUnderlying) {
        uint256 oldTotalAssetsInUnderlying = PlazmaVaultStorageLib.getVaultMarketTotalAssets().value[marketId];
        PlazmaVaultStorageLib.getVaultMarketTotalAssets().value[marketId] = newTotalAssetsInUnderlying;
        deltaInUnderlying = newTotalAssetsInUnderlying.toInt256() - oldTotalAssetsInUnderlying.toInt256();
    }
}
