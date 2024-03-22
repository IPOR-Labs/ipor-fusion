// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

interface IAavePriceOracle {
    /**
     * @notice Returns the asset price in the base currency
     * @param asset The address of the asset
     * @return The price of the asset
     */
    function getAssetPrice(address asset) external view returns (uint256);
}
