// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMarketBalanceFuse} from "./../IMarketBalanceFuse.sol";
import {IporMath} from "./../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "./../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "./../../libraries/PlasmaVaultLib.sol";
import {ILiquidityGaugeV6} from "./ext/ILiquidityGaugeV6.sol";
import {ICurveStableswapNG} from "./../curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {IPriceOracleMiddleware} from "./../../price_oracle/IPriceOracleMiddleware.sol";

/// @title Balance Fuse for Curve LiquidityGaugeV6 using pro-rata share valuation
/// @notice Values staked LP tokens by computing the pro-rata share of each pool coin,
///         avoiding calc_withdraw_one_coin which is vulnerable to price manipulation.
contract CurveLiquidityGaugeV6BalanceFuse is IMarketBalanceFuse {
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketIdInput_) {
        MARKET_ID = marketIdInput_;
    }

    /// @notice Returns the USD value of LP tokens staked in Curve gauges (rewards excluded)
    /// @return The balance in USD, represented in 18 decimals
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = substrates.length;

        if (len == 0) {
            return 0;
        }

        uint256 balance;
        address plasmaVault = address(this);
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        address stakedLpTokenAddress;
        address lpTokenAddress;
        uint256 stakedBalance;
        uint256 totalSupply;
        uint256 nCoins;
        address coin;
        uint256 coinAmount;
        uint256 coinPrice;
        uint256 coinPriceDecimals;

        for (uint256 i; i < len; ++i) {
            stakedLpTokenAddress = PlasmaVaultConfigLib.bytes32ToAddress(substrates[i]);
            stakedBalance = ERC20(stakedLpTokenAddress).balanceOf(plasmaVault);
            if (stakedBalance == 0) {
                continue;
            }

            lpTokenAddress = ILiquidityGaugeV6(stakedLpTokenAddress).lp_token();
            totalSupply = ICurveStableswapNG(lpTokenAddress).totalSupply();
            if (totalSupply == 0) {
                continue;
            }

            nCoins = ICurveStableswapNG(lpTokenAddress).N_COINS();
            for (uint256 j; j < nCoins; ++j) {
                coin = ICurveStableswapNG(lpTokenAddress).coins(j);

                coinAmount = Math.mulDiv(
                    ICurveStableswapNG(lpTokenAddress).balances(j),
                    stakedBalance,
                    totalSupply
                );

                (coinPrice, coinPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
                    .getAssetPrice(coin);

                balance += IporMath.convertToWad(
                    coinAmount * coinPrice,
                    ERC20(coin).decimals() + coinPriceDecimals
                );
            }
        }
        return balance;
    }
}
