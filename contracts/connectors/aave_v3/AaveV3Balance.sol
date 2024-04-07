// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IBalance} from "../IBalance.sol";
import {IAavePriceOracle} from "./IAavePriceOracle.sol";
import {IAavePoolDataProvider} from "./IAavePoolDataProvider.sol";
import {AaveConstants} from "./AaveConstants.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {MarketConfigurationLib} from "../../libraries/MarketConfigurationLib.sol";

contract AaveV3Balance is IBalance {
    using SafeCast for int256;
    uint256 private constant PRICE_DECIMALS = 8;
    address private constant USD = address(0x0000000000000000000000000000000000000348);
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketIdInput) {
        MARKET_ID = marketIdInput;
    }

    function balanceOfMarket(address user) external view override returns (uint256, address) {
        bytes32[] memory assetsRaw = MarketConfigurationLib.getMarketConfiguration(MARKET_ID).substrates;

        uint256 len = assetsRaw.length;

        if (len == 0) {
            return (0, USD);
        }

        int256 balanceTemp = 0;
        int256 balanceInLoop;
        uint256 decimals;
        // @dev this value has 8 decimals
        uint256 price;
        address asset;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;

        for (uint256 i; i < len; ++i) {
            balanceInLoop = 0;
            asset = MarketConfigurationLib.bytes32ToAddress(assetsRaw[i]);
            decimals = ERC20(asset).decimals();
            price = IAavePriceOracle(AaveConstants.ETHEREUM_AAVE_PRICE_ORACLE_MAINNET).getAssetPrice(asset);

            (aTokenAddress, stableDebtTokenAddress, variableDebtTokenAddress) = IAavePoolDataProvider(
                AaveConstants.ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3_MAINNET
            ).getReserveTokensAddresses(asset);

            if (aTokenAddress != address(0)) {
                balanceInLoop += int256(ERC20(aTokenAddress).balanceOf(user));
            }
            if (stableDebtTokenAddress != address(0)) {
                balanceInLoop -= int256(ERC20(stableDebtTokenAddress).balanceOf(user));
            }
            if (variableDebtTokenAddress != address(0)) {
                balanceInLoop -= int256(ERC20(variableDebtTokenAddress).balanceOf(user));
            }

            balanceTemp += IporMath.convertToWadInt(balanceInLoop * int256(price), decimals + PRICE_DECIMALS);
        }

        return (balanceTemp.toUint256(), USD);
    }
}
