// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

//TODO: upgradeable
contract PriceAdapter {


    /// @dev always return in 18 decimals
    function getPrice(address underlyingAsset, address asset) external view returns (uint256) {
        return 1e18;
    }
}