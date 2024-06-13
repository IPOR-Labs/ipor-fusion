// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
struct MarketToCheck {
    uint256 marketId;
    uint256 balanceInMarket;
}

struct DataToCheck {
    uint256 totalBalanceInVault;
    MarketToCheck[] marketsToCheck;
}

struct MarketLimit {
    uint256 marketId;
    uint256 limit;
}

library AssetDistributionProtectionLib {
    event MarketsLimitsActivated();
    event MarketsLimitsDeactivated();
    event MarketLimitUpdated(uint256 marketId, uint256 newLimit);

    error MarketLimitHasBeenExceeded(uint256 marketId, uint256 balanceInMarket, uint256 limit);

    function activateMarketsLimits() internal {
        PlasmaVaultStorageLib.getMarketsLimits().marketLimits[0] = 1;
        emit MarketsLimitsActivated();
    }

    function deactivateMarketsLimits() internal {
        PlasmaVaultStorageLib.getMarketsLimits().marketLimits[0] = 0;
        emit MarketsLimitsDeactivated();
    }

    function setupMarketsLimits(MarketLimit[] calldata marketsLimits) internal {
        uint256 len = marketsLimits.length;
        for (uint256 i; i < len; ++i) {
            PlasmaVaultStorageLib.getMarketsLimits().marketLimits[marketsLimits[i].marketId] = marketsLimits[i].limit;
            emit MarketLimitUpdated(marketsLimits[i].marketId, marketsLimits[i].limit);
        }
    }

    function checkLimits(DataToCheck memory data) internal view {
        if (!isMarketsLimitsActivated()) {
            return;
        }
        uint256 len = data.marketsToCheck.length;
        for (uint256 i; i < len; ++i) {
            uint256 limit = Math.mulDiv(
                PlasmaVaultStorageLib.getMarketsLimits().marketLimits[data.marketsToCheck[i].marketId],
                data.totalBalanceInVault,
                1e18
            );
            if (limit < data.marketsToCheck[i].balanceInMarket) {
                revert MarketLimitHasBeenExceeded(
                    data.marketsToCheck[i].marketId,
                    data.marketsToCheck[i].balanceInMarket,
                    limit
                );
            }
        }
    }

    function isMarketsLimitsActivated() internal view returns (bool) {
        return PlasmaVaultStorageLib.getMarketsLimits().marketLimits[0] != 0;
    }
}
