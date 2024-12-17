// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice MarketToCheck struct for the markets limits protection
struct MarketToCheck {
    /// @param marketId The market id
    uint256 marketId;
    /// @param balanceInMarket The balance in the market, represented in 18 decimals
    uint256 balanceInMarket;
}

/// @notice DataToCheck struct for the markets limits protection
struct DataToCheck {
    /// @param totalBalanceInVault The total balance in the Plasma Vault, represented in 18 decimals
    uint256 totalBalanceInVault;
    /// @param marketsToCheck The array of MarketToCheck structs
    MarketToCheck[] marketsToCheck;
}

/// @notice Market limit struct
struct MarketLimit {
    /// @dev MarketId: the same value as used in fuse
    uint256 marketId;
    /// @dev Limit in percentage of the total balance in the vault, use 1e18 as 100%
    uint256 limitInPercentage;
}

/// @title Asset Distribution Protection Library responsible for the markets limits protection in the Plasma Vault
library AssetDistributionProtectionLib {
    uint256 private constant ONE_HUNDRED_PERCENT = 1e18;

    event MarketsLimitsActivated();
    event MarketsLimitsDeactivated();
    event MarketLimitUpdated(uint256 marketId, uint256 newLimit);

    error MarketLimitExceeded(uint256 marketId, uint256 balanceInMarket, uint256 limit);
    error MarketLimitSetupInPercentageIsTooHigh(uint256 limit);
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

    /// @notice Sets up the limits for each market separately.
    /// @param marketsLimits_ The array of MarketLimit structs
    function setupMarketsLimits(MarketLimit[] calldata marketsLimits_) internal {
        uint256 len = marketsLimits_.length;
        for (uint256 i; i < len; ++i) {
            if (marketsLimits_[i].marketId == 0) {
                revert WrongMarketId(marketsLimits_[i].marketId);
            }
            if (marketsLimits_[i].limitInPercentage > ONE_HUNDRED_PERCENT) {
                revert MarketLimitSetupInPercentageIsTooHigh(marketsLimits_[i].limitInPercentage);
            }
            PlasmaVaultStorageLib.getMarketsLimits().limitInPercentage[marketsLimits_[i].marketId] = marketsLimits_[i]
                .limitInPercentage;
            emit MarketLimitUpdated(marketsLimits_[i].marketId, marketsLimits_[i].limitInPercentage);
        }
    }

    /// @notice Checks if the limits are exceeded for the markets.
    /// @param data_ The DataToCheck struct
    /// @dev revert if the limit is exceeded
    function checkLimits(DataToCheck memory data_) internal view {
        if (!isMarketsLimitsActivated()) {
            return;
        }
        
        uint256 len = data_.marketsToCheck.length;
        uint256 limit;

        for (uint256 i; i < len; ++i) {
            limit = Math.mulDiv(
                PlasmaVaultStorageLib.getMarketsLimits().limitInPercentage[data_.marketsToCheck[i].marketId],
                data_.totalBalanceInVault,
                ONE_HUNDRED_PERCENT
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

    /// @notice Checks if the markets limits protection is activated.
    /// @return bool true if the markets limits protection is activated
    function isMarketsLimitsActivated() internal view returns (bool) {
        return PlasmaVaultStorageLib.getMarketsLimits().limitInPercentage[0] != 0;
    }
}
