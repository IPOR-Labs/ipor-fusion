// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

/// @title IAaveV4Hub
/// @notice Minimal Aave V4 Hub interface: the liquidity the Hub can release, used to cap instant withdrawals
interface IAaveV4Hub {
    /// @notice Liquidity of the asset that the Hub holds and can release now (in the asset's decimals)
    /// @param assetId Hub asset id (`IAaveV4Spoke.Reserve.assetId`)
    function getAssetLiquidity(uint256 assetId) external view returns (uint256);
}
