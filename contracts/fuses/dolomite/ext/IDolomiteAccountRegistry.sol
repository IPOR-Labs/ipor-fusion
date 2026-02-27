// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IDolomiteAccountRegistry interface for Dolomite account configuration
/// @notice Interface for managing account-level settings including E-mode
/// @dev E-mode (Efficiency Mode) allows higher LTV for correlated asset pairs (e.g., stablecoins, ETH derivatives)
interface IDolomiteAccountRegistry {
    /// @notice E-mode category struct
    struct EModeCategory {
        /// @dev Category ID (0 = no e-mode, 1+ = specific category)
        uint8 id;
        /// @dev LTV for e-mode (scaled by 1e4, e.g., 9500 = 95%)
        uint16 ltv;
        /// @dev Liquidation threshold for e-mode (scaled by 1e4)
        uint16 liquidationThreshold;
        /// @dev Liquidation bonus for e-mode (scaled by 1e4)
        uint16 liquidationBonus;
        /// @dev Price oracle for e-mode (address(0) = use default)
        address priceOracle;
        /// @dev Label for the e-mode category
        string label;
    }

    /// @notice Gets the e-mode category for an account
    /// @param account The account address
    /// @param accountNumber The sub-account number
    /// @return The e-mode category ID (0 if not in e-mode)
    function getAccountEMode(address account, uint256 accountNumber) external view returns (uint8);

    /// @notice Sets the e-mode category for the caller's account
    /// @param accountNumber The sub-account number
    /// @param categoryId The e-mode category ID (0 to disable)
    function setAccountEMode(uint256 accountNumber, uint8 categoryId) external;

    /// @notice Gets the e-mode category configuration
    /// @param categoryId The category ID
    /// @return The e-mode category configuration
    function getEModeCategory(uint8 categoryId) external view returns (EModeCategory memory);

    /// @notice Gets the list of valid e-mode category IDs
    /// @return Array of valid category IDs
    function getEModeCategoryIds() external view returns (uint8[] memory);

    /// @notice Checks if a market is compatible with an e-mode category
    /// @param marketId The Dolomite market ID
    /// @param categoryId The e-mode category ID
    /// @return True if the market is compatible with the category
    function isMarketInEModeCategory(uint256 marketId, uint8 categoryId) external view returns (bool);
}
