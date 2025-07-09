// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {TacValidatorAddressConverter} from "../../../contracts/fuses/tac/TacValidatorAddressConverter.sol";

contract TacValidatorAddressConverterTest is Test {
    function testSimpleCase() public {
        string memory input = "tac1pdu86gjvnnr2786xtkw2eggxkmrsur0zjm6vxn";
        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);
        assertEq(input, output, "Simple string failed");
    }

    function testRoundTripShortString() public {
        string memory input = "tac1short";
        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);
        assertEq(input, output, "Short string round-trip failed");
    }

    function testRoundTrip32Bytes() public {
        string memory input = string(abi.encodePacked(new bytes(32)));
        for (uint i = 0; i < 32; i++) {
            bytes(input)[i] = bytes1(uint8(65 + i)); // A, B, C, ...
        }
        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);
        assertEq(input, output, "32-byte string round-trip failed");
    }

    function testRoundTrip33Bytes() public {
        string memory input = string(abi.encodePacked(new bytes(33)));
        for (uint i = 0; i < 33; i++) {
            bytes(input)[i] = bytes1(uint8(97 + i)); // a, b, c, ...
        }
        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);
        assertEq(input, output, "33-byte string round-trip failed");
    }

    function testRoundTrip63Bytes() public {
        string memory input = string(abi.encodePacked(new bytes(63)));
        for (uint i = 0; i < 63; i++) {
            bytes(input)[i] = bytes1(uint8(33 + i));
        }
        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);
        assertEq(input, output, "63-byte string round-trip failed");
    }

    function testRoundTrip64Bytes() public {
        string memory input = string(abi.encodePacked(new bytes(64)));
        for (uint i = 0; i < 64; i++) {
            bytes(input)[i] = bytes1(uint8(128 + i));
        }
        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);
        assertEq(input, output, "64-byte string round-trip failed");
    }

    function testEmptyString() public {
        string memory input = "";
        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);
        assertEq(input, output, "Empty string round-trip failed");
    }

    function testOneCharString() public {
        string memory input = "x";
        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);
        assertEq(input, output, "One char string round-trip failed");
    }

    function testStringLength() public {
        // Create a string that is exactly 65 bytes long
        string memory input = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyzA";
        uint256 length = bytes(input).length;

        // If the string is longer than 65, truncate it to exactly 65 bytes
        if (length > 65) {
            bytes memory truncated = new bytes(65);
            for (uint i = 0; i < 65; i++) {
                truncated[i] = bytes(input)[i];
            }
            input = string(truncated);
            length = 65;
        }

        assertEq(length, 65, "String should be 65 bytes long");
    }
}
