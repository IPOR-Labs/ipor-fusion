// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TypeConversionLib} from "../../contracts/libraries/TypeConversionLib.sol";

contract TypeConversionLibTest is Test {
    function test_addressToBytes32AndBack(address value) public pure {
        bytes32 bytesValue = TypeConversionLib.toBytes32(value);
        address result = TypeConversionLib.toAddress(bytesValue);
        assertEq(result, value);
    }

    function test_uint256ToBytes32AndBack(uint256 value) public pure {
        bytes32 bytesValue = TypeConversionLib.toBytes32(value);
        uint256 result = TypeConversionLib.toUint256(bytesValue);
        assertEq(result, value);
    }

    function test_int256ToBytes32AndBack(int256 value) public pure {
        bytes32 bytesValue = TypeConversionLib.toBytes32(value);
        int256 result = TypeConversionLib.toInt256(bytesValue);
        assertEq(result, value);
    }

    function test_boolToBytes32AndBack(bool value) public pure {
        bytes32 bytesValue = TypeConversionLib.toBytes32(value);
        bool result = TypeConversionLib.toBool(bytesValue);
        assertEq(result, value);
    }

    function test_bytesToBytes32AndBack(bytes memory value) public pure {
        // We can only convert bytes to bytes32 if length is <= 32,
        // but the current implementation of toBytes32(bytes) just loads the first 32 bytes.
        // If the input is shorter than 32 bytes, it might read garbage or revert depending on memory layout if not careful,
        // but let's check the implementation again.
        // The implementation:
        // if (value.length == 0) return 0x0;
        // assembly { result := mload(add(value, 32)) }
        // This reads the first 32 bytes of the data. If data is shorter, it reads out of bounds of the array data, potentially reading next memory slots.
        // However, for the purpose of this test, let's assume we want to test roundtrip for 32-byte arrays or handle the behavior for shorter ones if defined.
        // The library doesn't have a toBytes(bytes32) that returns the original dynamic bytes array exactly (it returns a 32-byte array).
        // Let's test that toBytes(bytes32) returns a 32-byte array with the correct content.

        bytes32 bytes32Value = keccak256(value);
        bytes memory result = TypeConversionLib.toBytes(bytes32Value);
        assertEq(result.length, 32);
        assertEq(bytes32(result), bytes32Value);
    }

    function test_bytesToBytes32_ZeroLength() public pure {
        bytes memory value = new bytes(0);
        bytes32 result = TypeConversionLib.toBytes32(value);
        assertEq(result, bytes32(0));
    }

    function test_bytesToBytes32_SpecificValue() public pure {
        bytes memory value = hex"1122334455667788990011223344556677889900112233445566778899001122";
        bytes32 result = TypeConversionLib.toBytes32(value);
        assertEq(result, 0x1122334455667788990011223344556677889900112233445566778899001122);
    }

    function test_bytesToBytes32_ShortInput_1Byte() public pure {
        bytes memory value = hex"aa";
        bytes32 result = TypeConversionLib.toBytes32(value);
        // Should be left-aligned with zeros on the right
        assertEq(result, 0xaa00000000000000000000000000000000000000000000000000000000000000);
    }

    function test_bytesToBytes32_ShortInput_3Bytes() public pure {
        bytes memory value = hex"112233";
        bytes32 result = TypeConversionLib.toBytes32(value);
        // Should be left-aligned with zeros on the right
        assertEq(result, 0x1122330000000000000000000000000000000000000000000000000000000000);
    }

    function test_bytesToBytes32_ShortInput_15Bytes() public pure {
        bytes memory value = hex"112233445566778899aabbccddeeff";
        bytes32 result = TypeConversionLib.toBytes32(value);
        // Should be left-aligned with zeros on the right (17 zero bytes)
        assertEq(result, 0x112233445566778899aabbccddeeff0000000000000000000000000000000000);
    }

    function test_bytesToBytes32_ShortInput_31Bytes() public pure {
        bytes memory value = hex"112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
        bytes32 result = TypeConversionLib.toBytes32(value);
        // Should be left-aligned with 1 zero byte on the right
        assertEq(result, 0x112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00);
    }

    function test_bytesToBytes32_ShortInput_NoDirtyMemoryLeak() public pure {
        // Allocate some memory with known values to potentially pollute memory
        bytes memory polluter = hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
        // Use polluter to prevent optimizer from removing it
        require(polluter.length == 32, "polluter check");

        // Now create a short input - should NOT contain any 0xff from previous allocation
        bytes memory shortValue = hex"aabb";
        bytes32 result = TypeConversionLib.toBytes32(shortValue);

        // Result must have zeros in trailing bytes, not 0xff from polluter
        assertEq(result, 0xaabb000000000000000000000000000000000000000000000000000000000000);
    }

    function test_bytesToBytes32_ShortInput_ConsistentAcrossCalls() public pure {
        bytes memory value = hex"deadbeef";

        // Call multiple times - should always return the same canonical value
        bytes32 result1 = TypeConversionLib.toBytes32(value);
        bytes32 result2 = TypeConversionLib.toBytes32(value);
        bytes32 result3 = TypeConversionLib.toBytes32(value);

        assertEq(result1, result2);
        assertEq(result2, result3);
        assertEq(result1, 0xdeadbeef00000000000000000000000000000000000000000000000000000000);
    }

    function test_bytesToBytes32_FuzzShortInput(bytes memory value) public pure {
        vm.assume(value.length > 0 && value.length < 32);

        bytes32 result = TypeConversionLib.toBytes32(value);

        // Verify that trailing bytes are zero - mask covers the last (32 - length) bytes
        bytes32 mask = bytes32(type(uint256).max >> (value.length * 8));

        // (result & mask) should be 0 - meaning all trailing bytes are zero
        assertEq(result & mask, bytes32(0), "Trailing bytes should be zero");

        // Verify that the first `length` bytes match the input
        for (uint256 i = 0; i < value.length; i++) {
            assertEq(uint8(result[i]), uint8(value[i]), "Leading bytes should match input");
        }
    }

    function test_bytesToBytes32_ExactlyThirtyTwoBytes_NoMasking() public pure {
        bytes memory value = hex"0102030405060708091011121314151617181920212223242526272829303132";
        bytes32 result = TypeConversionLib.toBytes32(value);
        assertEq(result, 0x0102030405060708091011121314151617181920212223242526272829303132);
    }

    function test_bytesToBytes32_LongerThanThirtyTwoBytes_TruncatesToFirst32() public pure {
        // Input is 40 bytes - should only read first 32
        bytes memory value = hex"01020304050607080910111213141516171819202122232425262728293031320000000000000000";
        bytes32 result = TypeConversionLib.toBytes32(value);
        assertEq(result, 0x0102030405060708091011121314151617181920212223242526272829303132);
    }
}
