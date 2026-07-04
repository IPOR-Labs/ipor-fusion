// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {ExchangeRateValidatorConfigLibCaller} from "test/test_helpers/lib_callers/ExchangeRateValidatorConfigLibCaller.sol";

/// @dev Target: ExchangeRateValidatorConfigLibCaller (library ExchangeRateValidatorConfigLib wrapped for Olympix targeting).

import {Hook} from "contracts/handlers/pre_hooks/pre_hooks/ExchangeRateValidatorConfigLib.sol";
import {ValidatorData} from "contracts/handlers/pre_hooks/pre_hooks/ExchangeRateValidatorConfigLib.sol";
import {ExchangeRateValidatorConfig, Hook, ValidatorData} from "contracts/handlers/pre_hooks/pre_hooks/ExchangeRateValidatorConfigLib.sol";
contract ExchangeRateValidatorConfigLibTest is OlympixUnitTest("ExchangeRateValidatorConfigLibCaller") {
    ExchangeRateValidatorConfigLibCaller internal caller;

    function setUp() public override {
        caller = new ExchangeRateValidatorConfigLibCaller();
    }

    function test_example_deploys() public view {
        assertTrue(address(caller) != address(0));
    }

    function test_bytes31ToHook_decodesAddressAndIndex() public view {
            Hook memory original;
            original.hookAddress = address(0x1234567890123456789012345678901234567890);
            original.index = 7;
    
            // encode using the library via caller
            bytes31 encoded = caller.hookToBytes31(original);
    
            // when: decode back via bytes31ToHook (targets opix-target-branch-32-True)
            Hook memory decoded = caller.bytes31ToHook(encoded);
    
            // then: fields round‑trip correctly
            assertEq(decoded.hookAddress, original.hookAddress, "hookAddress mismatch");
            assertEq(decoded.index, original.index, "index mismatch");
        }

    function test_validatorDataToBytes31_roundtrip() public view {
            // given: construct ValidatorData with non-zero fields to exercise packing logic
            ValidatorData memory original = ValidatorData({
                exchangeRate: uint128(1e18),
                threshold: uint120(5e17)
            });
    
            // when: encode then decode using the wrapped library functions
            bytes31 packed = caller.validatorDataToBytes31(original);
            ValidatorData memory decoded = caller.bytes31ToValidatorData(packed);
    
            // then: all fields should match
            assertEq(decoded.exchangeRate, original.exchangeRate, "exchangeRate mismatch");
            assertEq(decoded.threshold, original.threshold, "threshold mismatch");
        }

    function test_bytes31ToValidatorData_roundtrip() public view {
            // given: construct ValidatorData with specific fields
            ValidatorData memory original;
            original.exchangeRate = uint128(1e18);
            original.threshold = uint120(1234567890123456789);
    
            // when: pack then unpack using the caller wrapper
            bytes31 packed = caller.validatorDataToBytes31(original);
            ValidatorData memory decoded = caller.bytes31ToValidatorData(packed);
    
            // then: values should round-trip correctly
            assertEq(decoded.exchangeRate, original.exchangeRate, "exchangeRate should roundtrip correctly");
            assertEq(decoded.threshold, original.threshold, "threshold should roundtrip correctly");
        }
}