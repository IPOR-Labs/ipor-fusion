// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IporMath} from "../../contracts/libraries/math/IporMath.sol";

contract IporMathTest is Test {
    function testConvertToWadWhenSameDecimals() public {
        // given
        uint256 value = 1e18;
        uint256 assetDecimals = 18;

        // when
        uint256 result = IporMath.convertToWad(value, assetDecimals);

        // then
        assertEq(result, value, "Should return same value when decimals are equal to WAD");
    }

    function testConvertToWadWhenMoreDecimals() public {
        // given
        uint256 value = 1e24;
        uint256 assetDecimals = 24;
        uint256 expected = 1e18;

        // when
        uint256 result = IporMath.convertToWad(value, assetDecimals);

        // then
        assertEq(result, expected, "Should divide by 10^(assetDecimals - WAD_DECIMALS)");
    }

    function testConvertToWadWhenLessDecimals() public {
        // given
        uint256 value = 1e6;
        uint256 assetDecimals = 6;
        uint256 expected = 1e18;

        // when
        uint256 result = IporMath.convertToWad(value, assetDecimals);

        // then
        assertEq(result, expected, "Should multiply by 10^(WAD_DECIMALS - assetDecimals)");
    }

    function testConvertToWadWithZeroValue() public {
        // given
        uint256 value = 0;
        uint256 assetDecimals = 6;

        // when
        uint256 result = IporMath.convertToWad(value, assetDecimals);

        // then
        assertEq(result, 0, "Should return 0 when input is 0");
    }

    function testConvertToWadWithLargeValue() public {
        // given
        uint256 value = 1000e6; // 1000 in 6 decimals
        uint256 assetDecimals = 6;
        uint256 expected = 1000e18; // 1000 in WAD

        // when
        uint256 result = IporMath.convertToWad(value, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert large values");
    }

    function testConvertToWadWithSmallValue() public {
        // given
        uint256 value = 1e3; // 0.001 in 6 decimals
        uint256 assetDecimals = 6;
        uint256 expected = 1e15; // 0.001 in WAD

        // when
        uint256 result = IporMath.convertToWad(value, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert small values");
    }

    function testConvertToWadWithMaxDecimals() public {
        // given
        uint256 value = 1e36;
        uint256 assetDecimals = 36;
        uint256 expected = 1e18;

        // when
        uint256 result = IporMath.convertToWad(value, assetDecimals);

        // then
        assertEq(result, expected, "Should handle maximum decimal conversion");
    }

    function testConvertToWadWithMinDecimals() public {
        // given
        uint256 value = 1e1;
        uint256 assetDecimals = 1;
        uint256 expected = 1e18;

        // when
        uint256 result = IporMath.convertToWad(value, assetDecimals);

        // then
        assertEq(result, expected, "Should handle minimum decimal conversion");
    }

    function testConvertWadToAssetDecimalsWhenSameDecimals() public {
        // given
        uint256 wadValue = 1e18;
        uint256 assetDecimals = 18;

        // when
        uint256 result = IporMath.convertWadToAssetDecimals(wadValue, assetDecimals);

        // then
        assertEq(result, wadValue, "Should return same value when decimals are equal to WAD");
    }

    function testConvertWadToAssetDecimalsWhenMoreDecimals() public {
        // given
        uint256 wadValue = 1e18;
        uint256 assetDecimals = 24;
        uint256 expected = 1e24;

        // when
        uint256 result = IporMath.convertWadToAssetDecimals(wadValue, assetDecimals);

        // then
        assertEq(result, expected, "Should multiply by 10^(assetDecimals - WAD_DECIMALS)");
    }

    function testConvertWadToAssetDecimalsWhenLessDecimals() public {
        // given
        uint256 wadValue = 1e18;
        uint256 assetDecimals = 6;
        uint256 expected = 1e6;

        // when
        uint256 result = IporMath.convertWadToAssetDecimals(wadValue, assetDecimals);

        // then
        assertEq(result, expected, "Should divide by 10^(WAD_DECIMALS - assetDecimals)");
    }

    function testConvertWadToAssetDecimalsWithZeroValue() public {
        // given
        uint256 wadValue = 0;
        uint256 assetDecimals = 6;

        // when
        uint256 result = IporMath.convertWadToAssetDecimals(wadValue, assetDecimals);

        // then
        assertEq(result, 0, "Should return 0 when input is 0");
    }

    function testConvertWadToAssetDecimalsWithLargeValue() public {
        // given
        uint256 wadValue = 1000e18; // 1000 in WAD
        uint256 assetDecimals = 6;
        uint256 expected = 1000e6; // 1000 in 6 decimals

        // when
        uint256 result = IporMath.convertWadToAssetDecimals(wadValue, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert large values");
    }

    function testConvertWadToAssetDecimalsWithSmallValue() public {
        // given
        uint256 wadValue = 1e15; // 0.001 in WAD
        uint256 assetDecimals = 6;
        uint256 expected = 1e3; // 0.001 in 6 decimals

        // when
        uint256 result = IporMath.convertWadToAssetDecimals(wadValue, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert small values");
    }

    function testConvertWadToAssetDecimalsWithMaxDecimals() public {
        // given
        uint256 wadValue = 1e18;
        uint256 assetDecimals = 36;
        uint256 expected = 1e36;

        // when
        uint256 result = IporMath.convertWadToAssetDecimals(wadValue, assetDecimals);

        // then
        assertEq(result, expected, "Should handle maximum decimal conversion");
    }

    function testConvertWadToAssetDecimalsWithMinDecimals() public {
        // given
        uint256 wadValue = 1e18;
        uint256 assetDecimals = 1;
        uint256 expected = 1e1;

        // when
        uint256 result = IporMath.convertWadToAssetDecimals(wadValue, assetDecimals);

        // then
        assertEq(result, expected, "Should handle minimum decimal conversion");
    }

    function testConvertToWadIntWhenSameDecimals() public {
        // given
        int256 value = 1e18;
        uint256 assetDecimals = 18;

        // when
        int256 result = IporMath.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, value, "Should return same value when decimals are equal to WAD");
    }

    function testConvertToWadIntWhenMoreDecimals() public {
        // given
        int256 value = 1e24;
        uint256 assetDecimals = 24;
        int256 expected = 1e18;

        // when
        int256 result = IporMath.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should divide by 10^(assetDecimals - WAD_DECIMALS)");
    }

    function testConvertToWadIntWhenLessDecimals() public {
        // given
        int256 value = 1e6;
        uint256 assetDecimals = 6;
        int256 expected = 1e18;

        // when
        int256 result = IporMath.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should multiply by 10^(WAD_DECIMALS - assetDecimals)");
    }

    function testConvertToWadIntWithZeroValue() public {
        // given
        int256 value = 0;
        uint256 assetDecimals = 6;

        // when
        int256 result = IporMath.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, 0, "Should return 0 when input is 0");
    }

    function testConvertToWadIntWithLargePositiveValue() public {
        // given
        int256 value = 1000e6; // 1000 in 6 decimals
        uint256 assetDecimals = 6;
        int256 expected = 1000e18; // 1000 in WAD

        // when
        int256 result = IporMath.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert large positive values");
    }

    function testConvertToWadIntWithSmallPositiveValue() public {
        // given
        int256 value = 1e3; // 0.001 in 6 decimals
        uint256 assetDecimals = 6;
        int256 expected = 1e15; // 0.001 in WAD

        // when
        int256 result = IporMath.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert small positive values");
    }

    function testConvertToWadIntWithNegativeValue() public {
        // given
        int256 value = -1e6; // -1 in 6 decimals
        uint256 assetDecimals = 6;
        int256 expected = -1e18; // -1 in WAD

        // when
        int256 result = IporMath.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert negative values");
    }

    function testConvertToWadIntWithLargeNegativeValue() public {
        // given
        int256 value = -1000e6; // -1000 in 6 decimals
        uint256 assetDecimals = 6;
        int256 expected = -1000e18; // -1000 in WAD

        // when
        int256 result = IporMath.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert large negative values");
    }

    function testConvertToWadIntWithSmallNegativeValue() public {
        // given
        int256 value = -1e3; // -0.001 in 6 decimals
        uint256 assetDecimals = 6;
        int256 expected = -1e15; // -0.001 in WAD

        // when
        int256 result = IporMath.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should correctly convert small negative values");
    }

    function testConvertToWadIntWithMaxDecimals() public {
        // given
        int256 value = 1e36;
        uint256 assetDecimals = 36;
        int256 expected = 1e18;

        // when
        int256 result = IporMath.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should handle maximum decimal conversion");
    }

    function testConvertToWadIntWithMinDecimals() public {
        // given
        int256 value = 1e1;
        uint256 assetDecimals = 1;
        int256 expected = 1e18;

        // when
        int256 result = IporMath.convertToWadInt(value, assetDecimals);

        // then
        assertEq(result, expected, "Should handle minimum decimal conversion");
    }

    function testDivisionIntPositiveByPositive() public {
        // given
        int256 x = 10;
        int256 y = 3;
        int256 expected = 3; // 10/3 = 3.333... rounds to 3

        // when
        int256 result = IporMath.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should correctly divide positive by positive");
    }

    function testDivisionIntNegativeByPositive() public {
        // given
        int256 x = -10;
        int256 y = 3;
        int256 expected = -3; // -10/3 = -3.333... rounds to -3

        // when
        int256 result = IporMath.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should correctly divide negative by positive");
    }

    function testDivisionIntPositiveByNegative() public {
        // given
        int256 x = 10;
        int256 y = -3;
        int256 expected = -3; // 10/-3 = -3.333... rounds to -3

        // when
        int256 result = IporMath.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should correctly divide positive by negative");
    }

    function testDivisionIntNegativeByNegative() public {
        // given
        int256 x = -10;
        int256 y = -3;
        int256 expected = 3; // -10/-3 = 3.333... rounds to 3

        // when
        int256 result = IporMath.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should correctly divide negative by negative");
    }

    function testDivisionIntWithRoundingUp() public {
        // given
        int256 x = 5;
        int256 y = 2;
        int256 expected = 3; // 5/2 = 2.5 rounds to 3

        // when
        int256 result = IporMath.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should round up when remainder is >= half divisor");
    }

    function testDivisionIntWithRoundingDown() public {
        // given
        int256 x = 4;
        int256 y = 3;
        int256 expected = 1; // 4/3 = 1.333... rounds to 1

        // when
        int256 result = IporMath.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should round down when remainder is < half divisor");
    }

    function testDivisionIntWithNegativeRoundingDown() public {
        // given
        int256 x = -4;
        int256 y = 3;
        int256 expected = -1; // -4/3 = -1.333... rounds to -1

        // when
        int256 result = IporMath.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should round towards zero when remainder is small");
    }

    function testDivisionIntWithZeroNumerator() public {
        // given
        int256 x = 0;
        int256 y = 3;
        int256 expected = 0;

        // when
        int256 result = IporMath.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should return 0 when numerator is 0");
    }

    function testDivisionIntWithLargeNumbers() public {
        // given
        int256 x = 1e18;
        int256 y = 1e15;
        int256 expected = 1000; // 1e18/1e15 = 1000

        // when
        int256 result = IporMath.divisionInt(x, y);

        // then
        assertEq(result, expected, "Should handle large numbers correctly");
    }

    function testDivisionIntWithMaxInt256() public {
        // given
        int256 x = type(int256).max;
        int256 y = 2;
        int256 expected = type(int256).max / 2;

        // when
        int256 result = IporMath.divisionInt(x, y);

        // then
        assertApproxEqRel(result, expected, 10, "Should handle maximum int256 value");
    }
}
