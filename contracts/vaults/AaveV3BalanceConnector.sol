// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import "forge-std/console2.sol";
import "./interfaces/IPool.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IConnectorBalance} from "./IConnectorBalance.sol";
import {PriceAdapter} from "./PriceAdapter.sol";

interface IAaveProtocolDataProvider {
    function getReserveTokensAddresses(address asset)
    external
    view
    returns (
        address aTokenAddress,
        address stableDebtTokenAddress,
        address variableDebtTokenAddress
    );

    function getUserReserveData(address asset, address user)
    external
    view
    returns (
        uint256 currentATokenBalance,
        uint256 currentStableDebt,
        uint256 currentVariableDebt,
        uint256 principalStableDebt,
        uint256 scaledVariableDebt,
        uint256 stableBorrowRate,
        uint256 liquidityRate,
        uint40 stableRateLastUpdated,
        bool usageAsCollateralEnabled
    );
}

contract AaveV3BalanceConnector is IConnectorBalance {
    uint256 public immutable override marketId;
    bytes32 internal immutable _marketName;

    address public constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant wETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address public constant aaveProtocolDataProvider = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;

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
    ) external view override returns (int256) {
        console2.log("AaveV3BalanceConnector: balanceOf ENTER!!!");
        /// TODO: get supply
        /// TODO: get burrow
        /// TODO: supply - borrow
        console2.log("AaveV3BalanceConnector: underlyingAsset: ", asset);
        (
            uint256 currentATokenBalance,
            uint256 currentStableDebt,
            uint256 currentVariableDebt,
            uint256 principalStableDebt,
            uint256 scaledVariableDebt,
            uint256 stableBorrowRate,
            uint256 liquidityRate,
            uint40 stableRateLastUpdated,
            bool usageAsCollateralEnabled
        ) = IAaveProtocolDataProvider(aaveProtocolDataProvider).getUserReserveData(asset, address(this));

        console2.log("AaveV3BalanceConnector: asset: ", asset);
        console2.log("AaveV3BalanceConnector: currentATokenBalance: ", currentATokenBalance);
        console2.log("AaveV3BalanceConnector: currentStableDebt: ", currentStableDebt);
        console2.log("AaveV3BalanceConnector: currentVariableDebt: ", currentVariableDebt);
        console2.log("AaveV3BalanceConnector: principalStableDebt: ", principalStableDebt);
        console2.log("AaveV3BalanceConnector: scaledVariableDebt: ", scaledVariableDebt);
        console2.log("AaveV3BalanceConnector: stableBorrowRate: ", stableBorrowRate);
        console2.log("AaveV3BalanceConnector: liquidityRate: ", liquidityRate);
        console2.log("AaveV3BalanceConnector: stableRateLastUpdated: ", stableRateLastUpdated);
        console2.log("AaveV3BalanceConnector: usageAsCollateralEnabled: ", usageAsCollateralEnabled);

        int256 assetBalance = int256(currentATokenBalance) - int256(currentStableDebt) - int256(currentVariableDebt);

        if (assetBalance < 0) {
            console2.log("AaveV3BalanceConnector: MINUS assetBalance: ", -assetBalance);
        } else {
            console2.log("AaveV3BalanceConnector: assetBalance: ", assetBalance);
        }

        return assetBalance * int256(PriceAdapter(priceAdapter).getPrice(underlyingAsset, asset)) / 1e18;
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
