// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMarketBalanceFuse} from "./../IMarketBalanceFuse.sol";
import {IporMath} from "./../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "./../../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "./../../libraries/PlasmaVaultConfigLib.sol";
import {ICurveStableswapNG} from "./ext/ICurveStableswapNG.sol";
import {IPriceOracleMiddleware} from "./../../price_oracle/IPriceOracleMiddleware.sol";

/// @notice Balance Fuse for Curve StableswapNG pools using pro-rata share valuation
contract CurveStableswapNGSingleSideBalanceFuse is IMarketBalanceFuse {
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /// @return The balance of the Plasma Vault in the market in USD, represented in 18 decimals
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = assetsRaw.length;

        if (len == 0) {
            return 0;
        }

        uint256 balance;
        address plasmaVault = address(this);
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        address lpTokenAddress;
        uint256 lpTokenBalance; 
        uint256 totalSupply ;
        uint256 nCoins;
        address coin;
        uint256 coinAmount;
        uint256 coinPrice;
        uint256 coinPriceDecimals;
        
        for (uint256 i; i < len; ++i) {
            lpTokenAddress = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            lpTokenBalance = ERC20(lpTokenAddress).balanceOf(plasmaVault);
            if (lpTokenBalance == 0) {
                continue;
            }

            totalSupply = ICurveStableswapNG(lpTokenAddress).totalSupply();
            if (totalSupply == 0) {
                continue;
            }

            nCoins = ICurveStableswapNG(lpTokenAddress).N_COINS();
            for (uint256 j; j < nCoins; ++j) {
                
                coin = ICurveStableswapNG(lpTokenAddress).coins(j);
                
                coinAmount = Math.mulDiv(
                    ICurveStableswapNG(lpTokenAddress).balances(j),
                    lpTokenBalance,
                    totalSupply
                );


                    ( coinPrice,  coinPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
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
