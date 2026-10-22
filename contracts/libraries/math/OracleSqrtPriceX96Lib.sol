// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";

/// @title OracleSqrtPriceX96Lib
/// @notice Derives a Uniswap V3 style `sqrtPriceX96` (Q64.96) of a token0/token1 pool from oracle prices
/// @dev Shared by the Aerodrome and Velodrome Slipstream balance fuses. Supports the full Q64.96 range:
///      for realistic prices and decimals it reverts only when the oracle-implied raw
///      price `P = token1 / token0` is `>= 2^128` (i.e. `sqrt(P) * 2^96` no longer fits `uint160`).
library OracleSqrtPriceX96Lib {
    /// @notice Computes the oracle-implied sqrt price of a pool
    /// @dev `getAssetPrice` returns `(price, priceDecimals)` = USD value of one WHOLE token scaled by
    ///      `10^priceDecimals`. With `p0`/`d0` for token0, `p1`/`d1` for token1 and raw-unit token decimals
    ///      `t0`/`t1`, the raw token1-per-token0 price is `P = (p0 * 10^(d1+t1)) / (p1 * 10^(d0+t0))`
    ///      (numerator is `price0`, denominator is `price1`).
    ///      The net decimals scale is applied to the numerator or the denominator BEFORE the single
    ///      `mulDiv` (checked multiplication), so for realistic prices and decimals no intermediate
    ///      value overflows and the call reverts only when the result no longer fits Q64.96.
    /// @param token0_ The pool's token0 address
    /// @param token1_ The pool's token1 address
    /// @param oracle_ The address of the price oracle middleware
    /// @return The oracle-implied sqrt price of the pool, in Q64.96 format
    function fromOracle(address token0_, address token1_, address oracle_) internal view returns (uint160) {
        (uint256 price0, uint256 priceDecimals0) = IPriceOracleMiddleware(oracle_).getAssetPrice(token0_);
        (uint256 price1, uint256 priceDecimals1) = IPriceOracleMiddleware(oracle_).getAssetPrice(token1_);

        uint256 numExp = priceDecimals1 + IERC20Metadata(token1_).decimals();
        uint256 denExp = priceDecimals0 + IERC20Metadata(token0_).decimals();

        uint256 num = price0;
        uint256 den = price1;

        // Apply the net decimals adjustment 10^(numExp - denExp) on whichever side keeps the exponent
        // non-negative, so a negative power of ten is never needed.
        if (numExp >= denExp) {
            num *= 10 ** (numExp - denExp);
        } else {
            den *= 10 ** (denExp - numExp);
        }

        return fromRatio(num, den);
    }

    /// @notice Computes the Q64.96 sqrt price of a raw ratio: exactly floor(sqrt(num / den) * 2^96) for P < 2^64; for P >= 2^64 the result is floor(sqrt(floor(num * 2^128 / den))) << 32, at most 2^32 units (relative error <= 2^-96) below the exact floor
    /// @dev `(num >> 64) < den` is equivalent to `num * 2^192 / den < 2^256`, i.e. P < 2^64: the first branch
    ///      uses the full 192-bit shift (floor of the exact value). Otherwise `sqrt(num * 2^128 / den) << 32` is used,
    ///      which keeps at least 96 significant bits: the result is rounded down by a negligible amount
    ///      (relative error below 2^-96), not an exact floor. `mulDiv` reverts with `MathOverflowedMulDiv`
    ///      only when P >= 2^128, the end of the Q64.96 range.
    /// @param num_ The numerator of the raw price ratio
    /// @param den_ The denominator of the raw price ratio (must be non-zero)
    /// @return The sqrt price in Q64.96 format
    function fromRatio(uint256 num_, uint256 den_) internal pure returns (uint160) {
        if ((num_ >> 64) < den_) {
            return SafeCast.toUint160(Math.sqrt(Math.mulDiv(num_, 1 << 192, den_)));
        }
        return SafeCast.toUint160(Math.sqrt(Math.mulDiv(num_, 1 << 128, den_)) << 32);
    }
}
