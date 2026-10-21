// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPriceFeed} from "./IPriceFeed.sol";
import {IPriceOracleMiddleware} from "../IPriceOracleMiddleware.sol";
import {ICurveStableSwapNG} from "./ext/ICurveStableSwapNG.sol";
import {CurveStableSwapNGLpMath} from "../../fuses/curve_stableswap_ng/lib/CurveStableSwapNGLpMath.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Prices one Curve StableSwap-NG LP token via the canonical, swap-invariant LP price
/// `get_virtual_price() / 1e18 * min_j(price(coins(j)))`.
/// @dev A spot pro-rata read of `balances(j)` (the previous formula here) is manipulable within a
/// single transaction by a round-trip swap: swaps conserve `D` and refund the outbound leg's
/// slippage on the return leg, so the attacker's only permanent cost is the pool fee while the
/// reported price can move by tens of percent. `get_virtual_price()` (`D / totalSupply`) is
/// swap-conserved and is protected by the pool's own read-only-reentrancy lock, so it is not movable
/// for free the same way. Taking the minimum oracle price over the pool's coins is the standard
/// conservative convention for LP pricing (worst-case peg among constituents).
/// @dev The minimum is taken over BASE-unit coin prices, not raw ones: `stored_rates()[j]` folds an
/// external rate into the coin's multiplier for `asset_type` 1 and 3 (wstETH -> stETH,
/// sUSDe -> USDe, sDAI -> DAI), so `D` - and therefore `get_virtual_price()` - is denominated in
/// each coin's base asset. See `CurveStableSwapNGLpMath`. The conversion is the identity for a coin
/// with no external rate, so pools of ordinary stablecoins are valued exactly as before.
contract CurveStableSwapNGPriceFeed is IPriceFeed {
    using SafeCast for uint256;

    uint256 private constant WAD = 1e18;

    error ZeroAddress();
    error PriceOracleMiddleware_InvalidPrice();
    error CurveStableSwapNG_InvalidTotalSupply();

    address public immutable CURVE_STABLE_SWAP_NG;
    address public immutable PRICE_ORACLE_MIDDLEWARE;
    uint256 public immutable N_COINS;
    uint256 public immutable DECIMALS_LP;
    address[] public coins;
    /// @dev ERC-20 decimals of each coin, cached alongside `coins`. Needed to separate a coin's
    /// decimal normalisation from its external rate inside `stored_rates()`; a token's decimals
    /// never change, unlike the rate itself, which is why only this half is cached.
    uint256[] public coinDecimals;

    constructor(address _curveStableSwapNG, address _priceOracleMiddleware) {
        if (_curveStableSwapNG == address(0) || _priceOracleMiddleware == address(0)) {
            revert ZeroAddress();
        }

        CURVE_STABLE_SWAP_NG = _curveStableSwapNG;
        PRICE_ORACLE_MIDDLEWARE = _priceOracleMiddleware;
        N_COINS = ICurveStableSwapNG(CURVE_STABLE_SWAP_NG).N_COINS();
        DECIMALS_LP = ICurveStableSwapNG(CURVE_STABLE_SWAP_NG).decimals();
        address coin;
        for (uint256 i = 0; i < N_COINS; i++) {
            coin = ICurveStableSwapNG(CURVE_STABLE_SWAP_NG).coins(i);
            coins.push(coin);
            coinDecimals.push(ERC20(coin).decimals());
        }
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        /// @dev Defensive guard, kept from the pre-existing interface even though `get_virtual_price()`
        /// would itself revert (divide-by-zero) on a zero-supply pool: gives a clear, named error
        /// instead of an opaque low-level revert from the pool.
        if (ICurveStableSwapNG(CURVE_STABLE_SWAP_NG).totalSupply() == 0) {
            revert CurveStableSwapNG_InvalidTotalSupply();
        }

        uint256 minCoinPriceWad = type(uint256).max;
        IPriceOracleMiddleware priceOracleMiddleware = IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE);

        /// @dev Read live: for `asset_type == 1` the rate comes from a rate oracle and for
        /// `asset_type == 3` from `convertToAssets`, so it moves between calls.
        uint256[] memory storedRates = ICurveStableSwapNG(CURVE_STABLE_SWAP_NG).stored_rates();
        CurveStableSwapNGLpMath.validateStoredRatesLength(storedRates.length, N_COINS);

        uint256 coinPrice;
        uint256 coinPriceDecimals;
        uint256 coinPriceWad;
        for (uint256 i; i < N_COINS; i++) {
            (coinPrice, coinPriceDecimals) = priceOracleMiddleware.getAssetPrice(coins[i]);
            if (coinPrice == 0) {
                revert PriceOracleMiddleware_InvalidPrice();
            }

            /// @dev Normalise every coin's price to WAD (18 decimals) BEFORE comparing, so that
            /// coins priced through feeds with different `coinPriceDecimals` are compared on the
            /// same basis, then divide out the coin's external rate so the price is expressed in
            /// the BASE-asset units `D` - and therefore `get_virtual_price()` - is built from. The
            /// second step is the identity for a coin with no external rate; without it a pool of
            /// rate-bearing coins (sUSDe, sDAI, wstETH, ...) is over-valued by the smallest rate.
            coinPriceWad = CurveStableSwapNGLpMath.toBaseUnitPriceWad(
                IporMath.convertToWad(coinPrice, coinPriceDecimals),
                coinDecimals[i],
                storedRates[i],
                i
            );
            if (coinPriceWad < minCoinPriceWad) {
                minCoinPriceWad = coinPriceWad;
            }
        }

        uint256 totalPrice = Math.mulDiv(
            ICurveStableSwapNG(CURVE_STABLE_SWAP_NG).get_virtual_price(),
            minCoinPriceWad,
            WAD
        );

        return (0, totalPrice.toInt256(), 0, 0, 0);
    }

    function decimals() external view override returns (uint8) {
        return 18;
    }
}
