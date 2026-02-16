// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IporMath} from "../../contracts/libraries/math/IporMath.sol";

/// @notice Wrapper contract to expose IporMath library functions externally
/// @dev Required for vm.expectRevert to work properly with internal library functions
contract IporMathWrapper {
    function convertToWad(uint256 value_, uint256 assetDecimals_) external pure returns (uint256) {
        return IporMath.convertToWad(value_, assetDecimals_);
    }

    function convertWadToAssetDecimals(uint256 value_, uint256 assetDecimals_) external pure returns (uint256) {
        return IporMath.convertWadToAssetDecimals(value_, assetDecimals_);
    }

    function convertToWadInt(int256 value_, uint256 assetDecimals_) external pure returns (int256) {
        return IporMath.convertToWadInt(value_, assetDecimals_);
    }

    function divisionInt(int256 x_, int256 y_) external pure returns (int256) {
        return IporMath.divisionInt(x_, y_);
    }

    function division(uint256 x_, uint256 y_) external pure returns (uint256) {
        return IporMath.division(x_, y_);
    }

    function min(uint256 a_, uint256 b_) external pure returns (uint256) {
        return IporMath.min(a_, b_);
    }
}

contract IporMathTest is Test {
    IporMathWrapper public wrapper;

    function setUp() public {
        wrapper = new IporMathWrapper();
    }

    function testConvertToWadWhenSameDecimals() public view {
        // given
        uint256 value = 1e18;
        uint256 assetDecimals = 18;

        // when
        uint256 result = wrapper.convertToWad(value, assetDecimals);

        // then
        assertEq(result, value, "Should return same value when decimals are equal to WAD");
    }

    function testConvertToWadWhenMoreDecimals() public view {
        // given
        uint256 value = 1e24;
        uint256 assetDecimals = 24;
        uint256 expected = 1e18;

        // when
        uint256 result = wrapper.convertToWad(value, assetDecimals);

        // then
        assertEq(result, expected, "Should divide by 10^(assetDecimals - WAD_DECIMALS)");
    }

    function testConvertToWadWhenLessDecimals() public view {
        // given
        uint256 value = 1e6;
        uint256 assetDecimals = 6;
        uint256 expected = 1e18;

        // when
        uint256 result = wrapper.convertToWad(value, assetDecimals);

        // then
        assertEq(result, expected, "Should multiply by 10^(WAD_DECIMALS - assetDecimals)");
    }

    function testConvertToWadWithZeroValue() public view {
        // given
        uint256 value = 0;
        uint256 assetDecimals = 6;

        // when
        uint256 result = wrapper.convertToWad(value, assetDecimals);

        // then
        assertEq(result, 0, "Should return 0 when input is 0");
    }

    function testConvertToWadWithLargeValue() public view {
        // given
        uint256 value = 1000e6; // 1000 in 6 decimals
        uint256 assetDecimals = 6;
        uint256 expected = 1000e18; // 1000 in WAD

        // when
        uint256 result = wrapper.convertToWad(value, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert large values");
    }

    function testConvertToWadWithSmallValue() public view {
        // given
        uint256 value = 1e3; // 0.001 in 6 decimals
        uint256 assetDecimals = 6;
        uint256 expected = 1e15; // 0.001 in WAD

        // when
        uint256 result = wrapper.convertToWad(value, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert small values");
    }

    function testConvertToWadWithMaxDecimals() public view {
        // given
        uint256 value = 1e36;
        uint256 assetDecimals = 36;
        uint256 expected = 1e18;

        // when
        uint256 result = wrapper.convertToWad(value, assetDecimals);

        // then
        assertEq(result, expected, "Should handle maximum decimal conversion");
    }

    function testConvertToWadWithMinDecimals() public view {
        // given
        uint256 value = 1e1;
        uint256 assetDecimals = 1;
        uint256 expected = 1e18;

        // when
        uint256 result = wrapper.convertToWad(value, assetDecimals);

        // then
        assertEq(result, expected, "Should handle minimum decimal conversion");
    }

    function testConvertWadToAssetDecimalsWhenSameDecimals() public view {
        // given
        uint256 wadValue = 1e18;
        uint256 assetDecimals = 18;

        // when
        uint256 result = wrapper.convertWadToAssetDecimals(wadValue, assetDecimals);

        // then
        assertEq(result, wadValue, "Should return same value when decimals are equal to WAD");
    }

    function testConvertWadToAssetDecimalsWhenMoreDecimals() public view {
        // given
        uint256 wadValue = 1e18;
        uint256 assetDecimals = 24;
        uint256 expected = 1e24;

        // when
        uint256 result = wrapper.convertWadToAssetDecimals(wadValue, assetDecimals);

        // then
        assertEq(result, expected, "Should multiply by 10^(assetDecimals - WAD_DECIMALS)");
    }

    function testConvertWadToAssetDecimalsWhenLessDecimals() public view {
        // given
        uint256 wadValue = 1e18;
        uint256 assetDecimals = 6;
        uint256 expected = 1e6;

        // when
        uint256 result = wrapper.convertWadToAssetDecimals(wadValue, assetDecimals);

        // then
        assertEq(result, expected, "Should divide by 10^(WAD_DECIMALS - assetDecimals)");
    }

    function testConvertWadToAssetDecimalsWithZeroValue() public view {
        // given
        uint256 wadValue = 0;
        uint256 assetDecimals = 6;

        // when
        uint256 result = wrapper.convertWadToAssetDecimals(wadValue, assetDecimals);

        // then
        assertEq(result, 0, "Should return 0 when input is 0");
    }

    function testConvertWadToAssetDecimalsWithLargeValue() public view {
        // given
        uint256 wadValue = 1000e18; // 1000 in WAD
        uint256 assetDecimals = 6;
        uint256 expected = 1000e6; // 1000 in 6 decimals

        // when
        uint256 result = wrapper.convertWadToAssetDecimals(wadValue, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert large values");
    }

    function testConvertWadToAssetDecimalsWithSmallValue() public view {
        // given
        uint256 wadValue = 1e15; // 0.001 in WAD
        uint256 assetDecimals = 6;
        uint256 expected = 1e3; // 0.001 in 6 decimals

        // when
        uint256 result = wrapper.convertWadToAssetDecimals(wadValue, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert small values");
    }

    function testConvertWadToAssetDecimalsWithMaxDecimals() public view {
        // given
        uint256 wadValue = 1e18;
        uint256 assetDecimals = 36;
        uint256 expected = 1e36;

        // when
        uint256 result = wrapper.convertWadToAssetDecimals(wadValue, assetDecimals);

        // then
        assertEq(result, expected, "Should handle maximum decimal conversion");
    }

    function testConvertWadToAssetDecimalsWithMinDecimals() public view {
        // given
        uint256 wadValue = 1e18;
        uint256 assetDecimals = 1;
        uint256 expected = 1e1;

        // when
        uint256 result = wrapper.convertWadToAssetDecimals(wadValue, assetDecimals);

        // then
        assertEq(result, expected, "Should handle minimum decimal conversion");
    }

    function testConvertToWadIntWhenSameDecimals() public view {
        // given
        int256 value = 1e18;
        uint256 assetDecimals = 18;

        // when
        int256 result = wrapper.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, value, "Should return same value when decimals are equal to WAD");
    }

    function testConvertToWadIntWhenMoreDecimals() public view {
        // given
        int256 value = 1e24;
        uint256 assetDecimals = 24;
        int256 expected = 1e18;

        // when
        int256 result = wrapper.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should divide by 10^(assetDecimals - WAD_DECIMALS)");
    }

    function testConvertToWadIntWhenLessDecimals() public view {
        // given
        int256 value = 1e6;
        uint256 assetDecimals = 6;
        int256 expected = 1e18;

        // when
        int256 result = wrapper.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should multiply by 10^(WAD_DECIMALS - assetDecimals)");
    }

    function testConvertToWadIntWithZeroValue() public view {
        // given
        int256 value = 0;
        uint256 assetDecimals = 6;

        // when
        int256 result = wrapper.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, 0, "Should return 0 when input is 0");
    }

    function testConvertToWadIntWithLargePositiveValue() public view {
        // given
        int256 value = 1000e6; // 1000 in 6 decimals
        uint256 assetDecimals = 6;
        int256 expected = 1000e18; // 1000 in WAD

        // when
        int256 result = wrapper.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert large positive values");
    }

    function testConvertToWadIntWithSmallPositiveValue() public view {
        // given
        int256 value = 1e3; // 0.001 in 6 decimals
        uint256 assetDecimals = 6;
        int256 expected = 1e15; // 0.001 in WAD

        // when
        int256 result = wrapper.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert small positive values");
    }

    function testConvertToWadIntWithNegativeValue() public view {
        // given
        int256 value = -1e6; // -1 in 6 decimals
        uint256 assetDecimals = 6;
        int256 expected = -1e18; // -1 in WAD

        // when
        int256 result = wrapper.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert negative values");
    }

    function testConvertToWadIntWithLargeNegativeValue() public view {
        // given
        int256 value = -1000e6; // -1000 in 6 decimals
        uint256 assetDecimals = 6;
        int256 expected = -1000e18; // -1000 in WAD

        // when
        int256 result = wrapper.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert large negative values");
    }

    function testConvertToWadIntWithSmallNegativeValue() public view {
        // given
        int256 value = -1e3; // -0.001 in 6 decimals
        uint256 assetDecimals = 6;
        int256 expected = -1e15; // -0.001 in WAD

        // when
        int256 result = wrapper.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert small negative values");
    }

    function testConvertToWadIntWithMaxDecimals() public view {
        // given
        int256 value = 1e36;
        uint256 assetDecimals = 36;
        int256 expected = 1e18;

        // when
        int256 result = wrapper.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should handle maximum decimal conversion");
    }

    function testConvertToWadIntWithMinDecimals() public view {
        // given
        int256 value = 1e1;
        uint256 assetDecimals = 1;
        int256 expected = 1e18;

        // when
        int256 result = wrapper.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should handle minimum decimal conversion");
    }

    function testDivisionIntPositiveByPositive() public view {
        // given
        int256 x = 10;
        int256 y = 3;
        int256 expected = 3; // 10/3 = 3.333... rounds to 3

        // when
        int256 result = wrapper.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should correctly divide positive by positive");
    }

    function testDivisionIntNegativeByPositive() public view {
        // given
        int256 x = -10;
        int256 y = 3;
        int256 expected = -3; // -10/3 = -3.333... rounds to -3

        // when
        int256 result = wrapper.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should correctly divide negative by positive");
    }

    function testDivisionIntPositiveByNegative() public view {
        // given
        int256 x = 10;
        int256 y = -3;
        int256 expected = -3; // 10/-3 = -3.333... rounds to -3

        // when
        int256 result = wrapper.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should correctly divide positive by negative");
    }

    function testDivisionIntNegativeByNegative() public view {
        // given
        int256 x = -10;
        int256 y = -3;
        int256 expected = 3; // -10/-3 = 3.333... rounds to 3

        // when
        int256 result = wrapper.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should correctly divide negative by negative");
    }

    function testDivisionIntWithRoundingUp() public view {
        // given
        int256 x = 5;
        int256 y = 2;
        int256 expected = 3; // 5/2 = 2.5 rounds to 3

        // when
        int256 result = wrapper.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should round up when remainder is >= half divisor");
    }

    function testDivisionIntWithRoundingDown() public view {
        // given
        int256 x = 4;
        int256 y = 3;
        int256 expected = 1; // 4/3 = 1.333... rounds to 1

        // when
        int256 result = wrapper.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should round down when remainder is < half divisor");
    }

    function testDivisionIntWithNegativeRoundingDown() public view {
        // given
        int256 x = -4;
        int256 y = 3;
        int256 expected = -1; // -4/3 = -1.333... rounds to -1

        // when
        int256 result = wrapper.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should round towards zero when remainder is small");
    }

    function testDivisionIntWithZeroNumerator() public view {
        // given
        int256 x = 0;
        int256 y = 3;
        int256 expected = 0;

        // when
        int256 result = wrapper.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should return 0 when numerator is 0");
    }

    function testDivisionIntWithLargeNumbers() public view {
        // given
        int256 x = 1e18;
        int256 y = 1e15;
        int256 expected = 1000; // 1e18/1e15 = 1000

        // when
        int256 result = wrapper.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should handle large numbers correctly");
    }

    function testDivisionIntWithMaxInt256() public view {
        // given
        int256 x = type(int256).max;
        int256 y = 2;
        int256 expected = type(int256).max / 2;

        // when
        int256 result = wrapper.divisionInt(x, y);

        // then
        assertApproxEqRel(result, expected, 10, "Should handle maximum int256 value");
    }

    // ============ Overflow Detection Tests - convertToWadInt ============

    function testConvertToWadIntShouldRevertOnPositiveOverflow() public {
        // given
        // A value that would overflow when multiplied by 10^12 (for 6 decimals to 18)
        // type(int256).max / 10^12 + 1 would overflow
        int256 maxSafeValue = type(int256).max / int256(10 ** 12);
        int256 overflowValue = maxSafeValue + 1;
        uint256 assetDecimals = 6;

        // when/then
        vm.expectRevert(IporMath.MathOverflow.selector);
        wrapper.convertToWadInt(overflowValue, assetDecimals);
    }

    function testConvertToWadIntShouldRevertOnNegativeOverflow() public {
        // given
        // A negative value that would overflow when multiplied by 10^12
        int256 maxSafeNegative = type(int256).min / int256(10 ** 12);
        int256 overflowValue = maxSafeNegative - 1;
        uint256 assetDecimals = 6;

        // when/then
        vm.expectRevert(IporMath.MathOverflow.selector);
        wrapper.convertToWadInt(overflowValue, assetDecimals);
    }

    function testConvertToWadIntShouldNotOverflowAtBoundary() public view {
        // given
        // The maximum safe positive value for 6 decimals conversion
        int256 scaleFactor = int256(10 ** 12);
        int256 maxSafeValue = type(int256).max / scaleFactor;
        uint256 assetDecimals = 6;

        // when
        int256 result = wrapper.convertToWadInt(maxSafeValue, assetDecimals);

        // then
        int256 expected = maxSafeValue * scaleFactor;
        assertEq(result, expected, "Should correctly convert at boundary");
    }

    function testConvertToWadIntShouldPreserveSignNearBoundary() public view {
        // given
        int256 scaleFactor = int256(10 ** 12);
        int256 maxSafePositive = type(int256).max / scaleFactor;
        int256 maxSafeNegative = -(type(int256).max / scaleFactor);
        uint256 assetDecimals = 6;

        // when
        int256 positiveResult = wrapper.convertToWadInt(maxSafePositive, assetDecimals);
        int256 negativeResult = wrapper.convertToWadInt(maxSafeNegative, assetDecimals);

        // then
        assertTrue(positiveResult > 0, "Positive value should remain positive");
        assertTrue(negativeResult < 0, "Negative value should remain negative");
    }

    function testConvertToWadIntShouldWorkWithMaxSafePositive() public view {
        // given
        // Test with different decimal values
        int256 scaleFactor0 = int256(10 ** 18); // 0 decimals
        int256 maxSafeValue0 = type(int256).max / scaleFactor0;

        // when
        int256 result = wrapper.convertToWadInt(maxSafeValue0, 0);

        // then
        assertEq(result, maxSafeValue0 * scaleFactor0, "Should work with 0 decimals");
    }

    function testConvertToWadIntShouldWorkWithMaxSafeNegative() public view {
        // given
        int256 scaleFactor = int256(10 ** 12);
        // Use -(max/scale) to avoid type(int256).min issues
        int256 maxSafeNegative = -(type(int256).max / scaleFactor);
        uint256 assetDecimals = 6;

        // when
        int256 result = wrapper.convertToWadInt(maxSafeNegative, assetDecimals);

        // then
        int256 expected = maxSafeNegative * scaleFactor;
        assertEq(result, expected, "Should correctly convert max safe negative");
        assertTrue(result < 0, "Result should be negative");
    }

    function testConvertToWadIntShouldRevertOnMinInt256() public {
        // given
        // type(int256).min cannot be safely negated
        int256 minValue = type(int256).min;
        uint256 assetDecimals = 6;

        // when/then
        vm.expectRevert(IporMath.MathOverflow.selector);
        wrapper.convertToWadInt(minValue, assetDecimals);
    }

    // ============ Overflow Detection Tests - divisionInt ============

    function testDivisionIntShouldRevertOnMinInt256Numerator() public {
        // given
        int256 x = type(int256).min;
        int256 y = 2;

        // when/then
        vm.expectRevert(IporMath.MathOverflow.selector);
        wrapper.divisionInt(x, y);
    }

    function testDivisionIntShouldRevertOnMinInt256Denominator() public {
        // given
        int256 x = 100;
        int256 y = type(int256).min;

        // when/then
        vm.expectRevert(IporMath.MathOverflow.selector);
        wrapper.divisionInt(x, y);
    }

    function testDivisionIntShouldRevertOnBothMinInt256() public {
        // given
        int256 x = type(int256).min;
        int256 y = type(int256).min;

        // when/then
        vm.expectRevert(IporMath.MathOverflow.selector);
        wrapper.divisionInt(x, y);
    }

    // ============ Fuzz Tests for Overflow Detection ============

    function testFuzzConvertToWadIntNoSignFlip(int256 value, uint8 decimalsSeed) public view {
        // Bound decimals between 0 and 17 (where scaling up is needed)
        uint256 assetDecimals = bound(decimalsSeed, 0, 17);

        // Skip type(int256).min as it cannot be safely negated
        vm.assume(value != type(int256).min);

        // Calculate the scale factor
        int256 scaleFactor = int256(10 ** (18 - assetDecimals));

        // Calculate the max safe absolute value
        int256 maxSafeAbs = type(int256).max / scaleFactor;

        // Get absolute value of input
        int256 absValue = value < 0 ? -value : value;

        // Skip values that would overflow
        vm.assume(absValue <= maxSafeAbs);

        // when
        int256 result = wrapper.convertToWadInt(value, assetDecimals);

        // then - sign should never flip
        if (value > 0) {
            assertTrue(result > 0, "Positive value should remain positive");
        } else if (value < 0) {
            assertTrue(result < 0, "Negative value should remain negative");
        } else {
            assertEq(result, 0, "Zero should remain zero");
        }
    }

    function testFuzzConvertToWadIntOverflowDetection(int256 value, uint8 decimalsSeed) public {
        // Bound decimals between 0 and 17 (where scaling up is needed)
        uint256 assetDecimals = bound(decimalsSeed, 0, 17);

        // Skip type(int256).min and zero
        vm.assume(value != type(int256).min);
        vm.assume(value != 0);

        // Calculate the scale factor
        int256 scaleFactor = int256(10 ** (18 - assetDecimals));

        // Calculate the max safe absolute value
        int256 maxSafeAbs = type(int256).max / scaleFactor;

        // Get absolute value of input
        int256 absValue = value < 0 ? -value : value;

        if (absValue > maxSafeAbs) {
            // Should revert for overflow cases
            vm.expectRevert(IporMath.MathOverflow.selector);
            wrapper.convertToWadInt(value, assetDecimals);
        } else {
            // Should succeed for safe values
            int256 result = wrapper.convertToWadInt(value, assetDecimals);
            // Verify result makes sense
            assertEq(result, value * scaleFactor, "Result should be value * scaleFactor");
        }
    }

    function testFuzzDivisionIntNoSignFlip(int256 x, int256 y) public view {
        // Skip zero denominator
        vm.assume(y != 0);

        // Skip type(int256).min values
        vm.assume(x != type(int256).min);
        vm.assume(y != type(int256).min);

        // when
        int256 result = wrapper.divisionInt(x, y);

        // then - verify sign is correct
        bool expectedPositive = (x >= 0 && y > 0) || (x <= 0 && y < 0);

        if (x == 0) {
            assertEq(result, 0, "Zero numerator should give zero result");
        } else if (expectedPositive) {
            assertTrue(result >= 0, "Result should be non-negative");
        } else {
            assertTrue(result <= 0, "Result should be non-positive");
        }
    }

    // ============ Edge Case Tests ============

    function testConvertToWadIntWithExtremeDecimals0() public view {
        // given - 0 decimals means scale factor of 10^18
        int256 scaleFactor = int256(10 ** 18);
        int256 maxSafeValue = type(int256).max / scaleFactor;
        uint256 assetDecimals = 0;

        // when
        int256 result = wrapper.convertToWadInt(maxSafeValue, assetDecimals);

        // then
        assertEq(result, maxSafeValue * scaleFactor, "Should handle 0 decimals");
    }

    function testConvertToWadIntWithExtremeDecimals17() public view {
        // given - 17 decimals means scale factor of 10^1 = 10
        int256 scaleFactor = 10;
        int256 value = 1e50; // A very large value that's safe with scale factor 10
        uint256 assetDecimals = 17;

        // when
        int256 result = wrapper.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, value * scaleFactor, "Should handle 17 decimals");
    }

    function testConvertToWadIntShouldNotRevertWhenAssetDecimalsEquals18() public view {
        // given - When assetDecimals == 18, no scaling is needed
        int256 value = type(int256).min; // Even min value should work
        uint256 assetDecimals = 18;

        // when
        int256 result = wrapper.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, value, "Should return value unchanged when decimals match");
    }

    function testConvertToWadIntShouldRevertWhenAssetDecimalsGreaterThan18WithMinInt256() public {
        // given - When assetDecimals > 18, division is used, which also checks for min
        uint256 assetDecimals = 24;

        // when/then - divisionInt will revert with MathOverflow for type(int256).min
        vm.expectRevert(IporMath.MathOverflow.selector);
        wrapper.convertToWadInt(type(int256).min, assetDecimals);
    }

    function testConvertToWadIntShouldWorkWhenAssetDecimalsGreaterThan18() public view {
        // given - When assetDecimals > 18, division is used
        int256 value = 1e24;
        uint256 assetDecimals = 24;
        int256 expected = 1e18;

        // when
        int256 result = wrapper.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should divide correctly for decimals > 18");
    }
}
