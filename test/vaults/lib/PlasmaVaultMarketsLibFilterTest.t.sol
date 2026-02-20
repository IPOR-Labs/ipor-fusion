// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// @title Test harness for PlasmaVaultMarketsLib._filterZeroMarkets
/// @dev Exposes internal _filterZeroMarkets function for testing
/// @notice Since _filterZeroMarkets is private, we recreate the exact same logic for testing
contract FilterZeroMarketsHarness {
    /// @notice Filters zero values from markets array
    /// @param markets_ Array that may contain zero values
    /// @return Compacted array without zero values
    function filterZeroMarkets(uint256[] memory markets_) public pure returns (uint256[] memory) {
        uint256 length = markets_.length;
        if (length == 0) {
            return markets_;
        }

        // Count non-zero elements
        uint256 count;
        for (uint256 i; i < length; ++i) {
            if (markets_[i] != 0) {
                ++count;
            }
        }

        // If all elements are non-zero, return original array
        if (count == length) {
            return markets_;
        }

        // Create compacted array
        uint256[] memory filtered = new uint256[](count);
        uint256 index;
        for (uint256 i; i < length; ++i) {
            if (markets_[i] != 0) {
                filtered[index] = markets_[i];
                ++index;
            }
        }

        return filtered;
    }
}

