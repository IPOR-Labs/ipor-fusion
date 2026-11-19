// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEulerV2Swap} from "./ext/IEulerV2Swap.sol";

/// @title EulerV2SwapFairPointLib
/// @notice Oracle-fair point of an EulerSwap v2 curve and the displacement of a pool's reserves from it, in USD WAD
///         (IL-9706). The balance fuse subtracts the displacement from the value of the pool's sub-account, so a swap
///         or a donation that a third party can reverse in the same transaction does not change the reported value:
///         the holdings of the sub-account and the reserves of the pool move by the same amounts, the fair point does
///         not move at all, and only the LP fee stays.
/// @dev Pure library, no external calls: the caller reads `getDynamicParams()`, `getReserves()` and the oracle prices
///      and passes them in.
///
///      Notation: `x0, y0` equilibrium reserves, `px, py` curve prices, `cx, cy` concentrations (WAD), `P0, P1` oracle
///      USD price of one base unit of asset0 / asset1, `R = P0 / P1`, `rho = (px / py) / R` (curve price of asset0 over
///      its oracle price). The fair point is the point accepted by EulerSwap `CurveLib.verify` that minimises the
///      oracle value `V(u0, u1) = P0 * u0 + P1 * u1`.
///
///      Formula. On the asset0 side (`x <= x0`) the curve is `y = y0 + (px / py) * (x0 - x) * (cx + (1 - cx) * x0 / x)`
///      with slope `-(px / py) * (cx + (1 - cx) * (x0 / x)^2)`. `V` is convex along the curve and its derivative
///      vanishes where `(x0 / x)^2 = (1 / rho - cx) / (1 - cx)`, so:
///      - `rho == 1`: the equilibrium point `(x0, y0)`;
///      - `rho < 1`: `a0 = x0 * sqrt((1 - cx) * rho / (1 - cx * rho))`, `a1 = f(a0)` (the asset1 side only gets more
///        expensive, the minimum is on the asset0 side);
///      - `rho > 1`: mirrored on the asset1 side, `a1 = y0 * sqrt((1 - cy) / (rho - cy))`, `a0 = f(a1)`;
///      - constant-sum side (`c == 1e18`): the formula gives 0, so the point is the lowest admissible reserve.
///
///      Clamping. The minimum is taken over the admissible interval of the side, `[lowest, z0]`, with
///      `lowest = max(minReserve, 1 if c < 1e18)` (the curve divides by the reserve) and with the overflow boundary:
///      the smallest reserve for which `f` still fits in uint112 (`verify` rejects anything above uint112.max). The
///      closed form is evaluated at `floor(z*)` and `floor(z*) + 1` clamped to `[lowest, z0]` and the cheaper of the
///      two is taken. When `f` overflows there, the point moves up to the overflow boundary (`f` is monotonic: bisection
///      in at most 112 steps for a concentrated side, a closed form for a constant-sum side) - the value of `f` is never
///      truncated, so the fair point is always accepted by `verify`. An equilibrium reserve of 0 on the minimum side
///      (or `lowest >= z0`) leaves only the equilibrium point.
///
///      Rounding. `f` rounds up exactly like `CurveLib.f` (so `(a0, f(a0))` is the cheapest point `verify` accepts for
///      `a0`); the value of the reserves is rounded up and the value of the fair point down, so the displacement is
///      rounded up (the fuse value is rounded down) and floored at 0.
///
///      Precision. `rho` is formed as an exact 512-bit fraction and carried with 192 fractional bits; below 2^-64 the
///      factor `1 / (1 - c * rho)` (< 1 + 2^-63) is dropped. The value error of the fair point is second order in the
///      error of `a0`, so the point is within one base unit of asset1 at its oracle price (the rounding of `f`) of the
///      cheapest admissible point.
///
///      Domain (guaranteed for an activated pool, checked where cheap): `0 < px, py < 2^80`, `cx, cy <= 1e18`,
///      reserves and minimum reserves <= uint112.max, `minReserve <= equilibriumReserve`; prices > 0, token decimals
///      <= 36, `priceWad * 2^112 / 10^decimals < 2^256`.
library EulerV2SwapFairPointLib {
    /// @notice Oracle prices and token decimals of the two pool assets
    /// @param price0Wad USD price of one whole asset0 token, 18 decimals
    /// @param price1Wad USD price of one whole asset1 token, 18 decimals
    /// @param decimals0 Token decimals of asset0
    /// @param decimals1 Token decimals of asset1
    struct AssetPrices {
        uint256 price0Wad;
        uint256 price1Wad;
        uint256 decimals0;
        uint256 decimals1;
    }

    /// @dev One side of the curve seen from its own asset: the own reserve `z` goes down from `equilibriumOwn` and the
    ///      other reserve `w = f(z)` goes up from `equilibriumOther`. The asset0 side is (x0, y0, px, py, cx, minReserve0),
    ///      the asset1 side is (y0, x0, py, px, cy, minReserve1), as in the two branches of `CurveLib.verify`.
    struct CurveSide {
        uint256 equilibriumOwn;
        uint256 equilibriumOther;
        uint256 curvePriceOwn;
        uint256 curvePriceOther;
        uint256 concentration;
        uint256 minReserveOwn;
    }

    /// @dev A ratio `num / den` held as two 512-bit integers (hi, lo words)
    struct Ratio512 {
        uint256 numHi;
        uint256 numLo;
        uint256 denHi;
        uint256 denLo;
    }

    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_RESERVE = type(uint112).max;
    uint256 private constant MAX_DECIMALS = 36;
    /// @dev Value returned by `f` when the curve leaves uint112, as `CurveLib.f` does
    uint256 internal constant CURVE_OVERFLOW = type(uint256).max;
    /// @dev Fixed point of the side ratio on the exact branch: 192 fractional bits
    uint256 private constant RATIO_ONE = 1 << 192;
    /// @dev Below 2^-64 (2^128 in RATIO_ONE units) the factor 1 / (1 - c * rho) is dropped
    uint256 private constant RATIO_SMALL = 1 << 128;

    /// @notice Thrown when an oracle price of a pool asset is zero
    error EulerV2SwapFairPointZeroPrice();
    /// @notice Thrown when a token has more than 36 decimals
    error EulerV2SwapFairPointUnsupportedDecimals(uint256 decimals0, uint256 decimals1);
    /// @notice Thrown when the curve parameters are outside what EulerSwap accepts at activation
    error EulerV2SwapFairPointInvalidCurve();

    /// @notice Oracle value of the pool reserves above the value of the fair point, never negative
    /// @dev `ceil(V(reserve0_, reserve1_)) - floor(V(fair point))`, floored at 0. For reserves accepted by `verify` the
    ///      unfloored difference is at least minus the rounding of `f` (one base unit of asset1 at its oracle price), so
    ///      the floor only removes rounding. A swap or a donation changes it by exactly the oracle value it adds to or
    ///      takes from the reserves (rounding aside).
    /// @param params_ Dynamic parameters of the pool (`getDynamicParams()`)
    /// @param reserve0_ Current virtual reserve of asset0 (`getReserves()`)
    /// @param reserve1_ Current virtual reserve of asset1 (`getReserves()`)
    /// @param prices_ Oracle prices and token decimals of asset0 and asset1
    /// @return displacementWad Displacement in USD, 18 decimals, rounded up
    function poolDisplacementWad(
        IEulerV2Swap.DynamicParams memory params_,
        uint256 reserve0_,
        uint256 reserve1_,
        AssetPrices memory prices_
    ) internal pure returns (uint256 displacementWad) {
        (uint256 fairReserve0, uint256 fairReserve1) = fairPoint(params_, prices_);
        uint256 reservesValue = reservesValueWad(reserve0_, reserve1_, prices_, Math.Rounding.Ceil);
        uint256 fairValue = reservesValueWad(fairReserve0, fairReserve1, prices_, Math.Rounding.Floor);
        displacementWad = reservesValue > fairValue ? reservesValue - fairValue : 0;
    }

    /// @notice Point accepted by `CurveLib.verify` with the lowest oracle value; depends only on the curve parameters
    ///         and the oracle prices, never on the reserves
    /// @dev See the library NatSpec for the formula, the clamping and the overflow boundary.
    /// @param params_ Dynamic parameters of the pool
    /// @param prices_ Oracle prices and token decimals of asset0 and asset1
    /// @return fairReserve0 Reserve of asset0 at the fair point
    /// @return fairReserve1 Reserve of asset1 at the fair point (`f` of `fairReserve0`, or the equilibrium reserve)
    function fairPoint(
        IEulerV2Swap.DynamicParams memory params_,
        AssetPrices memory prices_
    ) internal pure returns (uint256 fairReserve0, uint256 fairReserve1) {
        _validate(params_, prices_);

        Ratio512 memory ratio = _curveToOracleRatio(params_, prices_);

        if (ratio.numHi == ratio.denHi && ratio.numLo == ratio.denLo) {
            return (params_.equilibriumReserve0, params_.equilibriumReserve1);
        }

        if (_lessThan512(ratio.numHi, ratio.numLo, ratio.denHi, ratio.denLo)) {
            // rho < 1: asset0 is cheaper on the curve than at the oracle, the minimum is at x <= x0
            return
                _sideFairPoint(
                    CurveSide({
                        equilibriumOwn: params_.equilibriumReserve0,
                        equilibriumOther: params_.equilibriumReserve1,
                        curvePriceOwn: params_.priceX,
                        curvePriceOther: params_.priceY,
                        concentration: params_.concentrationX,
                        minReserveOwn: params_.minReserve0
                    }),
                    prices_,
                    ratio
                );
        }

        // rho > 1: mirrored on the asset1 side with the ratio 1 / rho and the prices swapped
        (fairReserve1, fairReserve0) = _sideFairPoint(
            CurveSide({
                equilibriumOwn: params_.equilibriumReserve1,
                equilibriumOther: params_.equilibriumReserve0,
                curvePriceOwn: params_.priceY,
                curvePriceOther: params_.priceX,
                concentration: params_.concentrationY,
                minReserveOwn: params_.minReserve1
            }),
            AssetPrices({
                price0Wad: prices_.price1Wad,
                price1Wad: prices_.price0Wad,
                decimals0: prices_.decimals1,
                decimals1: prices_.decimals0
            }),
            Ratio512({numHi: ratio.denHi, numLo: ratio.denLo, denHi: ratio.numHi, denLo: ratio.numLo})
        );
    }

    /// @notice Oracle value of an amount of asset0 plus an amount of asset1
    /// @param amount0_ Amount of asset0 in base units
    /// @param amount1_ Amount of asset1 in base units
    /// @param prices_ Oracle prices and token decimals of asset0 and asset1
    /// @param rounding_ Rounding of each of the two terms
    /// @return valueWad Value in USD, 18 decimals
    function reservesValueWad(
        uint256 amount0_,
        uint256 amount1_,
        AssetPrices memory prices_,
        Math.Rounding rounding_
    ) internal pure returns (uint256 valueWad) {
        valueWad =
            Math.mulDiv(amount0_, prices_.price0Wad, 10 ** prices_.decimals0, rounding_) +
            Math.mulDiv(amount1_, prices_.price1Wad, 10 ** prices_.decimals1, rounding_);
    }

    /// @notice EulerSwap curve `y = f(x)` for `x <= x0`, the same integer function as `CurveLib.f` of
    ///         euler-xyz/euler-swap @ 81cf6dc9 (tag eulerswap-2.0), re-implemented on OpenZeppelin Math
    /// @dev Constant sum (`c_ == 1e18`): `y0 + ceil((x0 - x) * px / py)`. Otherwise
    ///      `y0 + ceil(px * (x0 - x) * (c * x + (1e18 - c) * x0) / (1e18 * x * py))`, saturating like
    ///      `FullMath.saturatingMulDivUp` (also for `x == 0`, where the divisor is 0). Returns `CURVE_OVERFLOW`
    ///      (type(uint256).max) when the result exceeds uint112.max, as the original does. The only difference from
    ///      the original: a quotient of exactly 2^256 - 1 with a remainder saturates here and panics there; both mean
    ///      "not accepted". Requires `x_ <= x0_ <= uint112.max`, `y0_ <= uint112.max`, `px_, py_ < 2^80`, `c_ <= 1e18`.
    /// @param x_ Reserve of the own asset, `x_ <= x0_`
    /// @param px_ Curve price of the own asset
    /// @param py_ Curve price of the other asset
    /// @param x0_ Equilibrium reserve of the own asset
    /// @param y0_ Equilibrium reserve of the other asset
    /// @param c_ Concentration of the side, WAD
    /// @return Reserve of the other asset on the curve, rounded up, or `CURVE_OVERFLOW`
    function f(
        uint256 x_,
        uint256 px_,
        uint256 py_,
        uint256 x0_,
        uint256 y0_,
        uint256 c_
    ) internal pure returns (uint256) {
        uint256 v;
        if (c_ == WAD) {
            v = Math.ceilDiv((x0_ - x_) * px_, py_);
        } else {
            v = _mulDivUpSaturating(px_ * (x0_ - x_), c_ * x_ + (WAD - c_) * x0_, WAD * x_ * py_);
        }
        if (v > MAX_RESERVE - y0_) {
            return CURVE_OVERFLOW;
        }
        return y0_ + v;
    }

    /// @dev Cheapest admissible point of one side, returned as (own reserve, other reserve)
    function _sideFairPoint(
        CurveSide memory side_,
        AssetPrices memory prices_,
        Ratio512 memory ratio_
    ) private pure returns (uint256 own, uint256 other) {
        uint256 lowest = side_.concentration < WAD ? Math.max(side_.minReserveOwn, 1) : side_.minReserveOwn;

        if (lowest >= side_.equilibriumOwn) {
            return (side_.equilibriumOwn, side_.equilibriumOther);
        }

        // floor of the continuous minimum; the integer minimum of the convex value is at floor or floor + 1
        uint256 candidate = Math.sqrt(_optimalOwnReserveSquared(side_, ratio_));
        uint256 low = _clamp(candidate, lowest, side_.equilibriumOwn);
        uint256 high = _clamp(candidate + 1, lowest, side_.equilibriumOwn);
        uint256 otherLow = _sideCurve(side_, low);
        uint256 otherHigh = _sideCurve(side_, high);

        if (otherLow != CURVE_OVERFLOW) {
            if (
                reservesValueWad(high, otherHigh, prices_, Math.Rounding.Floor) <
                reservesValueWad(low, otherLow, prices_, Math.Rounding.Floor)
            ) {
                return (high, otherHigh);
            }
            return (low, otherLow);
        }

        // `low` is below the overflow boundary; `high == low + 1`, so if `high` fits it is the boundary
        if (otherHigh != CURVE_OVERFLOW) {
            return (high, otherHigh);
        }

        // both candidates are below the boundary; the value increases from the boundary up to z0
        own = _overflowBoundary(side_, high);
        other = _sideCurve(side_, own);
    }

    /// @dev Smallest own reserve for which `f` fits in uint112, given that `f(overflowing_)` overflows and `f(z0)` fits
    function _overflowBoundary(CurveSide memory side_, uint256 overflowing_) private pure returns (uint256) {
        if (side_.concentration == WAD) {
            // y0 + ceil((z0 - z) * px / py) <= max  <=>  z0 - z <= floor((max - y0) * py / px)
            uint256 span = Math.mulDiv(
                MAX_RESERVE - side_.equilibriumOther,
                side_.curvePriceOther,
                side_.curvePriceOwn
            );
            return span >= side_.equilibriumOwn ? 0 : side_.equilibriumOwn - span;
        }

        uint256 low = overflowing_;
        uint256 high = side_.equilibriumOwn;
        while (high - low > 1) {
            uint256 mid = low + (high - low) / 2;
            if (_sideCurve(side_, mid) == CURVE_OVERFLOW) {
                low = mid;
            } else {
                high = mid;
            }
        }
        return high;
    }

    /// @dev floor((z0 * sqrt((1 - c) * r / (1 - c * r)))^2) for the side ratio r = num / den < 1
    function _optimalOwnReserveSquared(CurveSide memory side_, Ratio512 memory ratio_) private pure returns (uint256) {
        if (side_.concentration == WAD) {
            return 0;
        }

        (uint256 num, uint256 den) = _commonShift(ratio_);
        if (num == 0) {
            return 0;
        }

        uint256 concentration = side_.concentration;
        uint256 equilibriumSquared = side_.equilibriumOwn * side_.equilibriumOwn;
        uint256 ratioScaled = Math.mulDiv(num, RATIO_ONE, den);

        if (ratioScaled >= RATIO_SMALL) {
            return
                Math.mulDiv(
                    equilibriumSquared,
                    (WAD - concentration) * ratioScaled,
                    WAD * RATIO_ONE - concentration * ratioScaled
                );
        }

        return Math.mulDiv(Math.mulDiv(equilibriumSquared, num, den), WAD - concentration, WAD);
    }

    /// @dev rho = (px * 10^dec0 * price1Wad) / (py * 10^dec1 * price0Wad), both sides divided by 10^min(dec0, dec1)
    function _curveToOracleRatio(
        IEulerV2Swap.DynamicParams memory params_,
        AssetPrices memory prices_
    ) private pure returns (Ratio512 memory ratio) {
        uint256 minDecimals = Math.min(prices_.decimals0, prices_.decimals1);
        (ratio.numHi, ratio.numLo) = _mul512(
            uint256(params_.priceX) * 10 ** (prices_.decimals0 - minDecimals),
            prices_.price1Wad
        );
        (ratio.denHi, ratio.denLo) = _mul512(
            uint256(params_.priceY) * 10 ** (prices_.decimals1 - minDecimals),
            prices_.price0Wad
        );
    }

    function _validate(IEulerV2Swap.DynamicParams memory params_, AssetPrices memory prices_) private pure {
        if (prices_.price0Wad == 0 || prices_.price1Wad == 0) {
            revert EulerV2SwapFairPointZeroPrice();
        }
        if (prices_.decimals0 > MAX_DECIMALS || prices_.decimals1 > MAX_DECIMALS) {
            revert EulerV2SwapFairPointUnsupportedDecimals(prices_.decimals0, prices_.decimals1);
        }
        if (
            params_.priceX == 0 || params_.priceY == 0 || params_.concentrationX > WAD || params_.concentrationY > WAD
        ) {
            revert EulerV2SwapFairPointInvalidCurve();
        }
    }

    function _sideCurve(CurveSide memory side_, uint256 own_) private pure returns (uint256) {
        return
            f(
                own_,
                side_.curvePriceOwn,
                side_.curvePriceOther,
                side_.equilibriumOwn,
                side_.equilibriumOther,
                side_.concentration
            );
    }

    /// @dev ceil(a * b / d), or type(uint256).max when the quotient does not fit in 256 bits or d == 0
    function _mulDivUpSaturating(uint256 a_, uint256 b_, uint256 d_) private pure returns (uint256) {
        if (d_ == 0) {
            return type(uint256).max;
        }
        (uint256 hi, ) = _mul512(a_, b_);
        if (hi >= d_) {
            return type(uint256).max;
        }
        uint256 quotient = Math.mulDiv(a_, b_, d_);
        if (mulmod(a_, b_, d_) > 0) {
            return quotient == type(uint256).max ? quotient : quotient + 1;
        }
        return quotient;
    }

    /// @dev Shifts num and den right by the same number of bits so that both fit in 256 bits (num <= den)
    function _commonShift(Ratio512 memory ratio_) private pure returns (uint256 num, uint256 den) {
        if (ratio_.denHi == 0) {
            return (ratio_.numLo, ratio_.denLo);
        }
        uint256 shift = Math.log2(ratio_.denHi) + 1;
        num = (ratio_.numLo >> shift) | (ratio_.numHi << (256 - shift));
        den = (ratio_.denLo >> shift) | (ratio_.denHi << (256 - shift));
    }

    /// @dev 512-bit product [hi lo] = a * b (Chinese remainder theorem, as in Remco Bloemen's mulDiv)
    function _mul512(uint256 a_, uint256 b_) private pure returns (uint256 hi, uint256 lo) {
        unchecked {
            lo = a_ * b_;
            uint256 mm = mulmod(a_, b_, type(uint256).max);
            hi = mm - lo - (mm < lo ? 1 : 0);
        }
    }

    function _lessThan512(uint256 aHi_, uint256 aLo_, uint256 bHi_, uint256 bLo_) private pure returns (bool) {
        return aHi_ < bHi_ || (aHi_ == bHi_ && aLo_ < bLo_);
    }

    function _clamp(uint256 value_, uint256 lower_, uint256 upper_) private pure returns (uint256) {
        if (value_ < lower_) {
            return lower_;
        }
        return value_ > upper_ ? upper_ : value_;
    }
}
