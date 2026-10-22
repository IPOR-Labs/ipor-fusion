// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMarketBalanceFuse} from "./../IMarketBalanceFuse.sol";
import {IporMath} from "./../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "./../../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "./../../libraries/PlasmaVaultConfigLib.sol";
import {ICurveStableswapNG} from "./ext/ICurveStableswapNG.sol";
import {CurveStableSwapNGLpMath} from "./lib/CurveStableSwapNGLpMath.sol";
import {IPriceOracleMiddleware} from "./../../price_oracle/IPriceOracleMiddleware.sol";

/// @notice Balance Fuse for Curve StableswapNG pools using the canonical, swap-invariant LP price
/// `lpTokenBalance * get_virtual_price() / 1e18 * min_j(price(coins(j)))`.
/// @dev A spot pro-rata read of `balances(j)` (the previous formula here) is manipulable within a
/// single transaction by a round-trip swap: swaps conserve `D` and refund the outbound leg's
/// slippage on the return leg, so the attacker's only permanent cost is the pool fee while the
/// reported NAV can move by tens of percent. `get_virtual_price()` (`D / totalSupply`) is
/// swap-conserved and is protected by the pool's own read-only-reentrancy lock, so it is not movable
/// for free the same way. Taking the minimum oracle price over the pool's coins is the standard
/// conservative convention for LP pricing (worst-case peg among constituents).
/// @dev The minimum is taken over BASE-unit coin prices, not raw ones: `stored_rates()[j]` folds an
/// external rate into the coin's multiplier for `asset_type` 1 and 3 (wstETH -> stETH,
/// sUSDe -> USDe, sDAI -> DAI), so `D` - and therefore `get_virtual_price()` - is denominated in
/// each coin's base asset. See `CurveStableSwapNGLpMath`. The conversion is the identity for a coin
/// with no external rate, so pools of ordinary stablecoins are valued exactly as before.
/// @dev Precondition: every coin of every granted pool substrate must be a supported asset in the
/// price oracle middleware, or `getAssetPrice` reverts and takes `balanceOf()` — hence
/// `totalAssets()` and all deposits/withdrawals — down with it. Configuration precondition on
/// substrate grants; this stateless fuse must not fail open around it.
contract CurveStableswapNGSingleSideBalanceFuse is IMarketBalanceFuse {
    uint256 private constant WAD = 1e18;

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

        for (uint256 i; i < len; ++i) {
            lpTokenAddress = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            lpTokenBalance = ERC20(lpTokenAddress).balanceOf(plasmaVault);
            if (lpTokenBalance == 0) {
                continue;
            }

            uint256 lpValueInPegUnitsWad = Math.mulDiv(
                lpTokenBalance,
                ICurveStableswapNG(lpTokenAddress).get_virtual_price(),
                WAD
            );

            balance += Math.mulDiv(lpValueInPegUnitsWad, _minCoinPriceWad(lpTokenAddress, priceOracleMiddleware), WAD);
        }
        return balance;
    }

    /// @dev Returns the minimum coin price over all coins of `lpTokenAddress_`, WAD-normalised AND
    /// converted to the basis `get_virtual_price()` is denominated in (see
    /// `CurveStableSwapNGLpMath`). Isolated in its own function so the inner loop's locals do not
    /// add to `balanceOf()`'s stack frame (this file must stay `via_ir`-free; scoping, not a
    /// compiler flag, resolves "stack too deep" here).
    function _minCoinPriceWad(
        address lpTokenAddress_,
        address priceOracleMiddleware_
    ) private view returns (uint256 minCoinPriceWad) {
        uint256 nCoins = ICurveStableswapNG(lpTokenAddress_).N_COINS();
        uint256[] memory storedRates = ICurveStableswapNG(lpTokenAddress_).stored_rates();
        CurveStableSwapNGLpMath.validateStoredRatesLength(storedRates.length, nCoins);

        minCoinPriceWad = type(uint256).max;

        address coin;
        uint256 coinPrice;
        uint256 coinPriceDecimals;
        uint256 coinPriceWad;

        for (uint256 j; j < nCoins; ++j) {
            coin = ICurveStableswapNG(lpTokenAddress_).coins(j);

            (coinPrice, coinPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(coin);

            /// @dev Normalise every coin's price to WAD (18 decimals) BEFORE comparing, so that
            /// coins priced through feeds with different `coinPriceDecimals` are compared on the
            /// same basis, then divide out the coin's external rate so the price is expressed in
            /// the BASE-asset units `D` - and therefore `get_virtual_price()` - is built from. The
            /// second step is the identity for a coin with no external rate; without it a pool of
            /// rate-bearing coins (sUSDe, sDAI, wstETH, ...) is over-valued by the smallest rate.
            coinPriceWad = CurveStableSwapNGLpMath.toBaseUnitPriceWad(
                IporMath.convertToWad(coinPrice, coinPriceDecimals),
                ERC20(coin).decimals(),
                storedRates[j],
                j
            );

            if (coinPriceWad < minCoinPriceWad) {
                minCoinPriceWad = coinPriceWad;
            }
        }
    }
}
