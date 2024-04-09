// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PlazmaVaultStorageLib} from "./PlazmaVaultStorageLib.sol";

library PlazmaVaultLib {
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice Gets the total assets in the vault for all markets
    function getTotalAssetsInAllMarkets() internal view returns (uint256) {
        return PlazmaVaultStorageLib.getVaultTotalAssets().value;
    }

    /// @notice Gets the total assets in the vault for a specific market
    /// @param marketId The market id
    function getTotalAssetsInMarket(uint256 marketId) internal view returns (uint256) {
        return PlazmaVaultStorageLib.getVaultMarketTotalAssets().value[marketId];
    }

    function addToTotalAssetsInMarkets(int256 amount) internal {
        if (amount < 0) {
            PlazmaVaultStorageLib.getVaultTotalAssets().value -= (-amount).toUint256();
        } else {
            PlazmaVaultStorageLib.getVaultTotalAssets().value += amount.toUint256();
        }
    }

    //TODO: fix delta as int256, add tests with exit
    function updateTotalAssetsInMarket(uint256 marketId, uint256 newTotalAssets) internal returns (int256 delta) {
        uint256 oldTotalAssets = PlazmaVaultStorageLib.getVaultMarketTotalAssets().value[marketId];
        PlazmaVaultStorageLib.getVaultMarketTotalAssets().value[marketId] = newTotalAssets;
        delta = newTotalAssets.toInt256() - oldTotalAssets.toInt256();
    }
}
