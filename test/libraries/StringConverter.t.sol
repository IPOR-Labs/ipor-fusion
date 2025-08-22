// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StringConverter} from "../../contracts/libraries/StringConverter.sol";

contract StringConverterTest is Test {
    using StringConverter for string;

    function test_toBytes32_emptyString() public {
        string memory empty = "";
        bytes32[] memory result = StringConverter.toBytes32(empty);

        assertEq(result.length, 0, "Empty string should return empty array");
    }

    function test_toBytes32_singleCharacter() public {
        string memory single = "a";
        bytes32[] memory result = StringConverter.toBytes32(single);

        assertEq(result.length, 1, "Single character should return array of length 1");
        assertEq(result[0], bytes32(uint256(uint8(bytes1("a")))), "First character should be 'a'");
    }

    function test_toBytes32_exactly32Characters() public {
        string memory exactly32 = "abcdefghijklmnopqrstuvwxyz123456";
        bytes32[] memory result = StringConverter.toBytes32(exactly32);

        assertEq(result.length, 1, "Exactly 32 characters should return array of length 1");

        // Verify the packed bytes32 contains all characters
        bytes32 expected = 0;
        for (uint256 i = 0; i < 32; i++) {
            expected |= bytes32(uint256(uint8(bytes1(bytes(exactly32)[i]))) << (i * 8));
        }
        assertEq(result[0], expected, "Packed bytes32 should match expected value");
    }

    function test_toBytes32_33Characters() public {
        string memory thirtyThree = "abcdefghijklmnopqrstuvwxyz1234567";
        bytes32[] memory result = StringConverter.toBytes32(thirtyThree);

        assertEq(result.length, 2, "33 characters should return array of length 2");

        // Verify first bytes32 contains first 32 characters
        bytes32 expectedFirst = 0;
        for (uint256 i = 0; i < 32; i++) {
            expectedFirst |= bytes32(uint256(uint8(bytes(thirtyThree)[i])) << (i * 8));
        }
        assertEq(result[0], expectedFirst, "First bytes32 should contain first 32 characters");

        // Verify second bytes32 contains the last character
        assertEq(result[1], bytes32(uint256(uint8(bytes1("7")))), "Second bytes32 should contain '7'");
    }

    function test_toBytes32_64Characters() public {
        string memory sixtyFour = "abcdefghijklmnopqrstuvwxyz1234567890123456789012345678901234";
        bytes32[] memory result = StringConverter.toBytes32(sixtyFour);

        // Calculate expected array length using ceiling division
        uint256 expectedLength = (bytes(sixtyFour).length + 32 - 1) / 32;
        assertEq(result.length, expectedLength, "64 characters should return correct array length");

        // Verify round-trip conversion works
        string memory roundTrip = StringConverter.fromBytes32(result);
        assertEq(roundTrip, sixtyFour, "Round-trip conversion should preserve string");
    }

    function test_toBytes32_65Characters() public {
        string memory sixtyFive = "abcdefghijklmnopqrstuvwxyz12345678901234567890123456789012345";
        bytes32[] memory result = StringConverter.toBytes32(sixtyFive);

        // Calculate expected array length using ceiling division
        uint256 expectedLength = (bytes(sixtyFive).length + 32 - 1) / 32;
        assertEq(result.length, expectedLength, "65 characters should return correct array length");

        // Verify round-trip conversion works
        string memory roundTrip = StringConverter.fromBytes32(result);
        assertEq(roundTrip, sixtyFive, "Round-trip conversion should preserve string");
    }

    function test_toBytes32_specialCharacters() public {
        string memory special = "!@#$%^&*()_+-=[]{}|;':\",./<>?";
        bytes32[] memory result = StringConverter.toBytes32(special);

        assertEq(result.length, 1, "Special characters should fit in one bytes32");

        // Verify the packed bytes32 contains all special characters
        bytes32 expected = 0;
        for (uint256 i = 0; i < bytes(special).length; i++) {
            expected |= bytes32(uint256(uint8(bytes(special)[i])) << (i * 8));
        }
        assertEq(result[0], expected, "Packed bytes32 should match expected value");
    }

    function test_fromBytes32_emptyArray() public {
        bytes32[] memory empty = new bytes32[](0);
        string memory result = StringConverter.fromBytes32(empty);

        assertEq(result, "", "Empty array should return empty string");
    }

    function test_fromBytes32_singleCharacter() public {
        bytes32[] memory single = new bytes32[](1);
        single[0] = bytes32(uint256(uint8(bytes1("a"))));

        string memory result = StringConverter.fromBytes32(single);

        assertEq(result, "a", "Single character should be correctly extracted");
    }

    function test_fromBytes32_exactly32Characters() public {
        string memory original = "abcdefghijklmnopqrstuvwxyz123456";
        bytes32[] memory packed = StringConverter.toBytes32(original);
        string memory result = StringConverter.fromBytes32(packed);

        assertEq(result, original, "Round-trip conversion should preserve string");
    }

    function test_fromBytes32_33Characters() public {
        string memory original = "abcdefghijklmnopqrstuvwxyz1234567";
        bytes32[] memory packed = StringConverter.toBytes32(original);
        string memory result = StringConverter.fromBytes32(packed);

        assertEq(result, original, "Round-trip conversion should preserve string");
    }

    function test_fromBytes32_64Characters() public {
        string memory original = "abcdefghijklmnopqrstuvwxyz1234567890123456789012345678901234";
        bytes32[] memory packed = StringConverter.toBytes32(original);
        string memory result = StringConverter.fromBytes32(packed);

        assertEq(result, original, "Round-trip conversion should preserve string");
    }

    function test_fromBytes32_65Characters() public {
        string memory original = "abcdefghijklmnopqrstuvwxyz12345678901234567890123456789012345";
        bytes32[] memory packed = StringConverter.toBytes32(original);
        string memory result = StringConverter.fromBytes32(packed);

        assertEq(result, original, "Round-trip conversion should preserve string");
    }

    function test_fromBytes32_specialCharacters() public {
        string memory original = "!@#$%^&*()_+-=[]{}|;':\",./<>?";
        bytes32[] memory packed = StringConverter.toBytes32(original);
        string memory result = StringConverter.fromBytes32(packed);

        assertEq(result, original, "Round-trip conversion should preserve special characters");
    }

    function test_fromBytes32_withNullBytes() public {
        bytes32[] memory withNulls = new bytes32[](1);
        // Set first 3 bytes to 'abc', rest to null
        withNulls[0] = bytes32(
            uint256(uint8(bytes1("a"))) | (uint256(uint8(bytes1("b"))) << 8) | (uint256(uint8(bytes1("c"))) << 16)
        );

        string memory result = StringConverter.fromBytes32(withNulls);

        assertEq(result, "abc", "Should stop at first null byte");
    }

    function test_fromBytes32_partialLastBytes32() public {
        bytes32[] memory partialArray = new bytes32[](2);
        // First bytes32: full 32 characters
        partialArray[0] = bytes32(
            uint256(uint8(bytes1("a"))) |
                (uint256(uint8(bytes1("b"))) << 8) |
                (uint256(uint8(bytes1("c"))) << 16) |
                // ... fill with more characters
                (uint256(uint8(bytes1("z"))) << 248)
        );
        // Second bytes32: only 3 characters
        partialArray[1] = bytes32(
            uint256(uint8(bytes1("x"))) | (uint256(uint8(bytes1("y"))) << 8) | (uint256(uint8(bytes1("z"))) << 16)
        );

        string memory result = StringConverter.fromBytes32(partialArray);

        // Should extract all characters up to the null byte in the second bytes32
        assertEq(bytes(result).length, 35, "Should extract 32 + 3 = 35 characters");
    }

    function test_roundTrip_variousLengths() public {
        string[] memory testStrings = new string[](5);
        testStrings[0] = "";
        testStrings[1] = "a";
        testStrings[2] = "hello world";
        testStrings[3] = "abcdefghijklmnopqrstuvwxyz123456";
        testStrings[
            4
        ] = "This is a very long string that should be split across multiple bytes32 arrays to test the conversion logic thoroughly";

        for (uint256 i = 0; i < testStrings.length; i++) {
            bytes32[] memory packed = StringConverter.toBytes32(testStrings[i]);
            string memory result = StringConverter.fromBytes32(packed);

            assertEq(result, testStrings[i], string.concat("Round-trip failed for test string ", vm.toString(i)));
        }
    }
}
