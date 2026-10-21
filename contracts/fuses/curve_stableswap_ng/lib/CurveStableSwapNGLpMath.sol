// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CurveStableSwapNGLpMath
/// @notice Shared arithmetic for valuing a Curve StableSwap-NG LP token at the swap-invariant
///         virtual price. Three call sites price the very same LP token - the gauge balance fuse,
///         the single-side balance fuse and the LP price feed - and MUST agree exactly, so the part
///         of the formula that is easy to get subtly wrong lives here instead of being copied.
/// @dev The LP price is `get_virtual_price() / 1e18 * min_j(basePrice_j)`. `get_virtual_price()` is
///      `D / totalSupply`, and `D` is built from `xp[j] = balances[j] * stored_rates()[j] / 1e18`.
///
///      `stored_rates()[j]` is `10**(36 - dec_j) * rate_j / 1e18`, where `rate_j` is an EXTERNAL
///      rate baked in by the pool: `1e18` for a plain coin, a rate-oracle answer for
///      `asset_type == 1` (e.g. wstETH -> stETH) and `convertToAssets` for `asset_type == 3`
///      (e.g. sUSDe -> USDe, sDAI -> DAI). `D` is therefore denominated in units of each coin's
///      BASE asset, not in units of the coin itself.
///
///      Multiplying `D` by the coin's own USD price is only correct when `rate_j == 1`. For a pool
///      in which every coin carries a rate above 1 (e.g. sDAI/sUSDe or wstETH/rETH) the LP would be
///      over-valued by the smallest rate - on the order of 15-25%, permanently and without any
///      attacker. The opposite error cannot occur. `toBaseUnitPriceWad` removes `rate_j` by
///      dividing the coin's WAD price by it: `price_j * 10**(36 - dec_j) / stored_rates_j`. For a
///      plain coin `stored_rates_j == 10**(36 - dec_j)`, so the conversion is the identity and
///      pools of ordinary stablecoins are unaffected.
library CurveStableSwapNGLpMath {
    /// @dev Exponent StableSwap-NG normalises coin balances to: `stored_rates()[j]` for a coin with
    ///      no external rate is exactly `10**(36 - dec_j)`.
    uint256 private constant RATE_EXPONENT_BASE = 36;

    error CurveStableSwapNGLpMathZeroStoredRate(uint256 coinIndex);
    error CurveStableSwapNGLpMathUnsupportedDecimals(uint256 coinIndex, uint256 coinDecimals);
    error CurveStableSwapNGLpMathStoredRatesLengthMismatch(uint256 storedRatesLength, uint256 nCoins);

    /// @notice Reject a `stored_rates()` answer that does not line up with the pool's coin count
    /// @dev Indexing `stored_rates()` by the coin index is only meaningful when the two arrays have
    ///      the same length; a mismatch means the pool is not the StableSwap-NG this math assumes,
    ///      so it fails closed rather than pricing against an arbitrary rate.
    /// @param storedRatesLength_ Length of the array returned by `stored_rates()`
    /// @param nCoins_ Pool's `N_COINS()`
    function validateStoredRatesLength(uint256 storedRatesLength_, uint256 nCoins_) internal pure {
        if (storedRatesLength_ != nCoins_) {
            revert CurveStableSwapNGLpMathStoredRatesLengthMismatch(storedRatesLength_, nCoins_);
        }
    }

    /// @notice Convert a coin's WAD USD price into the basis `get_virtual_price()` is denominated in
    /// @dev Identity for a coin with no external rate. See the contract-level `@dev` for why the
    ///      conversion is needed at all.
    /// @param coinPriceWad_ Coin price in USD, normalised to 18 decimals
    /// @param coinDecimals_ Coin's own ERC-20 decimals
    /// @param storedRate_ `stored_rates()[coinIndex_]` read live from the pool
    /// @param coinIndex_ Coin index, carried only so a revert names the offending coin
    /// @return Price of one BASE unit of the coin, in USD, normalised to 18 decimals
    function toBaseUnitPriceWad(
        uint256 coinPriceWad_,
        uint256 coinDecimals_,
        uint256 storedRate_,
        uint256 coinIndex_
    ) internal pure returns (uint256) {
        if (storedRate_ == 0) {
            revert CurveStableSwapNGLpMathZeroStoredRate(coinIndex_);
        }

        /// @dev StableSwap-NG itself rejects coins with more than 18 decimals, so this is
        ///      unreachable on a well-formed pool; it guards the `10 **` exponent from underflowing
        ///      rather than silently pricing against a wrapped value.
        if (coinDecimals_ > RATE_EXPONENT_BASE) {
            revert CurveStableSwapNGLpMathUnsupportedDecimals(coinIndex_, coinDecimals_);
        }

        return Math.mulDiv(coinPriceWad_, 10 ** (RATE_EXPONENT_BASE - coinDecimals_), storedRate_);
    }
}
