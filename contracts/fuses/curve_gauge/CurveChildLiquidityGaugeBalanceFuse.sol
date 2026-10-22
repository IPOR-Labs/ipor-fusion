// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMarketBalanceFuse} from "./../IMarketBalanceFuse.sol";
import {IporMath} from "./../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "./../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "./../../libraries/PlasmaVaultLib.sol";
import {IChildLiquidityGauge} from "./ext/IChildLiquidityGauge.sol";
import {ICurveStableswapNG} from "./../curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {CurveStableSwapNGLpMath} from "./../curve_stableswap_ng/lib/CurveStableSwapNGLpMath.sol";
import {IPriceOracleMiddleware} from "./../../price_oracle/IPriceOracleMiddleware.sol";

contract CurveChildLiquidityGaugeBalanceFuse is IMarketBalanceFuse {
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketIdInput_) {
        MARKET_ID = marketIdInput_;
    }
    /// @dev 18-decimal fixed point unit used for `get_virtual_price()` and for the WAD-normalised
    /// coin prices below.
    uint256 private constant WAD = 1e18;

    /// @notice Returns the value of the LP tokens staked in the Curve pool
    /// @notice Rewards are not included here
    /// @notice Value of the staked LP (the staked gauge token is 1:1 with the underlying Curve LP)
    /// is the canonical, swap-invariant StableSwap LP price:
    /// `stakedLPTokenBalance * get_virtual_price() / 1e18 * min_j(price(coins(j)))`.
    /// `get_virtual_price()` is `D / totalSupply` (swap-conserved, protected by the pool's own
    /// read-only-reentrancy lock) and is therefore not movable for free by a same-block round-trip
    /// swap, unlike a spot pro-rata read of `balances(j)`. Taking the minimum oracle price over the
    /// pool's coins is the standard conservative convention for LP pricing: it prices the LP at the
    /// worst-case peg among its constituents instead of assuming every coin is exactly at par.
    /// @dev The minimum is taken over BASE-unit coin prices, not raw ones: `stored_rates()[j]` folds an
    /// external rate into the coin's multiplier for `asset_type` 1 and 3 (wstETH -> stETH,
    /// sUSDe -> USDe, sDAI -> DAI), so `D` - and therefore `get_virtual_price()` - is denominated in
    /// each coin's base asset. See `CurveStableSwapNGLpMath`. The conversion is the identity for a coin
    /// with no external rate, so pools of ordinary stablecoins are valued exactly as before.
    /// @dev Precondition: every coin of every granted pool substrate must be a supported asset in
    /// the price oracle middleware. If any coin is unsupported, `getAssetPrice` reverts, so
    /// `balanceOf()` reverts, which takes `totalAssets()` — and therefore all vault deposits and
    /// withdrawals — down with it. This is a configuration precondition on substrate grants, not
    /// something this (stateless, delegatecall) fuse can police; do not add a fail-open catch here.
    /// @return balance_ Plasma Vault balance
    function balanceOf() external view override returns (uint256) {
        /// @notice substrates below are the Curve staked LP tokens
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = substrates.length;

        if (len == 0) {
            return 0;
        }

        uint256 balance;
        address plasmaVault = address(this);
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        address stakedLpTokenAddress;
        address lpTokenAddress; /// @dev Curve LP token
        uint256 stakedLPTokenBalance;

        for (uint256 i; i < len; ++i) {
            stakedLpTokenAddress = PlasmaVaultConfigLib.bytes32ToAddress(substrates[i]);
            lpTokenAddress = IChildLiquidityGauge(stakedLpTokenAddress).lp_token();
            stakedLPTokenBalance = ERC20(stakedLpTokenAddress).balanceOf(plasmaVault);

            if (stakedLPTokenBalance == 0) {
                continue;
            }

            /// @dev `lpValueInPegUnitsWad` is the staked LP's value in WAD units under the
            /// assumption that every pool coin is exactly at its $1 peg (i.e. `D`-equivalent value);
            /// multiplying by the minimum WAD-normalised oracle price converts that into an actual,
            /// conservative USD (WAD) value.
            uint256 lpValueInPegUnitsWad = Math.mulDiv(
                stakedLPTokenBalance,
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
