// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IFxPoolManager
/// @notice Minimal interface of the f(x) Protocol v2 PoolManager used by the FxMint fuses
interface IFxPoolManager {
    /// @notice Opens or changes a position. positionId 0 opens a new one (position NFT minted to msg.sender).
    /// @param pool The f(x) long pool
    /// @param positionId The position id (0 = open)
    /// @param newColl Collateral delta in collateral token units (positive add, negative withdraw, type(int256).min all)
    /// @param newDebt Debt delta in fxUSD (positive borrow, negative repay, type(int256).min all)
    /// @return The position id
    function operate(address pool, uint256 positionId, int256 newColl, int256 newDebt) external returns (uint256);

    /// @notice Scaling factor that turns a collateral token amount into the pool's 18-decimal raw collateral
    function getTokenScalingFactor(address token) external view returns (uint256);
}
