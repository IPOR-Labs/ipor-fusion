// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IMarketBalanceFuse} from "../../fuses/IMarketBalanceFuse.sol";
import {PriceAdapter} from "./PriceAdapter.sol";

interface IAaveProtocolDataProvider {
    function getReserveTokensAddresses(
        address asset
    ) external view returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress);

    function getUserReserveData(
        address asset,
        address user
    )
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

contract AaveV3BalanceFuse is IMarketBalanceFuse {
    uint256 public immutable MARKET_ID;
    bytes32 internal immutable _MARKET_NAME;

    address public constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address public constant AAVE_PROTOCOL_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;

    address public immutable PRICE_ADAPTER;

    constructor(uint256 inputMarketId, bytes32 inputMarketName, address inputPriceAdapter) {
        MARKET_ID = inputMarketId;
        _MARKET_NAME = inputMarketName;
        PRICE_ADAPTER = inputPriceAdapter;
    }
    // todo remove solhint disable
    //solhint-disable-next-line
    function balanceOf(
        //solhint-disable-next-line
        address account
    ) external view override returns (uint256) {
        /// TODO: get supply
        /// TODO: get burrow
        /// TODO: supply - borrow
        (
            uint256 currentATokenBalance,
            uint256 currentStableDebt,
            uint256 currentVariableDebt,
            ,
            ,
            ,
            ,
            ,

        ) = IAaveProtocolDataProvider(AAVE_PROTOCOL_DATA_PROVIDER).getUserReserveData(WST_ETH, address(this));

        int256 assetBalance = int256(currentATokenBalance) - int256(currentStableDebt) - int256(currentVariableDebt);

        //        if (assetBalance < 0) {} else {}

        return uint256((assetBalance * int256(PriceAdapter(PRICE_ADAPTER).getPrice(W_ETH, WST_ETH))) / 1e18);
    }

    function getSupportedAssets() external view returns (address[] memory assets) {
        address[] memory supportedAssets = new address[](2);
        supportedAssets[0] = WST_ETH;
        supportedAssets[1] = W_ETH;
        return supportedAssets;
    }

    function isSupportedAsset(address asset) external view returns (bool) {
        if (asset == WST_ETH || asset == W_ETH) {
            return true;
        } else {
            return false;
        }
    }

    function marketName() external view returns (string memory) {
        return string(abi.encodePacked(_MARKET_NAME));
    }
}
