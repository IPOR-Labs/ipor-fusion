// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

interface IComet {
    /**
     * @notice Supply an amount of asset to the protocol
     * @param asset The asset to supply
     * @param amount The quantity to supply
     */
    function supply(address asset, uint256 amount) external;

    /**
     * @notice Withdraw an amount of asset from the protocol
     * @param asset The asset to withdraw
     * @param amount The quantity to withdraw
     */
    function withdraw(address asset, uint256 amount) external;

    function collateralBalanceOf(address account, address asset) external view returns (uint128);

    function balanceOf(address account) external view returns (uint256);
}
