// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {VaultStorageLib} from "./VaultStorageLib.sol";

library VaultLib {
    function getTotalAssets() internal view returns (uint256) {
        return VaultStorageLib.getVaultTotalAssets().value;
    }
    function getTotalAssetsInMarket(uint256 marketId) internal view returns (uint256) {
        return VaultStorageLib.getVaultMarketTotalAssets().value[marketId];
    }

    function addToTotalAssets(uint256 amount) internal {
        VaultStorageLib.getVaultTotalAssets().value += amount;
    }

    function updateTotalAssetsInMarket(uint256 marketId, uint256 newTotalAssets) internal returns (uint256 delta) {
        if (newTotalAssets == 0) {
            return 0;
        }
        uint256 oldTotalAssets = VaultStorageLib.getVaultMarketTotalAssets().value[marketId];
        VaultStorageLib.getVaultMarketTotalAssets().value[marketId] = newTotalAssets;
        delta = newTotalAssets - oldTotalAssets;
    }
}
