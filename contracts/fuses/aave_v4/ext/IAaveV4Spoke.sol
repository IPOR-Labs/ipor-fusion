// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

/// @title IAaveV4Spoke
/// @notice Interface for Aave V4 Spoke contracts in the Hub & Spoke architecture
/// @dev Spoke contracts serve as the user-facing interface with their own risk profile.
///      Positions are tracked per-Spoke using share-based accounting.
interface IAaveV4Spoke {
    /// @notice Supplies assets into the Spoke's reserve
    /// @param reserveId The reserve identifier within this Spoke
    /// @param amount The amount of underlying tokens to supply
    /// @param onBehalfOf The address that will receive the supply position
    /// @return shares The amount of supply shares minted
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 shares);

    /// @notice Withdraws assets from the Spoke's reserve
    /// @param reserveId The reserve identifier within this Spoke
    /// @param amount The amount of underlying tokens to withdraw
    /// @param to The address that will receive the withdrawn tokens
    /// @return withdrawn The actual amount of underlying tokens withdrawn
    function withdraw(uint256 reserveId, uint256 amount, address to) external returns (uint256 withdrawn);

    /// @notice Borrows assets from the Spoke's reserve
    /// @param reserveId The reserve identifier within this Spoke
    /// @param amount The amount of underlying tokens to borrow
    /// @param onBehalfOf The address that will receive the borrow position
    /// @return shares The amount of borrow shares created
    function borrow(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 shares);

    /// @notice Repays borrowed assets to the Spoke's reserve
    /// @param reserveId The reserve identifier within this Spoke
    /// @param amount The amount of underlying tokens to repay
    /// @param onBehalfOf The address whose debt will be reduced
    /// @return repaid The actual amount of underlying tokens repaid
    function repay(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 repaid);

    /// @notice Returns the position of a user in a specific reserve
    /// @param reserveId The reserve identifier
    /// @param user The address of the user
    /// @return supplyShares The amount of supply shares held by the user
    /// @return borrowShares The amount of borrow shares (debt) held by the user
    function getPosition(
        uint256 reserveId,
        address user
    ) external view returns (uint256 supplyShares, uint256 borrowShares);

    /// @notice Returns the reserve configuration
    /// @param reserveId The reserve identifier
    /// @return asset The address of the underlying ERC20 token
    /// @return totalSupplyShares The total supply shares in the reserve
    /// @return totalBorrowShares The total borrow shares in the reserve
    /// @return totalSupplyAssets The total underlying assets supplied
    /// @return totalBorrowAssets The total underlying assets borrowed
    function getReserve(
        uint256 reserveId
    )
        external
        view
        returns (
            address asset,
            uint256 totalSupplyShares,
            uint256 totalBorrowShares,
            uint256 totalSupplyAssets,
            uint256 totalBorrowAssets
        );

    /// @notice Converts supply shares to underlying asset amount
    /// @param reserveId The reserve identifier
    /// @param shares The amount of supply shares to convert
    /// @return assets The equivalent amount of underlying assets
    function convertToSupplyAssets(uint256 reserveId, uint256 shares) external view returns (uint256 assets);

    /// @notice Converts borrow shares to underlying debt amount
    /// @param reserveId The reserve identifier
    /// @param shares The amount of borrow shares to convert
    /// @return assets The equivalent amount of underlying debt
    function convertToDebtAssets(uint256 reserveId, uint256 shares) external view returns (uint256 assets);

    /// @notice Returns the total number of reserves in this Spoke
    /// @return count The number of reserves
    function getReserveCount() external view returns (uint256 count);

    /// @notice Returns the reserve ID at a given index
    /// @param index The index in the reserves list
    /// @return reserveId The reserve identifier
    function getReserveId(uint256 index) external view returns (uint256 reserveId);
}
