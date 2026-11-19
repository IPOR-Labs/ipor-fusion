// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEulerV2Swap} from "../../../contracts/fuses/euler/ext/IEulerV2Swap.sol";
import {EulerV2SwapFairPointLib} from "../../../contracts/fuses/euler/EulerV2SwapFairPointLib.sol";
import {EulerSwapCurveReference} from "./mocks/EulerSwapCurveReference.sol";

/// @dev External wrapper so that library reverts can be asserted by selector
contract EulerV2SwapFairPointLibHarness {
    function fairPoint(
        IEulerV2Swap.DynamicParams memory params_,
        EulerV2SwapFairPointLib.AssetPrices memory prices_
    ) external pure returns (uint256, uint256) {
        return EulerV2SwapFairPointLib.fairPoint(params_, prices_);
    }

    function poolDisplacementWad(
        IEulerV2Swap.DynamicParams memory params_,
        uint256 reserve0_,
        uint256 reserve1_,
        EulerV2SwapFairPointLib.AssetPrices memory prices_
    ) external pure returns (uint256) {
        return EulerV2SwapFairPointLib.poolDisplacementWad(params_, reserve0_, reserve1_, prices_);
    }
}

/// @title EulerV2SwapFairPointLibTest
/// @notice IL-9706 (3sigma #20): the closed-form fair point of the EulerSwap curve. The oracle is the transcription of
///         `CurveLib.f` / `CurveLib.verify` @ 81cf6dc9 in EulerSwapCurveReference, which is independent of the
///         library's re-implementation of `f`. Fuzz (2 000 runs each): the fair point is always accepted by `verify`
///         (also where `f` leaves uint112), its value is not above a numeric minimum of the oracle value on the
///         admissible region (ternary search on both sides of the curve plus a local scan) by more than the tolerance
///         of criterion 6d (2 base units of each asset at its oracle price + 1e-12 relative), no accepted point is
///         cheaper than the fair point beyond that tolerance, and the displacement moves one for one with the oracle
///         value of the reserves. New library: there is no base-commit proof for this file (plan, criterion 2).
contract EulerV2SwapFairPointLibTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_RESERVE = type(uint112).max;
    uint256 internal constant INFINITE = type(uint256).max;
    uint256 internal constant SCAN_WINDOW = 8;

    EulerV2SwapFairPointLibHarness internal harness;

    /// @dev Raw fuzz input; every field is mapped onto the domain EulerSwap accepts at activation, with corners
    struct CurveSeed {
        uint256 equilibrium0;
        uint256 equilibrium1;
        uint256 min0;
        uint256 min1;
        uint256 priceX;
        uint256 priceY;
        uint256 concentrationX;
        uint256 concentrationY;
        uint256 oracle0;
        uint256 oracle1;
        uint256 decimals0;
        uint256 decimals1;
    }

    function setUp() public {
        harness = new EulerV2SwapFairPointLibHarness();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fuzz (criterion 6d)
    // ---------------------------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_FairPointIsAcceptedByVerifyAndMatchesNumericMinimum(CurveSeed memory seed_) public pure {
        (IEulerV2Swap.DynamicParams memory params, EulerV2SwapFairPointLib.AssetPrices memory prices) = _build(seed_);

        (uint256 fair0, uint256 fair1) = EulerV2SwapFairPointLib.fairPoint(params, prices);

        assertTrue(EulerSwapCurveReference.verify(params, fair0, fair1), "fair point rejected by verify");

        uint256 fairValue = _valueDown(fair0, fair1, prices);
        uint256 numericMinimum = _numericMinimum(params, prices);

        assertLe(fairValue, numericMinimum + _tolerance(numericMinimum, prices), "fair point above numeric minimum");
        assertLe(
            EulerV2SwapFairPointLib.poolDisplacementWad(params, fair0, fair1, prices),
            2,
            "displacement at the fair point is more than rounding"
        );
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_AcceptedReservesAreNeverCheaperThanFairPointAndDisplacementMovesWithReserves(
        CurveSeed memory seed_,
        uint256 pointSeed_,
        uint256 extra0Seed_,
        uint256 extra1Seed_
    ) public pure {
        (IEulerV2Swap.DynamicParams memory params, EulerV2SwapFairPointLib.AssetPrices memory prices) = _build(seed_);
        (uint256 reserve0, uint256 reserve1) = _acceptedPoint(params, pointSeed_);
        assertTrue(EulerSwapCurveReference.verify(params, reserve0, reserve1), "generated point not on the curve");

        // A donation or the input leg of a swap: reserves above / to the right of the curve stay accepted
        uint256 extra0 = _below(extra0Seed_, MAX_RESERVE - reserve0);
        uint256 extra1 = _below(extra1Seed_, MAX_RESERVE - reserve1);
        assertTrue(
            EulerSwapCurveReference.verify(params, reserve0 + extra0, reserve1 + extra1),
            "moved point rejected by verify"
        );

        (uint256 fair0, uint256 fair1) = EulerV2SwapFairPointLib.fairPoint(params, prices);
        uint256 fairValue = _valueDown(fair0, fair1, prices);
        uint256 reservesValue = _valueUp(reserve0, reserve1, prices);

        // d >= 0 holds before the floor up to the tolerance: no accepted point is cheaper than the fair point
        assertLe(fairValue, reservesValue + _tolerance(reservesValue, prices), "accepted point below fair point");

        uint256 displacementBefore = EulerV2SwapFairPointLib.poolDisplacementWad(params, reserve0, reserve1, prices);
        uint256 displacementAfter = EulerV2SwapFairPointLib.poolDisplacementWad(
            params,
            reserve0 + extra0,
            reserve1 + extra1,
            prices
        );

        assertGe(displacementAfter, displacementBefore, "displacement decreased with more reserves");
        if (displacementBefore > 0) {
            // v - d of the pool sub-account is unchanged: d grows by the oracle value added to the reserves
            assertGe(displacementAfter - displacementBefore, _valueDown(extra0, extra1, prices), "below added value");
            assertLe(displacementAfter - displacementBefore, _valueUp(extra0, extra1, prices), "above added value");
        }
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_CurveMatchesReference(
        uint256 xSeed_,
        uint256 priceXSeed_,
        uint256 priceYSeed_,
        uint256 equilibrium0Seed_,
        uint256 equilibrium1Seed_,
        uint256 concentrationSeed_
    ) public pure {
        uint256 equilibrium0 = _reserve(equilibrium0Seed_);
        uint256 x = _below(xSeed_, equilibrium0);
        uint256 priceX = _curvePrice(priceXSeed_);
        uint256 priceY = _curvePrice(priceYSeed_);
        uint256 equilibrium1 = _reserve(equilibrium1Seed_);
        uint256 concentration = _concentration(concentrationSeed_);

        assertEq(
            EulerV2SwapFairPointLib.f(x, priceX, priceY, equilibrium0, equilibrium1, concentration),
            EulerSwapCurveReference.f(x, priceX, priceY, equilibrium0, equilibrium1, concentration),
            "library f differs from CurveLib.f"
        );
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Deterministic corners
    // ---------------------------------------------------------------------------------------------------------------

    function testShouldReturnEquilibriumWhenCurvePriceEqualsOraclePrice() public pure {
        IEulerV2Swap.DynamicParams memory params = _params(1e24, 1e24, 0, 0, 1e18, 1e18, 5e17, 5e17);
        EulerV2SwapFairPointLib.AssetPrices memory prices = _prices(1e18, 1e18, 18, 18);

        (uint256 fair0, uint256 fair1) = EulerV2SwapFairPointLib.fairPoint(params, prices);
        assertEq(fair0, 1e24, "fair0");
        assertEq(fair1, 1e24, "fair1");
        assertEq(EulerV2SwapFairPointLib.poolDisplacementWad(params, 1e24, 1e24, prices), 0, "d at equilibrium");

        // A curve push of 1e21 asset0: with rho = 1 the fair point is the equilibrium, so d is plain arithmetic:
        // every token is worth 1 USD and has 18 decimals, d = (x0 - 1e21 + y) - (x0 + y0) = y - y0 - 1e21
        uint256 pushed0 = 1e24 - 1e21;
        uint256 pushed1 = EulerSwapCurveReference.f(pushed0, 1e18, 1e18, 1e24, 1e24, 5e17);
        assertEq(
            EulerV2SwapFairPointLib.poolDisplacementWad(params, pushed0, pushed1, prices),
            pushed1 - 1e24 - 1e21,
            "d after a curve push"
        );
        assertGt(pushed1 - 1e24, 1e21, "the push overpays");
    }

    function testShouldReturnEquilibriumWhenCurvePriceEqualsOraclePriceAcrossDecimals() public pure {
        // asset0 has 6 decimals, asset1 18, both worth 1 USD: R = 1e12 base units of asset1 per base unit of asset0
        IEulerV2Swap.DynamicParams memory params = _params(1e12, 1e24, 0, 0, 1e24, 1e12, 9e17, 9e17);
        EulerV2SwapFairPointLib.AssetPrices memory prices = _prices(1e18, 1e18, 6, 18);

        (uint256 fair0, uint256 fair1) = EulerV2SwapFairPointLib.fairPoint(params, prices);
        assertEq(fair0, 1e12, "fair0");
        assertEq(fair1, 1e24, "fair1");
    }

    function testShouldPlaceFairPointAtClosedFormOnAssetZeroSide() public pure {
        // c = 0, curve price 1, asset0 worth 4 USD and asset1 1 USD: rho = 1/4, a0 = x0 * sqrt(rho) = x0 / 2,
        // a1 = y0 + (x0 - a0) * x0 / a0 = y0 + x0
        IEulerV2Swap.DynamicParams memory params = _params(1e18, 1e18, 0, 0, 1e18, 1e18, 0, 0);
        EulerV2SwapFairPointLib.AssetPrices memory prices = _prices(4e18, 1e18, 18, 18);

        (uint256 fair0, uint256 fair1) = EulerV2SwapFairPointLib.fairPoint(params, prices);
        assertEq(fair0, 5e17, "fair0");
        assertEq(fair1, 2e18, "fair1");
        assertTrue(EulerSwapCurveReference.verify(params, fair0, fair1), "verify");

        // Pending arbitrage loss booked at equilibrium: (4 * 1 + 1) - (4 * 0.5 + 2) = 1 USD
        assertEq(EulerV2SwapFairPointLib.poolDisplacementWad(params, 1e18, 1e18, prices), 1e18, "d at equilibrium");
        assertEq(EulerV2SwapFairPointLib.poolDisplacementWad(params, fair0, fair1, prices), 0, "d at fair point");
    }

    function testShouldPlaceFairPointAtClosedFormOnAssetOneSide() public pure {
        // Mirror: asset1 worth 4 USD, rho = 4, a1 = y0 * sqrt(1 / rho) = y0 / 2, a0 = x0 + y0
        IEulerV2Swap.DynamicParams memory params = _params(1e18, 1e18, 0, 0, 1e18, 1e18, 0, 0);
        EulerV2SwapFairPointLib.AssetPrices memory prices = _prices(1e18, 4e18, 18, 18);

        (uint256 fair0, uint256 fair1) = EulerV2SwapFairPointLib.fairPoint(params, prices);
        assertEq(fair0, 2e18, "fair0");
        assertEq(fair1, 5e17, "fair1");
        assertTrue(EulerSwapCurveReference.verify(params, fair0, fair1), "verify");
        assertEq(EulerV2SwapFairPointLib.poolDisplacementWad(params, 1e18, 1e18, prices), 1e18, "d at equilibrium");
    }

    function testShouldTakeMinReserveCornerOnConstantSumSide() public pure {
        // c = 1e18 on both sides, curve price 1, asset0 worth 2 USD: the cheapest point is the lowest asset0 reserve
        IEulerV2Swap.DynamicParams memory params = _params(1e18, 1e18, 1e17, 1e17, 1e18, 1e18, WAD, WAD);

        (uint256 fair0, uint256 fair1) = EulerV2SwapFairPointLib.fairPoint(params, _prices(2e18, 1e18, 18, 18));
        assertEq(fair0, 1e17, "asset0 side: fair0 = minReserve0");
        assertEq(fair1, 19e17, "asset0 side: fair1 = y0 + (x0 - minReserve0)");
        assertTrue(EulerSwapCurveReference.verify(params, fair0, fair1), "asset0 side: verify");
        assertFalse(EulerSwapCurveReference.verify(params, fair0 - 1, MAX_RESERVE), "below minReserve0");

        (fair0, fair1) = EulerV2SwapFairPointLib.fairPoint(params, _prices(1e18, 2e18, 18, 18));
        assertEq(fair0, 19e17, "asset1 side: fair0 = x0 + (y0 - minReserve1)");
        assertEq(fair1, 1e17, "asset1 side: fair1 = minReserve1");
        assertTrue(EulerSwapCurveReference.verify(params, fair0, fair1), "asset1 side: verify");
    }

    function testShouldTakeZeroReserveCornerOnConstantSumSideWithoutMinReserve() public pure {
        IEulerV2Swap.DynamicParams memory params = _params(1e18, 1e18, 0, 0, 1e18, 1e18, WAD, WAD);

        (uint256 fair0, uint256 fair1) = EulerV2SwapFairPointLib.fairPoint(params, _prices(2e18, 1e18, 18, 18));
        assertEq(fair0, 0, "fair0");
        assertEq(fair1, 2e18, "fair1");
        assertTrue(EulerSwapCurveReference.verify(params, fair0, fair1), "verify");
    }

    function testShouldClampToMinReserveOnConcentratedSide() public pure {
        // The closed form gives x0 / 2 (see the closed-form test); minReserve0 = 0.6 x0 is above it
        IEulerV2Swap.DynamicParams memory params = _params(1e18, 1e18, 6e17, 0, 1e18, 1e18, 0, 0);

        (uint256 fair0, uint256 fair1) = EulerV2SwapFairPointLib.fairPoint(params, _prices(4e18, 1e18, 18, 18));
        assertEq(fair0, 6e17, "fair0 = minReserve0");
        assertEq(fair1, EulerSwapCurveReference.f(6e17, 1e18, 1e18, 1e18, 1e18, 0), "fair1 = f(minReserve0)");
        assertTrue(EulerSwapCurveReference.verify(params, fair0, fair1), "verify");
    }

    function testShouldReturnEquilibriumWhenEquilibriumReserveOnMinimumSideIsZero() public pure {
        // rho < 1 puts the minimum on the asset0 side, but x0 = 0 leaves only the equilibrium point there
        IEulerV2Swap.DynamicParams memory params = _params(0, 1e18, 0, 0, 1e18, 1e18, 5e17, 5e17);
        (uint256 fair0, uint256 fair1) = EulerV2SwapFairPointLib.fairPoint(params, _prices(4e18, 1e18, 18, 18));
        assertEq(fair0, 0, "asset0 side: fair0");
        assertEq(fair1, 1e18, "asset0 side: fair1");
        assertTrue(EulerSwapCurveReference.verify(params, fair0, fair1), "asset0 side: verify");

        // Mirror: rho > 1 and y0 = 0
        params = _params(1e18, 0, 0, 0, 1e18, 1e18, 5e17, 5e17);
        (fair0, fair1) = EulerV2SwapFairPointLib.fairPoint(params, _prices(1e18, 4e18, 18, 18));
        assertEq(fair0, 1e18, "asset1 side: fair0");
        assertEq(fair1, 0, "asset1 side: fair1");
        assertTrue(EulerSwapCurveReference.verify(params, fair0, fair1), "asset1 side: verify");
    }

    function testShouldReturnEquilibriumWhenConstantSumCurveOverflowsBelowEquilibrium() public pure {
        // Codex review example: x0 = 100, y0 = uint112.max, constant sum, curve price 1, asset0 worth 2 at the oracle.
        // f(x) = y0 + (x0 - x) leaves uint112 for every x < x0, so the equilibrium is the only point of that side.
        // Truncating f at uint112.max would give (0, uint112.max), which verify rejects.
        IEulerV2Swap.DynamicParams memory params = _params(100, MAX_RESERVE, 0, 0, 1e18, 1e18, WAD, WAD);

        (uint256 fair0, uint256 fair1) = EulerV2SwapFairPointLib.fairPoint(params, _prices(2e18, 1e18, 18, 18));
        assertEq(fair0, 100, "fair0");
        assertEq(fair1, MAX_RESERVE, "fair1");
        assertTrue(EulerSwapCurveReference.verify(params, fair0, fair1), "verify");
        assertFalse(EulerSwapCurveReference.verify(params, 99, MAX_RESERVE), "one unit lower is rejected");
        assertFalse(EulerSwapCurveReference.verify(params, 0, MAX_RESERVE), "truncated point is rejected");
    }

    function testShouldMoveToOverflowBoundaryInsideIntervalOnConcentratedAssetZeroSide() public pure {
        // c = 0, curve price 1, asset0 worth 1e12 x asset1: the closed form a0 = x0 * 1e-6 = 1e24 lies where
        // f = y0 + (x0 - x) * x0 / x exceeds uint112, so the point moves up to the boundary near x0^2 / uint112.max
        IEulerV2Swap.DynamicParams memory params = _params(1e30, 0, 0, 0, 1e18, 1e18, 0, 0);
        _assertInteriorOverflowBoundaryOnAssetZeroSide(params, _prices(1e30, 1e18, 18, 18));
    }

    function testShouldMoveToOverflowBoundaryInsideIntervalOnConstantSumAssetZeroSide() public pure {
        // Constant sum, curve price 1, y0 = uint112.max - 1e20: f fits exactly for x >= x0 - 1e20
        IEulerV2Swap.DynamicParams memory params = _params(1e30, MAX_RESERVE - 1e20, 0, 0, 1e18, 1e18, WAD, WAD);
        (uint256 fair0, uint256 fair1) = _assertInteriorOverflowBoundaryOnAssetZeroSide(
            params,
            _prices(2e18, 1e18, 18, 18)
        );
        assertEq(fair0, 1e30 - 1e20, "fair0 = x0 - (uint112.max - y0) * py / px");
        assertEq(fair1, MAX_RESERVE, "fair1");
    }

    function testShouldMoveToOverflowBoundaryInsideIntervalOnConcentratedAssetOneSide() public pure {
        IEulerV2Swap.DynamicParams memory params = _params(0, 1e30, 0, 0, 1e18, 1e18, 0, 0);
        _assertInteriorOverflowBoundaryOnAssetOneSide(params, _prices(1e18, 1e30, 18, 18));
    }

    function testShouldMoveToOverflowBoundaryInsideIntervalOnConstantSumAssetOneSide() public pure {
        // Constant sum with curve prices 3 : 1 (px : py) and asset1 worth 1e6 USD: on the asset1 side
        // x = x0 + ceil((y0 - y) * py / px) fits for y >= y0 - floor((uint112.max - x0) * px / py)
        uint256 equilibrium0 = MAX_RESERVE - 3e20;
        IEulerV2Swap.DynamicParams memory params = _params(equilibrium0, 1e30, 0, 0, 3e18, 1e18, WAD, WAD);
        (uint256 fair0, uint256 fair1) = _assertInteriorOverflowBoundaryOnAssetOneSide(
            params,
            _prices(1e18, 1e24, 18, 18)
        );
        assertEq(fair1, 1e30 - 9e20, "fair1 = y0 - (uint112.max - x0) * px / py");
        assertEq(fair0, MAX_RESERVE, "fair0");
    }

    function testShouldMoveToOverflowBoundaryWithMinReserveBelowIt() public pure {
        // minReserve0 below the boundary does not change the point; the boundary is above the closed form
        IEulerV2Swap.DynamicParams memory params = _params(1e30, 0, 1e20, 0, 1e18, 1e18, 999e15, 0);
        _assertInteriorOverflowBoundaryOnAssetZeroSide(params, _prices(1e34, 1e18, 18, 18));
    }

    function testShouldBookDonationAndCurvePushOneForOne() public pure {
        // Fair point at (x0 / 2, y0 + x0) from the closed-form test, asset0 worth 4 USD, asset1 1 USD
        IEulerV2Swap.DynamicParams memory params = _params(1e18, 1e18, 0, 0, 1e18, 1e18, 0, 0);
        EulerV2SwapFairPointLib.AssetPrices memory prices = _prices(4e18, 1e18, 18, 18);

        uint256 base = EulerV2SwapFairPointLib.poolDisplacementWad(params, 1e18, 1e18, prices);

        // Donation of 300 asset1 (credit pump): d grows by its oracle value, 300 USD
        assertEq(
            EulerV2SwapFairPointLib.poolDisplacementWad(params, 1e18, 1e18 + 300e18, prices) - base,
            300e18,
            "donation"
        );

        // Curve push: take 0.25 asset0 out, pay f(0.75) - y0 of asset1; d grows by the oracle value of the trade
        uint256 pushed1 = EulerSwapCurveReference.f(75e16, 1e18, 1e18, 1e18, 1e18, 0);
        assertEq(
            EulerV2SwapFairPointLib.poolDisplacementWad(params, 75e16, pushed1, prices),
            base + (pushed1 - 1e18) - 4 * 25e16,
            "curve push"
        );
    }

    function testShouldNotDependOnReserves() public pure {
        IEulerV2Swap.DynamicParams memory params = _params(7e20, 3e21, 1e3, 1e3, 2e18, 5e17, 8e17, 3e17);
        EulerV2SwapFairPointLib.AssetPrices memory prices = _prices(3e21, 1e18, 8, 18);

        (uint256 fair0, uint256 fair1) = EulerV2SwapFairPointLib.fairPoint(params, prices);
        uint256 atFair = EulerV2SwapFairPointLib.poolDisplacementWad(params, fair0, fair1, prices);
        uint256 atEquilibrium = EulerV2SwapFairPointLib.poolDisplacementWad(params, 7e20, 3e21, prices);

        assertLe(atFair, 2, "d at the fair point is rounding only");
        assertEq(
            atEquilibrium,
            _valueUp(7e20, 3e21, prices) - _valueDown(fair0, fair1, prices),
            "d at equilibrium = value(equilibrium) - value(fair point)"
        );
    }

    function testCurveMatchesReferenceAtCorners() public pure {
        uint256[6][9] memory cases = [
            // [x, px, py, x0, y0, c]
            [uint256(0), 1e18, 1e18, 1e18, 1e18, 5e17], // x = 0 on a concentrated curve: divisor 0 -> overflow
            [uint256(0), 1e18, 1e18, 1e18, 1e18, WAD], // x = 0 on a constant-sum curve
            [uint256(1e18), 1e18, 1e18, 1e18, 1e18, 5e17], // x = x0
            [uint256(1), 1e24, 1, MAX_RESERVE, 0, 0], // saturating mulDiv
            [uint256(1), 1, 1e24, MAX_RESERVE, MAX_RESERVE, 0], // y0 = uint112.max: any v > 0 overflows
            [uint256(MAX_RESERVE - 1), 1e24, 1, MAX_RESERVE, MAX_RESERVE - 1e30, 1], // near the top
            [uint256(12345), 777, 1e24, 1e30, 0, 1e18 - 1], // c = 1e18 - 1
            [uint256(5), 1e24, 1e24, 1e6, MAX_RESERVE - 1e30, WAD], // constant sum, near the top
            [uint256(5), 1e24, 1, 1e6, MAX_RESERVE - 1e29, WAD] // constant sum overflow
        ];
        for (uint256 i; i < cases.length; ++i) {
            uint256[6] memory c = cases[i];
            assertEq(
                EulerV2SwapFairPointLib.f(c[0], c[1], c[2], c[3], c[4], c[5]),
                EulerSwapCurveReference.f(c[0], c[1], c[2], c[3], c[4], c[5]),
                "f corner"
            );
        }
        assertEq(EulerV2SwapFairPointLib.f(0, 1e18, 1e18, 1e18, 1e18, 5e17), type(uint256).max, "x = 0 overflows");
        assertEq(EulerV2SwapFairPointLib.f(1e18, 1e18, 1e18, 1e18, 7, 5e17), 7, "f(x0) = y0");
    }

    function testShouldRevertOnZeroOraclePrice() public {
        IEulerV2Swap.DynamicParams memory params = _params(1e18, 1e18, 0, 0, 1e18, 1e18, 5e17, 5e17);

        vm.expectRevert(EulerV2SwapFairPointLib.EulerV2SwapFairPointZeroPrice.selector);
        harness.fairPoint(params, _prices(0, 1e18, 18, 18));

        vm.expectRevert(EulerV2SwapFairPointLib.EulerV2SwapFairPointZeroPrice.selector);
        harness.poolDisplacementWad(params, 1e18, 1e18, _prices(1e18, 0, 18, 18));
    }

    function testShouldRevertOnUnsupportedDecimals() public {
        IEulerV2Swap.DynamicParams memory params = _params(1e18, 1e18, 0, 0, 1e18, 1e18, 5e17, 5e17);

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapFairPointLib.EulerV2SwapFairPointUnsupportedDecimals.selector,
                uint256(37),
                uint256(18)
            )
        );
        harness.fairPoint(params, _prices(1e18, 1e18, 37, 18));
    }

    function testShouldRevertOnCurveOutsideActivationDomain() public {
        EulerV2SwapFairPointLib.AssetPrices memory prices = _prices(1e18, 1e18, 18, 18);

        vm.expectRevert(EulerV2SwapFairPointLib.EulerV2SwapFairPointInvalidCurve.selector);
        harness.fairPoint(_params(1e18, 1e18, 0, 0, 0, 1e18, 5e17, 5e17), prices);

        vm.expectRevert(EulerV2SwapFairPointLib.EulerV2SwapFairPointInvalidCurve.selector);
        harness.fairPoint(_params(1e18, 1e18, 0, 0, 1e18, 0, 5e17, 5e17), prices);

        vm.expectRevert(EulerV2SwapFairPointLib.EulerV2SwapFairPointInvalidCurve.selector);
        harness.fairPoint(_params(1e18, 1e18, 0, 0, 1e18, 1e18, WAD + 1, 5e17), prices);

        vm.expectRevert(EulerV2SwapFairPointLib.EulerV2SwapFairPointInvalidCurve.selector);
        harness.fairPoint(_params(1e18, 1e18, 0, 0, 1e18, 1e18, 5e17, WAD + 1), prices);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Overflow boundary assertions
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The fair point sits strictly inside (lowest, x0) at the overflow boundary: accepted by verify, f fits there,
    ///      one unit lower f overflows and no reserve1 makes it acceptable
    function _assertInteriorOverflowBoundaryOnAssetZeroSide(
        IEulerV2Swap.DynamicParams memory params_,
        EulerV2SwapFairPointLib.AssetPrices memory prices_
    ) internal pure returns (uint256 fair0, uint256 fair1) {
        (fair0, fair1) = EulerV2SwapFairPointLib.fairPoint(params_, prices_);
        assertGt(fair0, Math.max(params_.minReserve0, 1), "boundary above the lowest reserve");
        assertLt(fair0, params_.equilibriumReserve0, "boundary below equilibrium");
        assertTrue(EulerSwapCurveReference.verify(params_, fair0, fair1), "boundary accepted by verify");
        assertEq(fair1, _referenceCurve0(params_, fair0), "fair1 = f(fair0), not truncated");
        assertEq(_referenceCurve0(params_, fair0 - 1), type(uint256).max, "f overflows one unit lower");
        assertFalse(EulerSwapCurveReference.verify(params_, fair0 - 1, MAX_RESERVE), "one unit lower rejected");
        assertLe(
            _valueDown(fair0, fair1, prices_),
            _valueUp(params_.equilibriumReserve0, params_.equilibriumReserve1, prices_),
            "cheaper than equilibrium"
        );
    }

    function _assertInteriorOverflowBoundaryOnAssetOneSide(
        IEulerV2Swap.DynamicParams memory params_,
        EulerV2SwapFairPointLib.AssetPrices memory prices_
    ) internal pure returns (uint256 fair0, uint256 fair1) {
        (fair0, fair1) = EulerV2SwapFairPointLib.fairPoint(params_, prices_);
        assertGt(fair1, Math.max(params_.minReserve1, 1), "boundary above the lowest reserve");
        assertLt(fair1, params_.equilibriumReserve1, "boundary below equilibrium");
        assertTrue(EulerSwapCurveReference.verify(params_, fair0, fair1), "boundary accepted by verify");
        assertEq(fair0, _referenceCurve1(params_, fair1), "fair0 = f(fair1), not truncated");
        assertEq(_referenceCurve1(params_, fair1 - 1), type(uint256).max, "f overflows one unit lower");
        assertFalse(EulerSwapCurveReference.verify(params_, MAX_RESERVE, fair1 - 1), "one unit lower rejected");
        assertLe(
            _valueDown(fair0, fair1, prices_),
            _valueUp(params_.equilibriumReserve0, params_.equilibriumReserve1, prices_),
            "cheaper than equilibrium"
        );
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Numeric minimisation on the reference curve
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Lowest oracle value over the points accepted by the reference verify: the equilibrium and the cheapest
    ///      accepted point of each side found numerically (no closed form involved)
    function _numericMinimum(
        IEulerV2Swap.DynamicParams memory params_,
        EulerV2SwapFairPointLib.AssetPrices memory prices_
    ) internal pure returns (uint256 minimum) {
        minimum = _valueDown(params_.equilibriumReserve0, params_.equilibriumReserve1, prices_);
        minimum = Math.min(minimum, _numericSideMinimum(params_, prices_, true));
        minimum = Math.min(minimum, _numericSideMinimum(params_, prices_, false));
    }

    /// @dev Ternary search over the own reserve of one side, z in [0, equilibrium], of value(z, f(z)) (infinite where
    ///      verify rejects), then a scan of SCAN_WINDOW points around the final bracket. Rejected points form a prefix
    ///      of the interval (f is monotonic), so the search moves right while both probes are rejected.
    function _numericSideMinimum(
        IEulerV2Swap.DynamicParams memory params_,
        EulerV2SwapFairPointLib.AssetPrices memory prices_,
        bool assetZeroSide_
    ) internal pure returns (uint256 minimum) {
        uint256 low;
        uint256 high = assetZeroSide_ ? params_.equilibriumReserve0 : params_.equilibriumReserve1;
        uint256 equilibrium = high;

        while (high - low > 2) {
            uint256 third = (high - low) / 3;
            uint256 probe1 = low + third;
            uint256 probe2 = high - third;
            uint256 value1 = _sideValue(params_, prices_, assetZeroSide_, probe1);
            uint256 value2 = _sideValue(params_, prices_, assetZeroSide_, probe2);
            if (value1 != INFINITE && value1 <= value2) {
                high = probe2;
            } else {
                low = probe1;
            }
        }

        minimum = INFINITE;
        uint256 from = low > SCAN_WINDOW ? low - SCAN_WINDOW : 0;
        uint256 to = Math.min(high + SCAN_WINDOW, equilibrium);
        for (uint256 z = from; z <= to; ++z) {
            minimum = Math.min(minimum, _sideValue(params_, prices_, assetZeroSide_, z));
        }
    }

    function _sideValue(
        IEulerV2Swap.DynamicParams memory params_,
        EulerV2SwapFairPointLib.AssetPrices memory prices_,
        bool assetZeroSide_,
        uint256 own_
    ) internal pure returns (uint256) {
        uint256 reserve0;
        uint256 reserve1;
        if (assetZeroSide_) {
            reserve0 = own_;
            reserve1 = _referenceCurve0(params_, own_);
        } else {
            reserve0 = _referenceCurve1(params_, own_);
            reserve1 = own_;
        }
        if (!EulerSwapCurveReference.verify(params_, reserve0, reserve1)) {
            return INFINITE;
        }
        return _valueDown(reserve0, reserve1, prices_);
    }

    function _referenceCurve0(IEulerV2Swap.DynamicParams memory params_, uint256 x_) internal pure returns (uint256) {
        return
            EulerSwapCurveReference.f(
                x_,
                params_.priceX,
                params_.priceY,
                params_.equilibriumReserve0,
                params_.equilibriumReserve1,
                params_.concentrationX
            );
    }

    function _referenceCurve1(IEulerV2Swap.DynamicParams memory params_, uint256 y_) internal pure returns (uint256) {
        return
            EulerSwapCurveReference.f(
                y_,
                params_.priceY,
                params_.priceX,
                params_.equilibriumReserve1,
                params_.equilibriumReserve0,
                params_.concentrationY
            );
    }

    /// @dev Criterion 6d: 2 base units of each asset at its oracle price (rounded up, so at least 1 wei each) plus
    ///      1e-12 of the value
    function _tolerance(
        uint256 value_,
        EulerV2SwapFairPointLib.AssetPrices memory prices_
    ) internal pure returns (uint256) {
        return
            2 * Math.mulDiv(1, prices_.price0Wad, 10 ** prices_.decimals0, Math.Rounding.Ceil) +
            2 * Math.mulDiv(1, prices_.price1Wad, 10 ** prices_.decimals1, Math.Rounding.Ceil) +
            value_ / 1e12;
    }

    /// @dev Independent of the library: oracle value with each term rounded down
    function _valueDown(
        uint256 amount0_,
        uint256 amount1_,
        EulerV2SwapFairPointLib.AssetPrices memory prices_
    ) internal pure returns (uint256) {
        return
            Math.mulDiv(amount0_, prices_.price0Wad, 10 ** prices_.decimals0) +
            Math.mulDiv(amount1_, prices_.price1Wad, 10 ** prices_.decimals1);
    }

    function _valueUp(
        uint256 amount0_,
        uint256 amount1_,
        EulerV2SwapFairPointLib.AssetPrices memory prices_
    ) internal pure returns (uint256) {
        return
            Math.mulDiv(amount0_, prices_.price0Wad, 10 ** prices_.decimals0, Math.Rounding.Ceil) +
            Math.mulDiv(amount1_, prices_.price1Wad, 10 ** prices_.decimals1, Math.Rounding.Ceil);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fuzz input mapping
    // ---------------------------------------------------------------------------------------------------------------

    function _build(
        CurveSeed memory seed_
    )
        internal
        pure
        returns (IEulerV2Swap.DynamicParams memory params, EulerV2SwapFairPointLib.AssetPrices memory prices)
    {
        uint256 equilibrium0 = _reserve(seed_.equilibrium0);
        uint256 equilibrium1 = _reserve(seed_.equilibrium1);
        params = _params(
            equilibrium0,
            equilibrium1,
            _minReserve(seed_.min0, equilibrium0),
            _minReserve(seed_.min1, equilibrium1),
            _curvePrice(seed_.priceX),
            _curvePrice(seed_.priceY),
            _concentration(seed_.concentrationX),
            _concentration(seed_.concentrationY)
        );
        prices = _prices(
            _oraclePrice(seed_.oracle0),
            _oraclePrice(seed_.oracle1),
            6 + (seed_.decimals0 % 13),
            6 + (seed_.decimals1 % 13)
        );
    }

    /// @dev A point on the reference curve (either side), or the equilibrium when the drawn reserve is rejected
    function _acceptedPoint(
        IEulerV2Swap.DynamicParams memory params_,
        uint256 seed_
    ) internal pure returns (uint256 reserve0, uint256 reserve1) {
        if (seed_ % 2 == 0) {
            reserve0 = _below(seed_ >> 1, params_.equilibriumReserve0);
            reserve1 = _referenceCurve0(params_, reserve0);
        } else {
            reserve1 = _below(seed_ >> 1, params_.equilibriumReserve1);
            reserve0 = _referenceCurve1(params_, reserve1);
        }
        if (!EulerSwapCurveReference.verify(params_, reserve0, reserve1)) {
            (reserve0, reserve1) = (params_.equilibriumReserve0, params_.equilibriumReserve1);
        }
    }

    /// @dev Reserve in [0, uint112.max], log-uniform with the corners 0, 1 and uint112.max
    function _reserve(uint256 seed_) internal pure returns (uint256) {
        uint256 kind = seed_ % 16;
        if (kind == 0) return 0;
        if (kind == 1) return 1;
        if (kind == 2) return MAX_RESERVE;
        uint256 bits = 1 + ((seed_ >> 8) % 112);
        return uint256(keccak256(abi.encode(seed_, "reserve"))) >> (256 - bits);
    }

    /// @dev Value in [0, max_], log-uniform with the corners 0, 1, max_ - 1 and max_
    function _below(uint256 seed_, uint256 max_) internal pure returns (uint256) {
        uint256 kind = seed_ % 8;
        if (kind == 0 || max_ == 0) return 0;
        if (kind == 1) return max_;
        if (kind == 2) return max_ - 1;
        if (kind == 3) return 1;
        uint256 bits = 1 + ((seed_ >> 8) % 256);
        return (uint256(keccak256(abi.encode(seed_, "below"))) >> (256 - bits)) % (max_ + 1);
    }

    /// @dev minReserve in [0, equilibrium] with the corners 0 and equilibrium
    function _minReserve(uint256 seed_, uint256 equilibrium_) internal pure returns (uint256) {
        uint256 kind = seed_ % 8;
        if (kind == 0 || kind == 1) return 0;
        if (kind == 2) return equilibrium_;
        return _below(seed_ >> 3, equilibrium_);
    }

    /// @dev Curve price in [1, 1e24] (EulerSwap activation bound), log-uniform with the corners 1, 1e18 and 1e24
    function _curvePrice(uint256 seed_) internal pure returns (uint256) {
        uint256 kind = seed_ % 8;
        if (kind == 0) return 1;
        if (kind == 1) return 1e18;
        if (kind == 2) return 1e24;
        uint256 bits = 1 + ((seed_ >> 8) % 80);
        return 1 + ((uint256(keccak256(abi.encode(seed_, "curve"))) >> (256 - bits)) % 1e24);
    }

    /// @dev Concentration in [0, 1e18] with the corners 0, 1, 0.5, 0.999, 1 - 1e-18 and 1
    function _concentration(uint256 seed_) internal pure returns (uint256) {
        uint256 kind = seed_ % 9;
        if (kind == 0) return 0;
        if (kind == 1) return 1;
        if (kind == 2) return 5e17;
        if (kind == 3) return 999e15;
        if (kind == 4) return WAD - 1;
        if (kind == 5) return WAD;
        return (seed_ >> 8) % (WAD + 1);
    }

    /// @dev Oracle price of one whole token, WAD: log-uniform over about 1e4 .. 1e34 (1e-14 .. 1e16 USD), corner 1 USD
    function _oraclePrice(uint256 seed_) internal pure returns (uint256) {
        if (seed_ % 4 == 0) return 1e18;
        uint256 bits = 14 + ((seed_ >> 8) % 100);
        return (uint256(keccak256(abi.encode(seed_, "oracle"))) >> (256 - bits)) | (1 << (bits - 1));
    }

    function _params(
        uint256 equilibrium0_,
        uint256 equilibrium1_,
        uint256 min0_,
        uint256 min1_,
        uint256 priceX_,
        uint256 priceY_,
        uint256 concentrationX_,
        uint256 concentrationY_
    ) internal pure returns (IEulerV2Swap.DynamicParams memory params) {
        params.equilibriumReserve0 = uint112(equilibrium0_);
        params.equilibriumReserve1 = uint112(equilibrium1_);
        params.minReserve0 = uint112(min0_);
        params.minReserve1 = uint112(min1_);
        params.priceX = uint80(priceX_);
        params.priceY = uint80(priceY_);
        params.concentrationX = uint64(concentrationX_);
        params.concentrationY = uint64(concentrationY_);
    }

    function _prices(
        uint256 price0Wad_,
        uint256 price1Wad_,
        uint256 decimals0_,
        uint256 decimals1_
    ) internal pure returns (EulerV2SwapFairPointLib.AssetPrices memory) {
        return
            EulerV2SwapFairPointLib.AssetPrices({
                price0Wad: price0Wad_,
                price1Wad: price1Wad_,
                decimals0: decimals0_,
                decimals1: decimals1_
            });
    }
}
