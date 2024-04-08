// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {PlazmaVaultStorageLib} from "./PlazmaVaultStorageLib.sol";

library PlazmaVaultLib {
    /// @notice Gets the total assets in the vault for all markets
    function getTotalAssetsInAllMarkets() internal view returns (uint256) {
        return PlazmaVaultStorageLib.getVaultTotalAssets().value;
    }

    /// @notice Gets the total assets in the vault for a specific market
    /// @param marketId The market id
    function getTotalAssetsInMarket(uint256 marketId) internal view returns (uint256) {
        return PlazmaVaultStorageLib.getVaultMarketTotalAssets().value[marketId];
    }

    function addToTotalAssetsInMarkets(uint256 amount) internal {
        PlazmaVaultStorageLib.getVaultTotalAssets().value += amount;
    }

    //TODO: fix delta as int256, add tests with exit
    function updateTotalAssetsInMarket(uint256 marketId, uint256 newTotalAssets) internal returns (uint256 delta) {
        if (newTotalAssets == 0) {
            return 0;
        }
        uint256 oldTotalAssets = PlazmaVaultStorageLib.getVaultMarketTotalAssets().value[marketId];
        PlazmaVaultStorageLib.getVaultMarketTotalAssets().value[marketId] = newTotalAssets;
        delta = newTotalAssets - oldTotalAssets;
    }
}
