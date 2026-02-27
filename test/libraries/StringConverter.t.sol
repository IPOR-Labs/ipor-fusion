// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StringConverter} from "../../contracts/libraries/StringConverter.sol";

/// @title StringConverter Tests
/// @notice Tests for length-prefixed string encoding (IL-6957/IL-6960 fix)
/// @dev New encoding format: first 2 bytes = length (uint16), followed by string data
contract StringConverterTest is Test {
    using StringConverter for string;

    // ============ toBytes32 Tests ============

    function test_toBytes32_emptyString() public pure {
        string memory empty = "";
        bytes32[] memory result = StringConverter.toBytes32(empty);

        // Empty string now returns array of length 1 containing length=0
        assertEq(result.length, 1, "Empty string should return array of length 1");
        assertEq(result[0], bytes32(0), "First bytes32 should be zero (length=0)");
    }

    function test_toBytes32_singleCharacter() public pure {
        string memory single = "a";
        bytes32[] memory result = StringConverter.toBytes32(single);

        assertEq(result.length, 1, "Single character should return array of length 1");
        // Length (1) in first 2 bytes, 'a' (0x61) starting at byte 2
        bytes32 expected = bytes32(uint256(1)) | bytes32(uint256(uint8(bytes1("a"))) << 16);
        assertEq(result[0], expected, "Should contain length=1 and character 'a'");
    }

    function test_toBytes32_30Characters() public pure {
        // 30 chars = 2 bytes length + 30 bytes data = 32 bytes total (fits in 1 bytes32)
        string memory thirty = "abcdefghijklmnopqrstuvwxyz1234";
        bytes32[] memory result = StringConverter.toBytes32(thirty);

        assertEq(result.length, 1, "30 characters should fit in 1 bytes32");

        // Verify round-trip
        string memory roundTrip = StringConverter.fromBytes32(result);
        assertEq(roundTrip, thirty, "Round-trip should preserve string");
    }

    function test_toBytes32_31Characters() public pure {
        // 31 chars = 2 bytes length + 31 bytes data = 33 bytes total (needs 2 bytes32)
        string memory thirtyOne = "abcdefghijklmnopqrstuvwxyz12345";
        bytes32[] memory result = StringConverter.toBytes32(thirtyOne);

        assertEq(result.length, 2, "31 characters should return array of length 2");

        // Verify round-trip
        string memory roundTrip = StringConverter.fromBytes32(result);
        assertEq(roundTrip, thirtyOne, "Round-trip should preserve string");
    }

    function test_toBytes32_exactly32Characters() public pure {
        // 32 chars = 2 bytes length + 32 bytes data = 34 bytes total (needs 2 bytes32)
        string memory exactly32 = "abcdefghijklmnopqrstuvwxyz123456";
        bytes32[] memory result = StringConverter.toBytes32(exactly32);

        assertEq(result.length, 2, "32 characters should return array of length 2");

        // Verify round-trip
        string memory roundTrip = StringConverter.fromBytes32(result);
        assertEq(roundTrip, exactly32, "Round-trip should preserve string");
    }

    function test_toBytes32_33Characters() public pure {
        string memory thirtyThree = "abcdefghijklmnopqrstuvwxyz1234567";
        bytes32[] memory result = StringConverter.toBytes32(thirtyThree);

        assertEq(result.length, 2, "33 characters should return array of length 2");

        // Verify round-trip
        string memory roundTrip = StringConverter.fromBytes32(result);
        assertEq(roundTrip, thirtyThree, "Round-trip should preserve string");
    }

    function test_toBytes32_64Characters() public pure {
        // 64 character string
        string memory sixtyFour = "abcdefghijklmnopqrstuvwxyz12345678901234567890abcdefghijklmnopqr";
        assertEq(bytes(sixtyFour).length, 64, "Should be 64 chars");
        bytes32[] memory result = StringConverter.toBytes32(sixtyFour);

        // Verify round-trip works correctly
        string memory roundTrip = StringConverter.fromBytes32(result);
        assertEq(roundTrip, sixtyFour, "Round-trip should preserve string");
    }

    function test_toBytes32_65Characters() public pure {
        string memory sixtyFive = "abcdefghijklmnopqrstuvwxyz12345678901234567890123456789012345";
        bytes32[] memory result = StringConverter.toBytes32(sixtyFive);

        // Verify round-trip
        string memory roundTrip = StringConverter.fromBytes32(result);
        assertEq(roundTrip, sixtyFive, "Round-trip should preserve string");
    }

    function test_toBytes32_specialCharacters() public pure {
        string memory special = "!@#$%^&*()_+-=[]{}|;':\",./<>?";
        bytes32[] memory result = StringConverter.toBytes32(special);

        // Verify round-trip preserves special chars
        string memory roundTrip = StringConverter.fromBytes32(result);
        assertEq(roundTrip, special, "Round-trip should preserve special characters");
    }

    // ============ fromBytes32 Tests ============

    function test_fromBytes32_emptyArray() public pure {
        bytes32[] memory empty = new bytes32[](0);
        string memory result = StringConverter.fromBytes32(empty);

        assertEq(result, "", "Empty array should return empty string");
    }

    function test_fromBytes32_zeroLength() public pure {
        bytes32[] memory zeroLen = new bytes32[](1);
        zeroLen[0] = bytes32(0); // Length = 0

        string memory result = StringConverter.fromBytes32(zeroLen);
        assertEq(result, "", "Zero length should return empty string");
    }

    function test_fromBytes32_singleCharacter() public pure {
        bytes32[] memory single = new bytes32[](1);
        // Length = 1 in first 2 bytes, 'a' (0x61) at byte index 2
        single[0] = bytes32(uint256(1)) | bytes32(uint256(0x61) << 16);

        string memory result = StringConverter.fromBytes32(single);
        assertEq(result, "a", "Single character should be correctly extracted");
    }

    function test_fromBytes32_exactly30Characters() public pure {
        string memory original = "abcdefghijklmnopqrstuvwxyz1234";
        bytes32[] memory packed = StringConverter.toBytes32(original);
        string memory result = StringConverter.fromBytes32(packed);

        assertEq(result, original, "Round-trip conversion should preserve string");
    }

    function test_fromBytes32_exactly32Characters() public pure {
        string memory original = "abcdefghijklmnopqrstuvwxyz123456";
        bytes32[] memory packed = StringConverter.toBytes32(original);
        string memory result = StringConverter.fromBytes32(packed);

        assertEq(result, original, "Round-trip conversion should preserve string");
    }

    function test_fromBytes32_33Characters() public pure {
        string memory original = "abcdefghijklmnopqrstuvwxyz1234567";
        bytes32[] memory packed = StringConverter.toBytes32(original);
        string memory result = StringConverter.fromBytes32(packed);

        assertEq(result, original, "Round-trip conversion should preserve string");
    }

    function test_fromBytes32_64Characters() public pure {
        string memory original = "abcdefghijklmnopqrstuvwxyz1234567890123456789012345678901234";
        bytes32[] memory packed = StringConverter.toBytes32(original);
        string memory result = StringConverter.fromBytes32(packed);

        assertEq(result, original, "Round-trip conversion should preserve string");
    }

    function test_fromBytes32_65Characters() public pure {
        string memory original = "abcdefghijklmnopqrstuvwxyz12345678901234567890123456789012345";
        bytes32[] memory packed = StringConverter.toBytes32(original);
        string memory result = StringConverter.fromBytes32(packed);

        assertEq(result, original, "Round-trip conversion should preserve string");
    }

    function test_fromBytes32_specialCharacters() public pure {
        string memory original = "!@#$%^&*()_+-=[]{}|;':\",./<>?";
        bytes32[] memory packed = StringConverter.toBytes32(original);
        string memory result = StringConverter.fromBytes32(packed);

        assertEq(result, original, "Round-trip conversion should preserve special characters");
    }

    // ============ IL-6957/IL-6960 Specific Tests - Null Byte Preservation ============

    function test_roundTrip_withTrailingNullBytes() public pure {
        // String with trailing null bytes - MUST be preserved
        bytes memory withTrailingNulls = new bytes(5);
        withTrailingNulls[0] = "a";
        withTrailingNulls[1] = "b";
        withTrailingNulls[2] = "c";
        withTrailingNulls[3] = 0x00; // trailing null
        withTrailingNulls[4] = 0x00; // trailing null

        string memory original = string(withTrailingNulls);
        bytes32[] memory packed = StringConverter.toBytes32(original);
        string memory result = StringConverter.fromBytes32(packed);

        assertEq(bytes(result).length, 5, "Should preserve all 5 bytes including trailing nulls");
        assertEq(keccak256(bytes(result)), keccak256(withTrailingNulls), "Content should match exactly");
    }

    function test_roundTrip_withEmbeddedNullBytes() public pure {
        // String with embedded null bytes - MUST be preserved
        bytes memory withEmbeddedNulls = new bytes(5);
        withEmbeddedNulls[0] = "a";
        withEmbeddedNulls[1] = 0x00; // embedded null
        withEmbeddedNulls[2] = "b";
        withEmbeddedNulls[3] = 0x00; // embedded null
        withEmbeddedNulls[4] = "c";

        string memory original = string(withEmbeddedNulls);
        bytes32[] memory packed = StringConverter.toBytes32(original);
        string memory result = StringConverter.fromBytes32(packed);

        assertEq(bytes(result).length, 5, "Should preserve all 5 bytes including embedded nulls");
        assertEq(keccak256(bytes(result)), keccak256(withEmbeddedNulls), "Content should match exactly");
    }

    function test_noCollision_abcAndAbcWithNull() public pure {
        // IL-6957 fix: "abc" and "abc\x00" should produce DIFFERENT encodings
        string memory abc = "abc";
        bytes memory abcWithNull = new bytes(4);
        abcWithNull[0] = "a";
        abcWithNull[1] = "b";
        abcWithNull[2] = "c";
        abcWithNull[3] = 0x00;
        string memory abcNull = string(abcWithNull);

        bytes32[] memory encodedAbc = StringConverter.toBytes32(abc);
        bytes32[] memory encodedAbcNull = StringConverter.toBytes32(abcNull);

        // They should produce different encodings (different lengths)
        assertTrue(
            keccak256(abi.encode(encodedAbc)) != keccak256(abi.encode(encodedAbcNull)),
            "abc and abc+null should have different encodings"
        );

        // Round-trip should preserve the difference
        string memory decodedAbc = StringConverter.fromBytes32(encodedAbc);
        string memory decodedAbcNull = StringConverter.fromBytes32(encodedAbcNull);

        assertEq(bytes(decodedAbc).length, 3, "abc should decode to 3 bytes");
        assertEq(bytes(decodedAbcNull).length, 4, "abc+null should decode to 4 bytes");
    }

    function test_noCollision_emptyAndSingleNull() public pure {
        // IL-6957 fix: "" and "\x00" should produce DIFFERENT encodings
        string memory empty = "";
        bytes memory singleNull = new bytes(1);
        singleNull[0] = 0x00;
        string memory nullStr = string(singleNull);

        bytes32[] memory encodedEmpty = StringConverter.toBytes32(empty);
        bytes32[] memory encodedNull = StringConverter.toBytes32(nullStr);

        // They should produce different encodings
        assertTrue(
            keccak256(abi.encode(encodedEmpty)) != keccak256(abi.encode(encodedNull)),
            "Empty and single-null should have different encodings"
        );

        // Round-trip should preserve the difference
        string memory decodedEmpty = StringConverter.fromBytes32(encodedEmpty);
        string memory decodedNull = StringConverter.fromBytes32(encodedNull);

        assertEq(bytes(decodedEmpty).length, 0, "Empty should decode to 0 bytes");
        assertEq(bytes(decodedNull).length, 1, "Single-null should decode to 1 byte");
    }

    function test_roundTrip_allNullString() public pure {
        // String of all nulls - edge case
        bytes memory allNulls = new bytes(5);
        // All bytes are already 0x00

        string memory original = string(allNulls);
        bytes32[] memory packed = StringConverter.toBytes32(original);
        string memory result = StringConverter.fromBytes32(packed);

        assertEq(bytes(result).length, 5, "Should preserve all 5 null bytes");
    }

    function test_noCollision_singleNullAndDoubleNull() public pure {
        // "\x00" and "\x00\x00" should produce DIFFERENT encodings
        bytes memory oneNull = new bytes(1);
        oneNull[0] = 0x00;
        string memory oneNullStr = string(oneNull);

        bytes memory twoNulls = new bytes(2);
        twoNulls[0] = 0x00;
        twoNulls[1] = 0x00;
        string memory twoNullsStr = string(twoNulls);

        bytes32[] memory encodedOne = StringConverter.toBytes32(oneNullStr);
        bytes32[] memory encodedTwo = StringConverter.toBytes32(twoNullsStr);

        assertTrue(
            keccak256(abi.encode(encodedOne)) != keccak256(abi.encode(encodedTwo)),
            "Single-null and double-null should have different encodings"
        );

        string memory decodedOne = StringConverter.fromBytes32(encodedOne);
        string memory decodedTwo = StringConverter.fromBytes32(encodedTwo);

        assertEq(bytes(decodedOne).length, 1, "Single-null should decode to 1 byte");
        assertEq(bytes(decodedTwo).length, 2, "Double-null should decode to 2 bytes");
    }

    function test_toBytes32_exactly62Characters() public pure {
        // 62 chars = 2 bytes length + 62 bytes data = 64 bytes = exactly 2 bytes32
        bytes memory raw = new bytes(62);
        for (uint256 i = 0; i < 62; i++) {
            raw[i] = bytes1(uint8(0x41 + (i % 26))); // A-Z repeating
        }
        string memory sixtyTwo = string(raw);
        assertEq(bytes(sixtyTwo).length, 62, "Should be 62 chars");

        bytes32[] memory result = StringConverter.toBytes32(sixtyTwo);
        assertEq(result.length, 2, "62 chars should exactly fill 2 bytes32");

        string memory roundTrip = StringConverter.fromBytes32(result);
        assertEq(bytes(roundTrip).length, 62, "Round-trip should preserve length");
        assertEq(keccak256(bytes(roundTrip)), keccak256(raw), "Round-trip should preserve content");
    }

    // ============ Error Cases ============

    function test_fromBytes32_invalidLength_reverts() public {
        bytes32[] memory invalid = new bytes32[](1);
        // Set length to 100, but only have 30 bytes of data available
        invalid[0] = bytes32(uint256(100));

        // Use try/catch since vm.expectRevert doesn't work with internal library calls
        bool reverted = false;
        try this.callFromBytes32(invalid) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "Should revert with InvalidEncodedData");
    }

    function callFromBytes32(bytes32[] memory data) external pure returns (string memory) {
        return StringConverter.fromBytes32(data);
    }

    function test_toBytes32_stringTooLong_reverts() public {
        // Create a string longer than uint16 max (65535)
        bytes memory tooLong = new bytes(65536);
        for (uint256 i = 0; i < 65536; i++) {
            tooLong[i] = "a";
        }

        // Use try/catch since vm.expectRevert doesn't work with internal library calls
        bool reverted = false;
        try this.callToBytes32(string(tooLong)) {
            // Should not reach here
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "Should revert with StringTooLong");
    }

    function callToBytes32(string memory s) external pure returns (bytes32[] memory) {
        return StringConverter.toBytes32(s);
    }

    // ============ Round-trip Tests ============

    function test_roundTrip_variousLengths() public pure {
        string[] memory testStrings = new string[](6);
        testStrings[0] = "";
        testStrings[1] = "a";
        testStrings[2] = "hello world";
        testStrings[3] = "abcdefghijklmnopqrstuvwxyz1234"; // 30 chars (fits in 1 bytes32)
        testStrings[4] = "abcdefghijklmnopqrstuvwxyz123456"; // 32 chars
        testStrings[5] = "This is a very long string that should be split across multiple bytes32 arrays to test the conversion logic thoroughly";

        for (uint256 i = 0; i < testStrings.length; i++) {
            bytes32[] memory packed = StringConverter.toBytes32(testStrings[i]);
            string memory result = StringConverter.fromBytes32(packed);

            assertEq(result, testStrings[i], "Round-trip failed");
        }
    }

    function test_roundTrip_maxLengthBoundary() public pure {
        // Test at boundary: 30 chars (fits in 1 bytes32 with length prefix)
        string memory boundary30 = "123456789012345678901234567890";
        assertEq(bytes(boundary30).length, 30, "Should be 30 chars");

        bytes32[] memory packed30 = StringConverter.toBytes32(boundary30);
        assertEq(packed30.length, 1, "30 chars should fit in 1 bytes32");

        string memory result30 = StringConverter.fromBytes32(packed30);
        assertEq(result30, boundary30, "Round-trip should work for 30 chars");

        // Test at boundary: 31 chars (needs 2 bytes32)
        string memory boundary31 = "1234567890123456789012345678901";
        assertEq(bytes(boundary31).length, 31, "Should be 31 chars");

        bytes32[] memory packed31 = StringConverter.toBytes32(boundary31);
        assertEq(packed31.length, 2, "31 chars should need 2 bytes32");

        string memory result31 = StringConverter.fromBytes32(packed31);
        assertEq(result31, boundary31, "Round-trip should work for 31 chars");
    }

    // ============ Fuzz Tests ============

    function testFuzz_roundTrip(string memory input) public pure {
        // Skip strings that are too long
        if (bytes(input).length > 65535) {
            return;
        }

        bytes32[] memory packed = StringConverter.toBytes32(input);
        string memory result = StringConverter.fromBytes32(packed);

        assertEq(
            keccak256(bytes(result)),
            keccak256(bytes(input)),
            "Fuzz: Round-trip should preserve all bytes"
        );
    }
}
