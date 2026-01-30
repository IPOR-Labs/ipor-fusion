// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

/// @title IAaveV4Spoke
/// @notice Interface for Aave V4 Spoke contracts in the Hub & Spoke architecture.
///         Aligned with the real ISpokeBase / ISpoke from aave/aave-v4.
/// @dev Spoke contracts serve as the user-facing interface with their own risk profile.
///      Positions are tracked per-Spoke using share-based accounting.
interface IAaveV4Spoke {
    // ============ Supply / Withdraw ============

    /// @notice Supplies assets into the Spoke's reserve
    /// @param reserveId The reserve identifier within this Spoke
    /// @param amount The amount of underlying tokens to supply
    /// @param onBehalfOf The address that will receive the supply position
    /// @return shares The amount of supply shares minted
    /// @return suppliedAmount The amount of underlying assets supplied
    function supply(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256 shares, uint256 suppliedAmount);

    /// @notice Withdraws assets from the Spoke's reserve.
    ///         The caller receives the withdrawn tokens.
    /// @param reserveId The reserve identifier within this Spoke
    /// @param amount The amount of underlying tokens to withdraw (type(uint256).max for full withdrawal)
    /// @param onBehalfOf The owner of the position to remove supply shares from
    /// @return withdrawnShares The amount of supply shares burned
    /// @return withdrawnAmount The amount of underlying tokens withdrawn
    function withdraw(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256 withdrawnShares, uint256 withdrawnAmount);

    // ============ Borrow / Repay ============

    /// @notice Borrows assets from the Spoke's reserve.
    ///         The caller receives the borrowed tokens.
    /// @param reserveId The reserve identifier within this Spoke
    /// @param amount The amount of underlying tokens to borrow
    /// @param onBehalfOf The address against which debt is generated
    /// @return shares The amount of borrow (drawn) shares created
    /// @return borrowedAmount The amount of underlying assets borrowed
    function borrow(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256 shares, uint256 borrowedAmount);

    /// @notice Repays borrowed assets to the Spoke's reserve
    /// @param reserveId The reserve identifier within this Spoke
    /// @param amount The amount of underlying tokens to repay
    /// @param onBehalfOf The address whose debt will be reduced
    /// @return repaidShares The amount of drawn shares burned
    /// @return repaidAmount The amount of underlying tokens repaid
    function repay(
        uint256 reserveId,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256 repaidShares, uint256 repaidAmount);

    // ============ User Position Queries ============

    /// @notice Returns the amount of supply shares held by a user for a given reserve
    /// @param reserveId The reserve identifier
    /// @param user The address of the user
    /// @return The amount of supply shares
    function getUserSuppliedShares(uint256 reserveId, address user) external view returns (uint256);

    /// @notice Returns the amount of supply assets for a user (shares converted to assets)
    /// @param reserveId The reserve identifier
    /// @param user The address of the user
    /// @return The amount of supplied assets
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);

    /// @notice Returns the total debt of a specific user for a given reserve (drawn + premium)
    /// @param reserveId The reserve identifier
    /// @param user The address of the user
    /// @return The total debt amount in underlying asset units
    function getUserTotalDebt(uint256 reserveId, address user) external view returns (uint256);

    // ============ Reserve Queries ============

    /// @notice Returns the number of listed reserves on the Spoke
    /// @return The number of reserves
    function getReserveCount() external view returns (uint256);

    /// @notice Reserve level data
    struct Reserve {
        address underlying;
        address hub; // IHubBase but stored as address for cross-version compat
        uint16 assetId;
        uint8 decimals;
        uint24 dynamicConfigKey;
        uint24 collateralRisk;
        uint8 flags; // ReserveFlags packed as uint8
    }

    /// @notice Returns the reserve struct data
    /// @param reserveId The reserve identifier
    /// @return The reserve struct
    function getReserve(uint256 reserveId) external view returns (Reserve memory);

    // ============ Reserve Aggregate Queries ============

    /// @notice Returns the total amount of supplied assets of a given reserve
    /// @param reserveId The reserve identifier
    /// @return The amount of supplied assets
    function getReserveSuppliedAssets(uint256 reserveId) external view returns (uint256);

    /// @notice Returns the total debt of a given reserve (drawn + premium)
    /// @param reserveId The reserve identifier
    /// @return The total debt amount
    function getReserveTotalDebt(uint256 reserveId) external view returns (uint256);

    // ============ E-Mode ============

    /// @notice Sets the E-Mode category for the caller
    /// @param categoryId The E-Mode category ID (0 to disable)
    function setUserEMode(uint8 categoryId) external;

    /// @notice Returns the E-Mode category for a user
    /// @param user The address of the user
    /// @return The E-Mode category ID
    function getUserEMode(address user) external view returns (uint8);
}
