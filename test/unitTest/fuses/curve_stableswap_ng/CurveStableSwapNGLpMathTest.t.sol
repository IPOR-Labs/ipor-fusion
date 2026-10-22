// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CurveStableSwapNGLpMath} from "../../../../contracts/fuses/curve_stableswap_ng/lib/CurveStableSwapNGLpMath.sol";

/// @dev External wrappers so `vm.expectRevert` has a real call frame to observe; the library's
///      functions are `internal` and would otherwise be inlined into the test itself.
contract CurveStableSwapNGLpMathHarness {
    function toBaseUnitPriceWad(
        uint256 coinPriceWad_,
        uint256 coinDecimals_,
        uint256 storedRate_,
        uint256 coinIndex_
    ) external pure returns (uint256) {
        return CurveStableSwapNGLpMath.toBaseUnitPriceWad(coinPriceWad_, coinDecimals_, storedRate_, coinIndex_);
    }

    function validateStoredRatesLength(uint256 storedRatesLength_, uint256 nCoins_) external pure {
        CurveStableSwapNGLpMath.validateStoredRatesLength(storedRatesLength_, nCoins_);
    }
}

/// @notice Unit tests for the IL-7950 follow-up: the LP price must be taken over BASE-unit coin
///         prices, so a coin whose `stored_rates()` entry carries an external rate does not
///         over-value the LP. This is where the arithmetic lives, so this is where it is pinned;
///         the three call sites only wire it up.
contract CurveStableSwapNGLpMathTest is Test {
    CurveStableSwapNGLpMathHarness internal harness;

    /// @dev sUSD/sUSDe on Ethereum, `stored_rates()` at block 22894761 -> [1e18, 1181045021292653918].
    uint256 internal constant SUSDE_STORED_RATE = 1181045021292653918;

    function setUp() public {
        harness = new CurveStableSwapNGLpMathHarness();
    }

    // ---- identity cases: a coin with no external rate must be untouched ----

    /// @notice An 18-decimal coin with no external rate has `stored_rates == 10**18`, so the
    ///         conversion must return the price unchanged. This is what keeps every pool of
    ///         ordinary stablecoins valued exactly as before the change.
    function test_toBaseUnitPriceWad_plainCoin18Decimals_isIdentity() public view {
        assertEq(harness.toBaseUnitPriceWad(1e18, 18, 1e18, 0), 1e18);
        assertEq(harness.toBaseUnitPriceWad(0.97e18, 18, 1e18, 1), 0.97e18);
    }

    /// @notice A 6-decimal coin (USDC) has `stored_rates == 10**30`; still the identity.
    function test_toBaseUnitPriceWad_plainCoin6Decimals_isIdentity() public view {
        assertEq(harness.toBaseUnitPriceWad(1e18, 6, 1e30, 0), 1e18);
        assertEq(harness.toBaseUnitPriceWad(1.0031e18, 6, 1e30, 0), 1.0031e18);
    }

    /// @notice An 8-decimal coin (WBTC-shaped) priced far from $1 is also unchanged - the guard
    ///         against a formula that only happens to work for dollar-pegged coins.
    function test_toBaseUnitPriceWad_plainCoin8Decimals_highPrice_isIdentity() public view {
        assertEq(harness.toBaseUnitPriceWad(100_000e18, 8, 1e28, 0), 100_000e18);
    }

    // ---- the actual fix: a rate-bearing coin must be divided back to base units ----

    /// @notice sUSDe with the real on-chain rate: priced at exactly the rate, one BASE unit (USDe)
    ///         is worth exactly $1. Before the fix the raw $1.181 price was compared against the
    ///         other coins and, when it was the minimum, inflated the whole LP by the same 18.1%.
    function test_toBaseUnitPriceWad_rateBearingCoin_dividesOutTheRate() public view {
        assertEq(harness.toBaseUnitPriceWad(SUSDE_STORED_RATE, 18, SUSDE_STORED_RATE, 1), 1e18);
    }

    /// @notice The rate is divided out, not the peg: a rate-bearing coin trading BELOW its
    ///         redemption value must still report a base price below $1, so the conservative
    ///         minimum keeps its meaning.
    function test_toBaseUnitPriceWad_rateBearingCoin_keepsDepegSignal() public view {
        uint256 depeggedPrice = (SUSDE_STORED_RATE * 97) / 100; // 3% below redemption value
        uint256 baseUnitPrice = harness.toBaseUnitPriceWad(depeggedPrice, 18, SUSDE_STORED_RATE, 1);

        assertApproxEqAbs(baseUnitPrice, 0.97e18, 1, "depeg must survive the conversion");
        assertLt(baseUnitPrice, 1e18, "a depegged coin must not price above par in base units");
    }

    /// @notice A rate-bearing coin with non-18 decimals: `stored_rates` folds BOTH the decimal
    ///         normalisation and the rate into one number, and only the rate half may be removed.
    function test_toBaseUnitPriceWad_rateBearingCoin_nonStandardDecimals() public view {
        // 6-decimal coin carrying a 1.25 rate -> stored_rates = 10**(36-6) * 1.25.
        uint256 storedRate = (1e30 * 125) / 100;

        assertEq(harness.toBaseUnitPriceWad(1.25e18, 6, storedRate, 0), 1e18);
    }

    // ---- guards ----

    function test_toBaseUnitPriceWad_zeroStoredRate_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(CurveStableSwapNGLpMath.CurveStableSwapNGLpMathZeroStoredRate.selector, uint256(1))
        );
        harness.toBaseUnitPriceWad(1e18, 18, 0, 1);
    }

    function test_toBaseUnitPriceWad_decimalsAboveBase_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CurveStableSwapNGLpMath.CurveStableSwapNGLpMathUnsupportedDecimals.selector,
                uint256(0),
                uint256(37)
            )
        );
        harness.toBaseUnitPriceWad(1e18, 37, 1e18, 0);
    }

    /// @notice 36 decimals is the boundary the guard allows through - `10**0` - so it must NOT
    ///         revert, pinning the comparison as `>` rather than `>=`.
    function test_toBaseUnitPriceWad_decimalsAtBase_isAllowed() public view {
        assertEq(harness.toBaseUnitPriceWad(1e18, 36, 1, 0), 1e18);
    }

    function test_validateStoredRatesLength_matching_passes() public view {
        harness.validateStoredRatesLength(3, 3);
    }

    function test_validateStoredRatesLength_mismatch_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CurveStableSwapNGLpMath.CurveStableSwapNGLpMathStoredRatesLengthMismatch.selector,
                uint256(2),
                uint256(3)
            )
        );
        harness.validateStoredRatesLength(2, 3);
    }
}
