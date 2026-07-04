// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {TacValidatorAddressConverterCaller} from "test/test_helpers/lib_callers/TacValidatorAddressConverterCaller.sol";

/// @dev Target: TacValidatorAddressConverterCaller (library TacValidatorAddressConverter wrapped for Olympix targeting).

contract TacValidatorAddressConverterTest is OlympixUnitTest("TacValidatorAddressConverterCaller") {
    TacValidatorAddressConverterCaller internal caller;

    function setUp() public override {
        caller = new TacValidatorAddressConverterCaller();
    }

    function test_example_deploys() public view {
        assertTrue(address(caller) != address(0));
    }

    function test_validatorAddressConversionRoundTrip() public view {
            string memory original = "cosmosvaloper1qyqszqgpqyqszqgpqyqszqgpqyqszqgpq0p7r";
    
            (bytes32 first, bytes32 second) = caller.validatorAddressToBytes32(original);
            string memory reconstructed = caller.bytes32ToValidatorAddress(first, second);
    
            assertEq(reconstructed, original);
        }

    function test_validatorAddressRoundTrip() public view {
            string memory original = "cosmosvaloper1qqp9q4h8dpc9x0q2t9q3v9tq9p0x9q9p0x9p0";
    
            (bytes32 first, bytes32 second) = caller.validatorAddressToBytes32(original);
            string memory reconstructed = caller.bytes32ToValidatorAddress(first, second);
    
            assertEq(reconstructed, original, "validator address should round-trip through bytes32 representation");
        }
}