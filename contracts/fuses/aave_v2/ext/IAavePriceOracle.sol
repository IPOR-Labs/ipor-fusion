// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface IAavePriceOracle {
    /**
     * @notice Returns the asset price in the base currency
     * @param asset The address of the asset
     * @return The price of the asset
     * @dev address on Ethereum Mainnet 0x54586bE62E3c3580375aE3723C145253060Ca0C2
     * @dev https://docs.aave.com/developers/core-contracts/aaveoracle
     */
    function getAssetPrice(address asset) external view returns (uint256);
}
