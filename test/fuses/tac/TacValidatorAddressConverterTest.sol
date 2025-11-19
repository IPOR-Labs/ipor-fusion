// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {TacValidatorAddressConverter} from "../../../contracts/fuses/tac/lib/TacValidatorAddressConverter.sol";

contract TacValidatorAddressConverterTest is Test {
    function stestSimpleCase() public {
        string memory input = "tac1pdu86gjvnnr2786xtkw2eggxkmrsur0zjm6vxn";
        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);
        assertEq(input, output, "Simple string failed");
    }

    function stestRoundTripShortString() public {
        string memory input = "tac1short";
        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);
        assertEq(input, output, "Short string round-trip failed");
    }

    function stestRoundTrip32Bytes() public {
        string memory input = string(abi.encodePacked(new bytes(32)));
        for (uint i = 0; i < 32; i++) {
            bytes(input)[i] = bytes1(uint8(65 + i)); // A, B, C, ...
        }
        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);
        assertEq(input, output, "32-byte string round-trip failed");
    }

    function stestRoundTrip33Bytes() public {
        string memory input = string(abi.encodePacked(new bytes(33)));
        for (uint i = 0; i < 33; i++) {
            bytes(input)[i] = bytes1(uint8(97 + i)); // a, b, c, ...
        }
        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);
        assertEq(input, output, "33-byte string round-trip failed");
    }

    function stestRoundTrip63Bytes() public {
        string memory input = string(abi.encodePacked(new bytes(63)));
        for (uint i = 0; i < 63; i++) {
            bytes(input)[i] = bytes1(uint8(33 + i));
        }
        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);
        assertEq(input, output, "63-byte string round-trip failed");
    }

    function stestRoundTrip64Bytes() public {
        string memory input = string(abi.encodePacked(new bytes(63)));
        for (uint i = 0; i < 63; i++) {
            bytes(input)[i] = bytes1(uint8(128 + i));
        }
        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);
        assertEq(input, output, "63-byte string round-trip failed");
    }

    function stestEmptyString() public {
        string memory input = "";
        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);
        assertEq(input, output, "Empty string round-trip failed");
    }

    function stestOneCharString() public {
        string memory input = "x";
        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);
        assertEq(input, output, "One char string round-trip failed");
    }

    function stestStringWithNullByteInMiddle() public {
        // Create a string with a null byte in the middle
        bytes memory strBytes = new bytes(10);
        strBytes[0] = "a";
        strBytes[1] = "b";
        strBytes[2] = "c";
        strBytes[3] = 0; // null byte in the middle
        strBytes[4] = "d";
        strBytes[5] = "e";
        strBytes[6] = "f";
        strBytes[7] = "g";
        strBytes[8] = "h";
        strBytes[9] = "i";

        string memory input = string(strBytes);

        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);

        assertEq(input, output, "String with null byte in middle should be preserved");
    }

    function stestStringWithMultipleNullBytes() public {
        // Create a string with multiple null bytes
        bytes memory strBytes = new bytes(15);
        strBytes[0] = "x";
        strBytes[1] = "y";
        strBytes[2] = 0; // first null byte
        strBytes[3] = "z";
        strBytes[4] = "w";
        strBytes[5] = 0; // second null byte
        strBytes[6] = "v";
        strBytes[7] = "u";
        strBytes[8] = "t";
        strBytes[9] = "s";
        strBytes[10] = "r";
        strBytes[11] = "q";
        strBytes[12] = "p";
        strBytes[13] = "o";
        strBytes[14] = "n";

        string memory input = string(strBytes);

        // Convert to bytes32 and back
        (bytes32 a, bytes32 b) = TacValidatorAddressConverter.validatorAddressToBytes32(input);
        string memory output = TacValidatorAddressConverter.bytes32ToValidatorAddress(a, b);

        assertEq(input, output, "String with multiple null bytes should be preserved");
    }
}
