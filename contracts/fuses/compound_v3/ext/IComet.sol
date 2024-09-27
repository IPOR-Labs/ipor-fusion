// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

interface IComet {
    struct AssetInfo {
        uint8 offset;
        address asset;
        address priceFeed;
        uint64 scale;
        uint64 borrowCollateralFactor;
        uint64 liquidateCollateralFactor;
        uint64 liquidationFactor;
        uint128 supplyCap;
    }

    /**
     * @notice Supply an amount of asset to the protocol
     * @param asset The asset to supply
     * @param amount The quantity to supply
     */
    function supply(address asset, uint256 amount) external;

    /**
     * @notice Supply an amount of asset to dst
     * @param dst The address which will hold the balance
     * @param asset The asset to supply
     * @param amount The quantity to supply
     */
    function supplyTo(address dst, address asset, uint256 amount) external;

    /**
     * @notice Withdraw an amount of asset from the protocol
     * @param asset The asset to withdraw
     * @param amount The quantity to withdraw
     */
    function withdraw(address asset, uint256 amount) external;

    function collateralBalanceOf(address account, address asset) external view returns (uint128);

    function balanceOf(address account) external view returns (uint256);

    function borrowBalanceOf(address account) external view returns (uint256);

    function getAssetInfoByAddress(address asset) external view returns (AssetInfo memory);

    /// @dev The decimals required for a price feed, 8 decimals
    function getPrice(address priceFeed) external view returns (uint256);

    function baseToken() external view returns (address);

    function baseTokenPriceFeed() external view returns (address);
}
