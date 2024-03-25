// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IBalances} from "../IBalances.sol";
import {IAavePriceOracle} from "./IAavePriceOracle.sol";
import {IAavePoolDataProvider} from "./IAavePoolDataProvider.sol";
import {AaveConstants} from "./AaveConstants.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

contract AaveV3Balances is IBalances {
    using SafeCast for int256;
    uint256 private constant PRICE_DECIMALS = 8;
    address private constant USD = address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);

    function balanceOfMarket(
        address[] calldata assets,
        address user
    ) external view override returns (uint256, address) {
        uint256 len = assets.length;
        if (len == 0) {
            return (0, USD);
        }

        int256 balanceTemp = 0;
        int256 balanceInLoop;
        uint256 decimals;
        // @dev this value has 8 decimals
        uint256 price;

        for (uint256 i; i < len; ++i) {
            balanceInLoop = 0;
            decimals = ERC20(assets[i]).decimals();
            price = IAavePriceOracle(AaveConstants.ETHEREUM_AAVE_PRICE_ORACLE_MAINNET).getAssetPrice(assets[i]);

            (
                address aTokenAddress,
                address stableDebtTokenAddress,
                address variableDebtTokenAddress
            ) = IAavePoolDataProvider(AaveConstants.ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3_MAINNET)
                    .getReserveTokensAddresses(assets[i]);

            if (aTokenAddress != address(0)) {
                balanceInLoop += int256(ERC20(aTokenAddress).balanceOf(user));
            }
            if (stableDebtTokenAddress != address(0)) {
                balanceInLoop -= int256(ERC20(stableDebtTokenAddress).balanceOf(user));
            }
            if (variableDebtTokenAddress != address(0)) {
                balanceInLoop -= int256(ERC20(variableDebtTokenAddress).balanceOf(user));
            }

            balanceTemp += IporMath.convertToWad(balanceInLoop * int256(price), decimals + PRICE_DECIMALS);
        }

        return (balanceTemp.toUint256(), USD);
    }
}
