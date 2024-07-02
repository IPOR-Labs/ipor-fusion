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
    /// @dev MarketId: the same value as used in fuse
    uint256 marketId;
    /// @dev Limit in percentage of the total balance in the vault, use 1e18 as 100%
    uint256 limitInPercentage;
}

library AssetDistributionProtectionLib {
    event MarketsLimitsActivated();
    event MarketsLimitsDeactivated();
    event MarketLimitUpdated(uint256 marketId, uint256 newLimit);

    error MarketLimitExceeded(uint256 marketId, uint256 balanceInMarket, uint256 limit);
    error WrongMarketId(uint256 marketId);

    /// @notice Activates the markets limits protection, by default it is deactivated. After activation the limits
    /// is setup for each market separately.
    function activateMarketsLimits() internal {
        PlasmaVaultStorageLib.getMarketsLimits().limitInPercentage[0] = 1;
        emit MarketsLimitsActivated();
    }

    /// @notice Deactivates the markets limits protection.
    function deactivateMarketsLimits() internal {
        PlasmaVaultStorageLib.getMarketsLimits().limitInPercentage[0] = 0;
        emit MarketsLimitsDeactivated();
    }

    function setupMarketsLimits(MarketLimit[] calldata marketsLimits_) internal {
        uint256 len = marketsLimits_.length;
        for (uint256 i; i < len; ++i) {
            if (marketsLimits_[i].marketId == 0) {
                revert WrongMarketId(marketsLimits_[i].marketId);
            }
            PlasmaVaultStorageLib.getMarketsLimits().limitInPercentage[marketsLimits_[i].marketId] = marketsLimits_[i]
                .limitInPercentage;
            emit MarketLimitUpdated(marketsLimits_[i].marketId, marketsLimits_[i].limitInPercentage);
        }
    }

    function checkLimits(DataToCheck memory data_) internal view {
        if (!isMarketsLimitsActivated()) {
            return;
        }
        uint256 len = data_.marketsToCheck.length;
        for (uint256 i; i < len; ++i) {
            uint256 limit = Math.mulDiv(
                PlasmaVaultStorageLib.getMarketsLimits().limitInPercentage[data_.marketsToCheck[i].marketId],
                data_.totalBalanceInVault,
                1e18
            );
            if (limit < data_.marketsToCheck[i].balanceInMarket) {
                revert MarketLimitExceeded(
                    data_.marketsToCheck[i].marketId,
                    data_.marketsToCheck[i].balanceInMarket,
                    limit
                );
            }
        }
    }

    function isMarketsLimitsActivated() internal view returns (bool) {
        return PlasmaVaultStorageLib.getMarketsLimits().limitInPercentage[0] != 0;
    }
}
