// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title Asset Distribution Protection Library - Risk Management System for Plasma Vault
 * @notice Library enforcing market exposure limits and risk distribution across DeFi protocols
 * @dev Core risk management component that:
 * 1. Enforces maximum exposure limits per market
 * 2. Tracks and validates asset distribution
 * 3. Provides activation/deactivation controls
 * 4. Maintains market-specific limit configurations
 *
 * Key Components:
 * - Market Limit System: Percentage-based exposure controls
 * - Activation Controls: System-wide protection toggle
 * - Limit Validation: Real-time balance checks
 * - Storage Integration: Uses PlasmaVaultStorageLib for persistent state
 *
 * Integration Points:
 * - Used by PlasmaVault for operation validation
 * - Managed through PlasmaVaultGovernance
 * - Coordinates with FusesLib for market balance data
 * - Works with balance fuses for position tracking
 *
 * Security Considerations:
 * - Prevents over-concentration in single markets
 * - Enforces risk distribution across protocols
 * - Maintains system-wide risk parameters
 * - Critical for vault's risk management
 *
 * @custom:security-contact security@ipor.io
 */

/**
 * @notice Market balance tracking structure for limit validation
 * @dev Used during balance updates and limit checks
 *
 * Storage Layout:
 * - marketId: Maps to protocol-specific market identifiers
 * - balanceInMarket: Standardized 18-decimal balance representation
 *
 * Integration Context:
 * - Used by checkLimits() for validation
 * - Populated during balance updates
 * - Coordinates with balance fuses
 */
struct MarketToCheck {
    /// @notice The unique identifier of the market
    /// @dev Same ID used in fuse contracts and market configurations
    uint256 marketId;
    /// @notice The current balance allocated to this market
    /// @dev Amount represented in 18 decimals for consistent comparison
    uint256 balanceInMarket;
}

/**
 * @notice Aggregated vault state for market limit validation
 * @dev Combines total vault value with per-market positions
 *
 * Components:
 * - Total vault balance for percentage calculations
 * - Array of market positions for limit checking
 *
 * Integration Context:
 * - Used during vault operations
 * - Critical for limit enforcement
 * - Updated on balance changes
 */
struct DataToCheck {
    /// @notice Total value of assets in the Plasma Vault
    /// @dev Amount represented in 18 decimals for consistent comparison
    uint256 totalBalanceInVault;
    /// @notice Array of markets and their current balances to validate
    MarketToCheck[] marketsToCheck;
}

/**
 * @notice Market-specific exposure limit configuration
 * @dev Defines maximum allowed allocation per market
 *
 * Configuration Notes:
 * - Uses fixed-point percentages (1e18 = 100%)
 * - Market ID must match protocol identifiers
 * - Zero marketId is reserved for system control
 *
 * Integration Context:
 * - Set through governance
 * - Used in limit validation
 * - Critical for risk management
 */
struct MarketLimit {
    /// @notice The unique identifier of the market
    /// @dev Must match the marketId used in fuse contracts
    uint256 marketId;
    /// @notice Maximum percentage of total vault assets allowed in this market
    /// @dev Uses fixed-point notation where 1e18 represents 100%
    uint256 limitInPercentage;
}

