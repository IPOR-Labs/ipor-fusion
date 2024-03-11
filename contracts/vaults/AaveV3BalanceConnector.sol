// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;
import "forge-std/console2.sol";
import "./interfaces/IPool.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IConnectorBalance} from "./IConnectorBalance.sol";
import {PriceAdapter} from "./PriceAdapter.sol";

contract AaveV3BalanceConnector is IConnectorBalance {
    uint256 public immutable override marketId;
    bytes32 internal immutable _marketName;

    address public constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant wETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address public immutable priceAdapter;

    constructor(
        uint256 inputMarketId,
        bytes32 inputMarketName,
        address inputPriceAdapter
    ) {
        marketId = inputMarketId;
        _marketName = inputMarketName;
        priceAdapter = inputPriceAdapter;
    }

    function balanceOf(
        address account,
        address underlyingAsset,
        address asset
    ) external view override returns (uint256) {
        console2.log("AaveV3BalanceConnector: balanceOf...");
        /// TODO: get supply
        /// TODO: get burrow
        /// TODO: supply - borrow

        uint256 assetBalance;

        if (asset == wstETH) {
            assetBalance = IERC20(wstETH).balanceOf(account);
        } else if (asset == wETH) {
            assetBalance = IERC20(wETH).balanceOf(account);
        }

        return assetBalance * PriceAdapter(priceAdapter).getPrice(underlyingAsset, asset) / 1e18;
    }

    function getSupportedAssets()
        external
        view
        returns (address[] memory assets)
    {
        address[] memory supportedAssets = new address[](2);
        supportedAssets[0] = wstETH;
        supportedAssets[1] = wETH;
        return supportedAssets;
    }

    function isSupportedAsset(address asset) external view returns (bool) {
        if (asset == wstETH || asset == wETH) {
            return true;
        } else {
            return false;
        }
    }

    function marketName() external view returns (string memory) {
        return string(abi.encodePacked(_marketName));
    }
}
