// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IEulerV2Swap} from "../../../../contracts/fuses/euler/ext/IEulerV2Swap.sol";

/// @title EulerSwapCurveReference
/// @notice Test-only transcription of EulerSwap `CurveLib.verify` and `CurveLib.f` from euler-xyz/euler-swap
///         @ 81cf6dc988468fd56f690e6bc0e338a5be02d034 (tag eulerswap-2.0), `src/libraries/CurveLib.sol` (BUSL-1.1,
///         Euler Labs / ZeroEx), together with the helpers `f` uses from `src/math/FullMath.sol`
///         (`saturatingMulDivUp`, `fullMul`, `_mulDivSetup`, `_mulDivInvert`; MIT, after Remco Bloemen) and
///         `src/math/UnsafeMath.sol` (`unsafeDivUp`, `unsafeMulMod`, `Math.saturatingAdd`, `Math.inc`, `Math.toInt`).
/// @dev Kept as close to the source as possible (same operation order, the same unchecked blocks and assembly) so it
///      is an independent oracle for EulerV2SwapFairPointLib, which re-implements `f` on OpenZeppelin Math. The only
///      edits: `IEulerSwap.DynamicParams` is `IEulerV2Swap.DynamicParams` (same fields, transcribed from the same
///      commit), the `using` directives are expanded into calls, and `Panic.panic(ARITHMETIC_OVERFLOW)` in `Math.inc`
///      is a checked addition (same panic code 0x11).
library EulerSwapCurveReference {
    /// @notice CurveLib.verify: true if the reserves are on, or above and to the right of, the curve
    function verify(
        IEulerV2Swap.DynamicParams memory p,
        uint256 newReserve0,
        uint256 newReserve1
    ) internal pure returns (bool) {
        if (newReserve0 > type(uint112).max || newReserve1 > type(uint112).max) return false;
        if (newReserve0 < p.minReserve0 || newReserve1 < p.minReserve1) return false;

        if (newReserve0 >= p.equilibriumReserve0) {
            if (newReserve1 >= p.equilibriumReserve1) return true;
            return
                newReserve0 >=
                f(newReserve1, p.priceY, p.priceX, p.equilibriumReserve1, p.equilibriumReserve0, p.concentrationY);
        } else {
            if (newReserve1 < p.equilibriumReserve1) return false;
            return
                newReserve1 >=
                f(newReserve0, p.priceX, p.priceY, p.equilibriumReserve0, p.equilibriumReserve1, p.concentrationX);
        }
    }

    /// @notice CurveLib.f: output `y` for input `x` (1 <= x <= x0), `y0 <= y <= 2^112 - 1`, or type(uint256).max on
    ///         overflow
    function f(uint256 x, uint256 px, uint256 py, uint256 x0, uint256 y0, uint256 c) internal pure returns (uint256) {
        uint256 output;

        unchecked {
            if (c == 1e18) {
                // `c == 1e18` indicates that this is a constant-sum curve. Convert `x` into `y`
                // using `px` and `py`
                uint256 v = unsafeDivUp((x0 - x) * px, py); // scale: 1; units: token Y
                output = y0 + v;
            } else {
                uint256 a = px * (x0 - x); // scale: 1e18; units: none; range: 196 bits
                uint256 b = c * x + (1e18 - c) * x0; // scale: 1e18; units: token X; range: 172 bits
                uint256 d = 1e18 * x * py; // scale: 1e36; units: token X / token Y; range: 255 bits
                uint256 v = saturatingMulDivUp(a, b, d); // scale: 1; units: token Y
                output = saturatingAdd(y0, v);
            }

            if (output > type(uint112).max) return type(uint256).max;
        }

        return output;
    }

    /// @dev FullMath.saturatingMulDivUp: a*b/denominator rounded up, type(uint256).max on overflow or denominator == 0
    function saturatingMulDivUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        (uint256 prod0, uint256 prod1, uint256 remainder) = _mulDivSetup(a, b, denominator);
        uint256 overflow;
        unchecked {
            overflow = toInt(denominator > prod1) - 1;
        }
        if (prod1 == 0) {
            return saturatingAdd(unsafeDivUp(prod0, denominator), overflow);
        }
        return saturatingAdd(inc(_mulDivInvert(prod0, prod1, denominator, remainder), 0 < remainder), overflow);
    }

    /// @dev FullMath.fullMul
    function fullMul(uint256 a, uint256 b) internal pure returns (uint256 lo, uint256 hi) {
        assembly ("memory-safe") {
            let mm := mulmod(a, b, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }

    /// @dev FullMath._mulDivSetup
    function _mulDivSetup(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) private pure returns (uint256 prod0, uint256 prod1, uint256 remainder) {
        (prod0, prod1) = fullMul(a, b);
        remainder = unsafeMulMod(a, b, denominator);
    }

    /// @dev FullMath._mulDivInvert: 512-bit by 256-bit division, overflow and division by zero are GIGO
    function _mulDivInvert(
        uint256 prod0,
        uint256 prod1,
        uint256 denominator,
        uint256 remainder
    ) private pure returns (uint256) {
        uint256 inv;
        assembly ("memory-safe") {
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)

            {
                let twos := and(sub(0, denominator), denominator)

                denominator := div(denominator, twos)

                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
                prod0 := or(prod0, mul(prod1, twos))
            }

            inv := xor(mul(3, denominator), 2)

            inv := mul(inv, sub(2, mul(denominator, inv))) // inverse mod 2**8
            inv := mul(inv, sub(2, mul(denominator, inv))) // inverse mod 2**16
            inv := mul(inv, sub(2, mul(denominator, inv))) // inverse mod 2**32
            inv := mul(inv, sub(2, mul(denominator, inv))) // inverse mod 2**64
            inv := mul(inv, sub(2, mul(denominator, inv))) // inverse mod 2**128
            inv := mul(inv, sub(2, mul(denominator, inv))) // inverse mod 2**256
        }

        unchecked {
            return prod0 * inv;
        }
    }

    /// @dev UnsafeMath.unsafeDivUp
    function unsafeDivUp(uint256 n, uint256 d) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := add(gt(mod(n, d), 0x00), div(n, d))
        }
    }

    /// @dev UnsafeMath.unsafeMulMod
    function unsafeMulMod(uint256 a, uint256 b, uint256 m) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := mulmod(a, b, m)
        }
    }

    /// @dev Math.saturatingAdd (UnsafeMath.sol)
    function saturatingAdd(uint256 x, uint256 y) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := add(x, y)
            r := or(r, sub(0x00, lt(r, y)))
        }
    }

    /// @dev Math.inc (UnsafeMath.sol): x + c, panics 0x11 on overflow
    function inc(uint256 x, bool c) internal pure returns (uint256) {
        return x + toInt(c);
    }

    /// @dev Math.toInt (UnsafeMath.sol)
    function toInt(bool c) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := c
        }
    }
}