library AssetDistributionProtectionLib {
    /// @dev Represents 100% in fixed-point notation (1e18)
    uint256 private constant ONE_HUNDRED_PERCENT = 1e18;

    /// @notice Emitted when market limits protection is activated
    event MarketsLimitsActivated();
    /// @notice Emitted when market limits protection is deactivated
    event MarketsLimitsDeactivated();
    /// @notice Emitted when a market's limit is updated
    /// @param marketId The ID of the market whose limit was updated
    /// @param newLimit The new limit value in percentage (1e18 = 100%)
    event MarketLimitUpdated(uint256 marketId, uint256 newLimit);

    /// @notice Thrown when a market's balance exceeds its configured limit
    error MarketLimitExceeded(uint256 marketId, uint256 balanceInMarket, uint256 limit);
    /// @notice Thrown when attempting to set a limit above 100%
    error MarketLimitSetupInPercentageIsTooHigh(uint256 limit);
    /// @notice Thrown when using an invalid market ID (0 is reserved)
    error WrongMarketId(uint256 marketId);

    /**
     * @notice Activates the market exposure protection system
     * @dev Enables limit enforcement through sentinel value
     *
     * Storage Updates:
     * 1. Sets activation flag in slot 0
     * 2. Emits activation event
     *
     * Integration Context:
     * - Called by PlasmaVaultGovernance
     * - Affects all subsequent vault operations
     * - Requires prior limit configuration
     *
     * Security Considerations:
     * - Only callable through governance
     * - Critical for risk management activation
     * - Must have limits configured before use
     *
     * @custom:events Emits MarketsLimitsActivated
     * @custom:access Restricted to ATOMIST_ROLE via PlasmaVaultGovernance
     */
    function activateMarketsLimits() internal {
        PlasmaVaultStorageLib.getMarketsLimits().limitInPercentage[0] = 1;
        emit MarketsLimitsActivated();
    }

    /**
     * @notice Deactivates the market exposure protection system
     * @dev Disables limit enforcement by clearing sentinel
     *
     * Storage Updates:
     * 1. Clears activation flag in slot 0
     * 2. Emits deactivation event
     *
     * Integration Context:
     * - Called by PlasmaVaultGovernance
     * - Emergency risk control feature
     * - Affects all market operations
     *
     * Security Notes:
     * - Only callable through governance
     * - Should be used with caution
     * - Removes all limit protections
     *
     * @custom:events Emits MarketsLimitsDeactivated
     * @custom:access Restricted to ATOMIST_ROLE via PlasmaVaultGovernance
     */
    function deactivateMarketsLimits() internal {
        PlasmaVaultStorageLib.getMarketsLimits().limitInPercentage[0] = 0;
        emit MarketsLimitsDeactivated();
    }

    /**
     * @notice Configures exposure limits for multiple markets
     * @dev Sets maximum allowed allocation percentages
     *
     * Limit Configuration:
     * - Percentages use 1e18 as 100%
     * - Each market can have unique limit
     * - Zero marketId is reserved
     * - The sum of limits may exceed 100%
     *
     * Storage Updates:
     * 1. Validates each market config
     * 2. Updates limit mappings
     * 3. Emits update events
     *
     * Error Conditions:
     * - Reverts if marketId is 0
     * - Reverts if limit > 100%
     *
     * @param marketsLimits_ Array of market limit configurations
     * @custom:events Emits MarketLimitUpdated for each update
     * @custom:access Restricted to ATOMIST_ROLE via PlasmaVaultGovernance
     */
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

    /**
     * @notice Validates market positions against configured limits
     * @dev Core protection logic for asset distribution
     *
     * Validation Process:
     * 1. Checks system activation
     * 2. Calculates absolute limits
     * 3. Compares current positions
     * 4. Reverts if limits exceeded
     *
     * Integration Context:
     * - Called during vault operations
     * - Critical for risk management
     * - Affects all market interactions
     *
     * Error Handling:
     * - Reverts with MarketLimitExceeded
     * - Includes detailed error data
     * - Prevents limit violations
     *
     * @param data_ Struct containing vault state and positions
     * @custom:security Non-reentrant via PlasmaVault
     */
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

    /**
     * @notice Checks activation status of market limits
     * @dev Uses sentinel value in storage slot 0
     *
     * Storage Pattern:
     * - Slot 0 reserved for activation flag
     * - Non-zero value indicates active
     * - Part of protection system state
     *
     * Integration Context:
     * - Used by checkLimits()
     * - Part of protection logic
     * - Critical for system control
     *
     * @return bool True if market limits are enforced
     */
    function isMarketsLimitsActivated() internal view returns (bool) {
        return PlasmaVaultStorageLib.getMarketsLimits().limitInPercentage[0] != 0;
    }
}
