// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface ISavingsDai {
    function balanceOf(address owner) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256);

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
}
