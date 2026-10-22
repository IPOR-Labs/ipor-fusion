// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Input bundle for `SolidlyFairReserveLib.fairReserves`
/// @dev Passed as a memory struct rather than as loose arguments so that call sites inside the
///      balance fuses stay within the EVM's 16-slot stack window without `via_ir`.
/// @param reserve0 Live raw reserve of token0
/// @param reserve1 Live raw reserve of token1
/// @param price0Wad USD value of one whole token0, in WAD
/// @param price1Wad USD value of one whole token1, in WAD
/// @param decimals0 ERC20 decimals of token0
/// @param decimals1 ERC20 decimals of token1
/// @param stable True for the stable invariant, false for the constant-product invariant
struct SolidlyFairReserveInput {
    uint256 reserve0;
    uint256 reserve1;
    uint256 price0Wad;
    uint256 price1Wad;
    uint256 decimals0;
    uint256 decimals1;
    bool stable;
}

/// @title SolidlyFairReserveLib
/// @notice Derives the oracle-consistent ("fair") reserves of a Solidly-style AMM pool
///         (Aerodrome / Velodrome v2 and forks) so that LP positions can be valued without
///         reading the pool's instantaneous, single-block-manipulable reserve composition.
/// @dev Security rationale. Valuing an LP position as `share * liveReserve_i * oraclePrice_i`
///      takes the *quantities* from the pool and the *prices* from an independent oracle. For a
///      convex AMM invariant the basket value measured at fixed external prices is minimised at
///      the oracle-consistent composition and rises without bound as the pool is pushed away from
///      it, so a same-transaction round-trip swap (fundable with a flash loan) inflates the
///      reported value while the vault's holdings are unchanged.
///
///      This library removes the root cause: it returns the point `(X, Y)` on the pool's *live*
///      invariant whose marginal internal price equals the oracle price ratio. Because a swap
///      moves reserves along the invariant, `(X, Y)` - and therefore the reported value - is
///      unchanged by it, up to the fee leakage the swap causes in the invariant constant itself
///      (order of the pool's swap fee, i.e. basis points, instead of an unbounded factor).
///
///      The invariant constant is intentionally taken from the live reserves. In Solidly pools the
///      swap fee is skimmed to the external `PoolFees` contract before the invariant check, so a
///      swap leaves the constant changed only by that fee leakage.
///
///      The library never reverts on economically meaningless input: degenerate cases (a zero
///      reserve, a zero price, a price ratio so extreme it underflows WAD) fall back to the live
///      reserves, because this code runs on the balance path and a revert there would propagate
///      into `totalAssets()` and brick vault deposits and withdrawals.
/// @author IPOR Labs
library SolidlyFairReserveLib {
    /// @dev 18-decimals fixed point one.
    uint256 private constant WAD = 1e18;

    /// @dev Rescales `sqrt(k_scaled)` back into `x^2` units, see `_majorLeg`.
    uint256 private constant SQRT_K_SCALE = 1e27;

    /// @dev Number of bisection steps used to invert the stable-pool marginal price. The search
    ///      interval is `[0, WAD]`, so 60 halvings narrow it below one wei (2^60 > 1e18).
    uint256 private constant RATIO_SEARCH_STEPS = 60;

    /// @notice Rescales an oracle price to 18 decimals
    /// @dev `IPriceOracleMiddleware.getAssetPrice` returns the USD value of one WHOLE token scaled
    ///      by `10 ** priceDecimals_`. Both branches use a non-negative exponent so no negative
    ///      power of ten is ever needed.
    /// @param price_ The raw price returned by the oracle
    /// @param priceDecimals_ The number of decimals the raw price is scaled by
    /// @return The USD value of one whole token, in WAD (18 decimals)
    function priceToWad(uint256 price_, uint256 priceDecimals_) internal pure returns (uint256) {
        if (priceDecimals_ == 18) {
            return price_;
        }

        if (priceDecimals_ < 18) {
            return price_ * (10 ** (18 - priceDecimals_));
        }

        return price_ / (10 ** (priceDecimals_ - 18));
    }

    /// @notice Returns the oracle-consistent reserves of a Solidly pool
    /// @dev Volatile pools (`x * y = k`) have a closed form; stable pools (`x^3 * y + x * y^3 = k`
    ///      on 1e18-normalised balances, exactly the normalisation the pool's own `_k` uses) are
    ///      solved numerically. The returned values are raw token units, directly substitutable for
    ///      the values returned by `IPool.getReserves()`.
    /// @param input_ The live reserves, oracle prices (WAD), token decimals and invariant selector
    /// @return fairReserve0 Oracle-consistent raw reserve of token0
    /// @return fairReserve1 Oracle-consistent raw reserve of token1
    function fairReserves(
        SolidlyFairReserveInput memory input_
    ) internal pure returns (uint256 fairReserve0, uint256 fairReserve1) {
        if (input_.reserve0 == 0 || input_.reserve1 == 0 || input_.price0Wad == 0 || input_.price1Wad == 0) {
            return (input_.reserve0, input_.reserve1);
        }

        if (input_.stable) {
            return
                _fairReservesStable(
                    input_.reserve0,
                    input_.reserve1,
                    10 ** input_.decimals0,
                    10 ** input_.decimals1,
                    Math.mulDiv(input_.price0Wad, WAD, input_.price1Wad)
                );
        }

        return
            _fairReservesVolatile(
                input_.reserve0,
                input_.reserve1,
                input_.price0Wad,
                input_.price1Wad,
                10 ** input_.decimals0,
                10 ** input_.decimals1
            );
    }

    /// @notice Fair reserves of a constant-product pool
    /// @dev Minimising `X * w0 + Y * w1` on `X * Y = k`, where `w_i` is the USD value of one RAW
    ///      unit of token i, gives `X = sqrt(k * w1 / w0)` and `Y = k / X`. Substituting
    ///      `w_i = price_iWad / scale_i` yields
    ///      `X^2 = k * price1Wad * scale0 / (price0Wad * scale1)`,
    ///      evaluated with a single `Math.mulDiv` so the numerator is carried at 512-bit precision
    ///      and no intermediate rounding is introduced.
    /// @param reserve0_ Live raw reserve of token0
    /// @param reserve1_ Live raw reserve of token1
    /// @param price0Wad_ USD value of one whole token0, in WAD
    /// @param price1Wad_ USD value of one whole token1, in WAD
    /// @param scale0_ `10 ** decimals0`
    /// @param scale1_ `10 ** decimals1`
    /// @return fairReserve0 Oracle-consistent raw reserve of token0
    /// @return fairReserve1 Oracle-consistent raw reserve of token1
    function _fairReservesVolatile(
        uint256 reserve0_,
        uint256 reserve1_,
        uint256 price0Wad_,
        uint256 price1Wad_,
        uint256 scale0_,
        uint256 scale1_
    ) private pure returns (uint256 fairReserve0, uint256 fairReserve1) {
        uint256 invariant = Math.mulDiv(reserve0_, reserve1_, 1);

        fairReserve0 = Math.sqrt(Math.mulDiv(invariant, price1Wad_ * scale0_, price0Wad_ * scale1_));

        if (fairReserve0 == 0) {
            return (reserve0_, reserve1_);
        }

        fairReserve1 = invariant / fairReserve0;

        if (fairReserve1 == 0) {
            return (reserve0_, reserve1_);
        }
    }

    /// @notice Fair reserves of a Solidly stable pool
    /// @dev Work in the pool's own normalisation `x = reserve0 * 1e18 / 10 ** decimals0` (likewise
    ///      for y), where the invariant is `f(x, y) = x^3 * y + x * y^3 = k`.
    ///
    ///      With `r = y / x` the marginal price of one whole token0 in whole token1 is
    ///        `g(r) = f_x / f_y = (r^3 + 3r) / (3r^2 + 1)`,
    ///      which is strictly increasing on `(0, inf)` with `g(1) = 1` and `g(1 / r) = 1 / g(r)`.
    ///      That reciprocal symmetry, together with the symmetry of `f` itself in `(x, y)`, lets us
    ///      always solve in the orientation where the target price is <= 1 - so the sought ratio
    ///      lies in `(0, 1]` and a bisection over `[0, WAD]` is exact - and swap the resulting pair
    ///      back afterwards.
    /// @param reserve0_ Live raw reserve of token0
    /// @param reserve1_ Live raw reserve of token1
    /// @param scale0_ `10 ** decimals0`
    /// @param scale1_ `10 ** decimals1`
    /// @param targetPrice_ Price of one whole token0 expressed in whole token1, in WAD
    /// @return fairReserve0 Oracle-consistent raw reserve of token0
    /// @return fairReserve1 Oracle-consistent raw reserve of token1
    function _fairReservesStable(
        uint256 reserve0_,
        uint256 reserve1_,
        uint256 scale0_,
        uint256 scale1_,
        uint256 targetPrice_
    ) private pure returns (uint256 fairReserve0, uint256 fairReserve1) {
        uint256 invariant = _invariant(Math.mulDiv(reserve0_, WAD, scale0_), Math.mulDiv(reserve1_, WAD, scale1_));

        if (invariant == 0) {
            return (reserve0_, reserve1_);
        }

        bool swapped = targetPrice_ > WAD;

        if (swapped) {
            targetPrice_ = Math.mulDiv(WAD, WAD, targetPrice_);
        }

        if (targetPrice_ == 0) {
            return (reserve0_, reserve1_);
        }

        uint256 ratio = _solveRatio(targetPrice_);

        if (ratio == 0) {
            return (reserve0_, reserve1_);
        }

        uint256 majorLeg = _majorLeg(invariant, ratio);
        uint256 minorLeg = Math.mulDiv(majorLeg, ratio, WAD);

        if (minorLeg == 0) {
            return (reserve0_, reserve1_);
        }

        fairReserve0 = Math.mulDiv(swapped ? minorLeg : majorLeg, scale0_, WAD);
        fairReserve1 = Math.mulDiv(swapped ? majorLeg : minorLeg, scale1_, WAD);

        if (fairReserve0 == 0 || fairReserve1 == 0) {
            return (reserve0_, reserve1_);
        }
    }

    /// @notice The larger normalised leg of the fair composition
    /// @dev From `f = x^4 * (r + r^3) = k_real` and the pool's scaled constant
    ///      `k_scaled = k_real / 1e54` (the three divisions by 1e18 in `_invariant`):
    ///        `x^2 = sqrt(k_real / (r + r^3)) = sqrt(k_scaled) * 1e27 * WAD / sqrt(qWad * WAD)`,
    ///      with `qWad = (r + r^3) * 1e18`. Splitting the fourth root into two square roots this way
    ///      keeps every intermediate inside 256 bits - `x^4` itself would overflow for realistically
    ///      sized pools. `r <= WAD` by construction, so `x` here is the larger of the two legs.
    /// @param invariant_ The stable invariant in the pool's scaled form
    /// @param ratio_ The fair ratio `r = y / x` of the smaller to the larger leg, in WAD
    /// @return The larger normalised (1e18-scaled) leg
    function _majorLeg(uint256 invariant_, uint256 ratio_) private pure returns (uint256) {
        uint256 qWad = ratio_ + Math.mulDiv(Math.mulDiv(ratio_, ratio_, WAD), ratio_, WAD);
        return Math.sqrt(Math.mulDiv(Math.sqrt(invariant_) * SQRT_K_SCALE, WAD, Math.sqrt(qWad * WAD)));
    }

    /// @notice The Solidly stable invariant `x^3 * y + x * y^3`, in the pool's own scaled form
    /// @dev Mirrors `Pool._k` (`k_scaled = x * y * (x^2 + y^2) / 1e54`) but evaluates every product
    ///      with `Math.mulDiv`, which carries the intermediate at 512-bit precision and therefore
    ///      cannot overflow where the pool's own plain multiplication would.
    /// @param x_ Normalised (1e18-scaled) reserve of token0
    /// @param y_ Normalised (1e18-scaled) reserve of token1
    /// @return The scaled invariant constant
    function _invariant(uint256 x_, uint256 y_) private pure returns (uint256) {
        uint256 a = Math.mulDiv(x_, y_, WAD);
        uint256 b = Math.mulDiv(x_, x_, WAD) + Math.mulDiv(y_, y_, WAD);
        return Math.mulDiv(a, b, WAD);
    }

    /// @notice Inverts the stable-pool marginal price: returns `r` in WAD with `g(r) = targetPrice_`
    /// @dev `g` is monotonically increasing, `g(0) = 0` and `g(WAD) = WAD`, and the caller
    ///      guarantees `0 < targetPrice_ <= WAD`, so the root is bracketed by `[0, WAD]` and plain
    ///      bisection converges unconditionally. Bisection is used rather than Newton on purpose:
    ///      `g'(1) = 0`, so a Newton iteration degenerates exactly at the peg - the most common
    ///      operating point of a stable pool - whereas bisection has a fixed, provable step count
    ///      and therefore needs no non-convergence fallback.
    /// @param targetPrice_ The marginal price to invert, in WAD, in `(0, WAD]`
    /// @return The ratio `r = y / x`, in WAD, in `(0, WAD]`
    function _solveRatio(uint256 targetPrice_) private pure returns (uint256) {
        uint256 low;
        uint256 high = WAD;
        uint256 mid;

        for (uint256 i; i < RATIO_SEARCH_STEPS; ++i) {
            mid = (low + high) / 2;

            if (_marginalPrice(mid) < targetPrice_) {
                low = mid;
            } else {
                high = mid;
            }
        }

        return high;
    }

    /// @notice `g(r) = (r^3 + 3r) / (3r^2 + 1)`, the stable invariant's marginal price, all in WAD
    /// @dev `ratio_ <= WAD` by construction, so `r^2` and `r^3` stay far inside 256 bits.
    /// @param ratio_ The reserve ratio `r = y / x`, in WAD
    /// @return The marginal price of one whole token0 in whole token1, in WAD
    function _marginalPrice(uint256 ratio_) private pure returns (uint256) {
        uint256 ratioSquared = Math.mulDiv(ratio_, ratio_, WAD);
        uint256 numerator = Math.mulDiv(ratioSquared, ratio_, WAD) + 3 * ratio_;
        uint256 denominator = 3 * ratioSquared + WAD;
        return Math.mulDiv(numerator, WAD, denominator);
    }
}
