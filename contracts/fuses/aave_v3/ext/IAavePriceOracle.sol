// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

interface IAavePriceOracle {
    /**
     * @notice Returns the asset price in the base currency, which is USD
     * @param asset The address of the asset
     * @return The price is USD of the asset represented in 8 decimals
     * @dev https://docs.aave.com/developers/core-contracts/aaveoracle
     * All V3 markets use USD based oracles which return values with 8 decimals.
     */
    function getAssetPrice(address asset) external view returns (uint256);
}