/// @title PlasmaVaultMarketsLibFilterTest
/// @notice Unit tests for the _filterZeroMarkets function in PlasmaVaultMarketsLib
contract PlasmaVaultMarketsLibFilterTest is Test {
    FilterZeroMarketsHarness public harness;

    function setUp() public {
        harness = new FilterZeroMarketsHarness();
    }

    // ============ Basic Filtering Tests ============

    function testShouldFilterZerosFromMiddle() public view {
        // given
        uint256[] memory input = new uint256[](3);
        input[0] = 100;
        input[1] = 0;
        input[2] = 200;

        // when
        uint256[] memory result = harness.filterZeroMarkets(input);

        // then
        assertEq(result.length, 2, "Should have 2 elements");
        assertEq(result[0], 100, "First element should be 100");
        assertEq(result[1], 200, "Second element should be 200");
    }

    function testShouldFilterZerosFromStart() public view {
        // given
        uint256[] memory input = new uint256[](3);
        input[0] = 0;
        input[1] = 100;
        input[2] = 200;

        // when
        uint256[] memory result = harness.filterZeroMarkets(input);

        // then
        assertEq(result.length, 2, "Should have 2 elements");
        assertEq(result[0], 100, "First element should be 100");
        assertEq(result[1], 200, "Second element should be 200");
    }

    function testShouldFilterZerosFromEnd() public view {
        // given
        uint256[] memory input = new uint256[](3);
        input[0] = 100;
        input[1] = 200;
        input[2] = 0;

        // when
        uint256[] memory result = harness.filterZeroMarkets(input);

        // then
        assertEq(result.length, 2, "Should have 2 elements");
        assertEq(result[0], 100, "First element should be 100");
        assertEq(result[1], 200, "Second element should be 200");
    }

    function testShouldFilterMultipleZeros() public view {
        // given
        uint256[] memory input = new uint256[](5);
        input[0] = 100;
        input[1] = 0;
        input[2] = 200;
        input[3] = 0;
        input[4] = 300;

        // when
        uint256[] memory result = harness.filterZeroMarkets(input);

        // then
        assertEq(result.length, 3, "Should have 3 elements");
        assertEq(result[0], 100, "First element should be 100");
        assertEq(result[1], 200, "Second element should be 200");
        assertEq(result[2], 300, "Third element should be 300");
    }

    // ============ Edge Case Tests ============

    function testShouldReturnEmptyForAllZeros() public view {
        // given
        uint256[] memory input = new uint256[](3);
        input[0] = 0;
        input[1] = 0;
        input[2] = 0;

        // when
        uint256[] memory result = harness.filterZeroMarkets(input);

        // then
        assertEq(result.length, 0, "Should return empty array");
    }

    function testShouldReturnEmptyForEmptyInput() public view {
        // given
        uint256[] memory input = new uint256[](0);

        // when
        uint256[] memory result = harness.filterZeroMarkets(input);

        // then
        assertEq(result.length, 0, "Should return empty array");
    }

    function testShouldReturnSameForNoZeros() public view {
        // given
        uint256[] memory input = new uint256[](3);
        input[0] = 100;
        input[1] = 200;
        input[2] = 300;

        // when
        uint256[] memory result = harness.filterZeroMarkets(input);

        // then
        assertEq(result.length, 3, "Should have 3 elements");
        assertEq(result[0], 100, "First element should be 100");
        assertEq(result[1], 200, "Second element should be 200");
        assertEq(result[2], 300, "Third element should be 300");
    }

    function testShouldHandleSingleZero() public view {
        // given
        uint256[] memory input = new uint256[](1);
        input[0] = 0;

        // when
        uint256[] memory result = harness.filterZeroMarkets(input);

        // then
        assertEq(result.length, 0, "Should return empty array");
    }

    function testShouldHandleSingleNonZero() public view {
        // given
        uint256[] memory input = new uint256[](1);
        input[0] = 100;

        // when
        uint256[] memory result = harness.filterZeroMarkets(input);

        // then
        assertEq(result.length, 1, "Should have 1 element");
        assertEq(result[0], 100, "Element should be 100");
    }

    function testShouldHandleLargeArray() public view {
        // given - 100 elements with every 3rd being zero
        uint256[] memory input = new uint256[](100);
        uint256 expectedCount;
        for (uint256 i; i < 100; ++i) {
            if (i % 3 == 0) {
                input[i] = 0;
            } else {
                input[i] = i + 1;
                ++expectedCount;
            }
        }

        // when
        uint256[] memory result = harness.filterZeroMarkets(input);

        // then
        assertEq(result.length, expectedCount, "Should have correct element count");

        // Verify all non-zero values are preserved in order
        uint256 resultIndex;
        for (uint256 i; i < 100; ++i) {
            if (i % 3 != 0) {
                assertEq(result[resultIndex], i + 1, "Element should be preserved in order");
                ++resultIndex;
            }
        }
    }

    // ============ Order Preservation Tests ============

    function testShouldPreserveOrderAfterFiltering() public view {
        // given
        uint256[] memory input = new uint256[](7);
        input[0] = 0;
        input[1] = 5;
        input[2] = 0;
        input[3] = 10;
        input[4] = 15;
        input[5] = 0;
        input[6] = 20;

        // when
        uint256[] memory result = harness.filterZeroMarkets(input);

        // then
        assertEq(result.length, 4, "Should have 4 elements");
        assertEq(result[0], 5, "First element should be 5");
        assertEq(result[1], 10, "Second element should be 10");
        assertEq(result[2], 15, "Third element should be 15");
        assertEq(result[3], 20, "Fourth element should be 20");
    }

    // ============ Consecutive Zeros Tests ============

    function testShouldHandleConsecutiveZerosAtStart() public view {
        // given
        uint256[] memory input = new uint256[](5);
        input[0] = 0;
        input[1] = 0;
        input[2] = 0;
        input[3] = 100;
        input[4] = 200;

        // when
        uint256[] memory result = harness.filterZeroMarkets(input);

        // then
        assertEq(result.length, 2, "Should have 2 elements");
        assertEq(result[0], 100, "First element should be 100");
        assertEq(result[1], 200, "Second element should be 200");
    }

    function testShouldHandleConsecutiveZerosAtEnd() public view {
        // given
        uint256[] memory input = new uint256[](5);
        input[0] = 100;
        input[1] = 200;
        input[2] = 0;
        input[3] = 0;
        input[4] = 0;

        // when
        uint256[] memory result = harness.filterZeroMarkets(input);

        // then
        assertEq(result.length, 2, "Should have 2 elements");
        assertEq(result[0], 100, "First element should be 100");
        assertEq(result[1], 200, "Second element should be 200");
    }

    // ============ Special Values Tests ============

    function testShouldHandleMaxUint256Values() public view {
        // given
        uint256[] memory input = new uint256[](3);
        input[0] = type(uint256).max;
        input[1] = 0;
        input[2] = type(uint256).max - 1;

        // when
        uint256[] memory result = harness.filterZeroMarkets(input);

        // then
        assertEq(result.length, 2, "Should have 2 elements");
        assertEq(result[0], type(uint256).max, "First element should be max uint256");
        assertEq(result[1], type(uint256).max - 1, "Second element should be max uint256 - 1");
    }

    // ============ Fuzz Tests ============

    function testFuzzFilterZeroMarkets(uint256[] memory input) public view {
        // given - count expected non-zero elements
        uint256 expectedCount;
        for (uint256 i; i < input.length; ++i) {
            if (input[i] != 0) {
                ++expectedCount;
            }
        }

        // when
        uint256[] memory result = harness.filterZeroMarkets(input);

        // then
        assertEq(result.length, expectedCount, "Result length should match non-zero count");

        // Verify all elements in result are non-zero
        for (uint256 i; i < result.length; ++i) {
            assertTrue(result[i] != 0, "Result should not contain zeros");
        }

        // Verify order is preserved
        uint256 resultIndex;
        for (uint256 i; i < input.length; ++i) {
            if (input[i] != 0) {
                assertEq(result[resultIndex], input[i], "Order should be preserved");
                ++resultIndex;
            }
        }
    }

    function testFuzzFilterWithSpecificZeroRatio(uint256 seed, uint8 zeroRatio) public view {
        // given
        vm.assume(zeroRatio <= 100);
        uint256 length = (seed % 50) + 1; // 1 to 50 elements
        uint256[] memory input = new uint256[](length);

        uint256 expectedNonZero;
        for (uint256 i; i < length; ++i) {
            // Determine if this element should be zero based on ratio
            bool shouldBeZero = (uint256(keccak256(abi.encode(seed, i))) % 100) < zeroRatio;
            if (shouldBeZero) {
                input[i] = 0;
            } else {
                input[i] = i + 1;
                ++expectedNonZero;
            }
        }

        // when
        uint256[] memory result = harness.filterZeroMarkets(input);

        // then
        assertEq(result.length, expectedNonZero, "Result length should match expected non-zero count");
    }
}
