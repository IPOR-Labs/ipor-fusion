// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ExchangeRateValidatorConfigLib, ExchangeRateValidatorConfig, HookType, Hook, ValidatorData} from "../../contracts/handlers/pre_hooks/pre_hooks/ExchangeRateValidatorConfigLib.sol";

/// @title ExchangeRateValidatorConfigLibTest
/// @notice Comprehensive tests for ExchangeRateValidatorConfigLib encoding and decoding functions
contract ExchangeRateValidatorConfigLibTest is Test {
    using ExchangeRateValidatorConfigLib for ExchangeRateValidatorConfig;

    // ============ ExchangeRateValidatorConfig Tests ============

    /// @notice Test basic encoding and decoding of ExchangeRateValidatorConfig
    function testExchangeRateValidatorConfigEncodeDecode() public {
        // Use a value that fits in uint248 (248 bits = 31 bytes)
        bytes32 dataBytes32 = bytes32(uint256(0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef));
        ExchangeRateValidatorConfig memory config = ExchangeRateValidatorConfig({
            typ: HookType.PREHOOKS,
            data: bytes31(uint248(uint256(dataBytes32)))
        });

        bytes32 encoded = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(config);
        ExchangeRateValidatorConfig memory decoded = ExchangeRateValidatorConfigLib
            .bytes32ToExchangeRateValidatorConfig(encoded);

        assertEq(uint256(decoded.typ), uint256(config.typ), "Decoded type should match");
        assertEq(uint256(uint248(decoded.data)), uint256(uint248(config.data)), "Decoded data should match");
    }

    /// @notice Test all HookType enum values
    function testExchangeRateValidatorConfigAllTypes() public {
        HookType[] memory types = new HookType[](3);
        types[0] = HookType.PREHOOKS;
        types[1] = HookType.POSTHOOKS;
        types[2] = HookType.VALIDATOR;

        // Use a value that fits in bytes31 (use smaller hex value that fits in uint256)
        uint256 dataValue = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
        bytes31 data = bytes31(uint248(dataValue));

        for (uint256 i = 0; i < types.length; i++) {
            ExchangeRateValidatorConfig memory config = ExchangeRateValidatorConfig({typ: types[i], data: data});

            bytes32 encoded = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(config);
            ExchangeRateValidatorConfig memory decoded = ExchangeRateValidatorConfigLib
                .bytes32ToExchangeRateValidatorConfig(encoded);

            assertEq(uint256(decoded.typ), uint256(types[i]), "Type should match");
            assertEq(uint256(uint248(decoded.data)), uint256(uint248(data)), "Data should match");
        }
    }

    /// @notice Test encoding/decoding with zero data
    function testExchangeRateValidatorConfigZeroData() public {
        ExchangeRateValidatorConfig memory config = ExchangeRateValidatorConfig({
            typ: HookType.VALIDATOR,
            data: bytes31(0)
        });

        bytes32 encoded = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(config);
        ExchangeRateValidatorConfig memory decoded = ExchangeRateValidatorConfigLib
            .bytes32ToExchangeRateValidatorConfig(encoded);

        assertEq(uint256(decoded.typ), uint256(HookType.VALIDATOR), "Type should match");
        assertEq(uint256(uint248(decoded.data)), 0, "Data should be zero");
    }

    /// @notice Test encoding/decoding with maximum data value
    function testExchangeRateValidatorConfigMaxData() public {
        bytes31 maxData = bytes31(type(uint248).max);
        ExchangeRateValidatorConfig memory config = ExchangeRateValidatorConfig({
            typ: HookType.POSTHOOKS,
            data: maxData
        });

        bytes32 encoded = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(config);
        ExchangeRateValidatorConfig memory decoded = ExchangeRateValidatorConfigLib
            .bytes32ToExchangeRateValidatorConfig(encoded);

        assertEq(uint256(decoded.typ), uint256(HookType.POSTHOOKS), "Type should match");
        assertEq(uint256(uint248(decoded.data)), uint256(uint248(maxData)), "Data should match max value");
    }

    /// @notice Fuzz test for ExchangeRateValidatorConfig encoding/decoding
    function testFuzzExchangeRateValidatorConfig(uint8 typ_, uint248 data_) public {
        // Bound typ to valid enum values (0-2)
        typ_ = uint8(bound(typ_, 0, 2));
        HookType hookType = HookType(typ_);

        ExchangeRateValidatorConfig memory config = ExchangeRateValidatorConfig({typ: hookType, data: bytes31(data_)});

        bytes32 encoded = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(config);
        ExchangeRateValidatorConfig memory decoded = ExchangeRateValidatorConfigLib
            .bytes32ToExchangeRateValidatorConfig(encoded);

        assertEq(uint256(decoded.typ), uint256(hookType), "Fuzz: Type should match");
        assertEq(uint256(uint248(decoded.data)), data_, "Fuzz: Data should match");
    }

    // ============ Hook Tests ============

    /// @notice Test basic encoding and decoding of Hook
    function testHookEncodeDecode() public {
        address hookAddress = address(0x1234567890123456789012345678901234567890);
        uint8 index = 5;

        Hook memory hook = Hook({hookAddress: hookAddress, index: index});

        bytes31 encoded = ExchangeRateValidatorConfigLib.hookToBytes31(hook);
        Hook memory decoded = ExchangeRateValidatorConfigLib.bytes31ToHook(encoded);

        assertEq(decoded.hookAddress, hookAddress, "Decoded address should match");
        assertEq(decoded.index, index, "Decoded index should match");
    }

    /// @notice Test Hook with zero address
    function testHookZeroAddress() public {
        Hook memory hook = Hook({hookAddress: address(0), index: 0});

        bytes31 encoded = ExchangeRateValidatorConfigLib.hookToBytes31(hook);
        Hook memory decoded = ExchangeRateValidatorConfigLib.bytes31ToHook(encoded);

        assertEq(decoded.hookAddress, address(0), "Zero address should be preserved");
        assertEq(decoded.index, 0, "Index should be zero");
    }

    /// @notice Test Hook with maximum address
    function testHookMaxAddress() public {
        address maxAddress = address(type(uint160).max);
        uint8 index = 9;

        Hook memory hook = Hook({hookAddress: maxAddress, index: index});

        bytes31 encoded = ExchangeRateValidatorConfigLib.hookToBytes31(hook);
        Hook memory decoded = ExchangeRateValidatorConfigLib.bytes31ToHook(encoded);

        assertEq(decoded.hookAddress, maxAddress, "Max address should be preserved");
        assertEq(decoded.index, index, "Index should match");
    }

    /// @notice Test Hook with all possible index values (0-10)
    function testHookAllIndices() public {
        address hookAddress = address(0xabCDEF1234567890ABcDEF1234567890aBCDeF12);

        for (uint8 i = 0; i <= 10; i++) {
            Hook memory hook = Hook({hookAddress: hookAddress, index: i});

            bytes31 encoded = ExchangeRateValidatorConfigLib.hookToBytes31(hook);
            Hook memory decoded = ExchangeRateValidatorConfigLib.bytes31ToHook(encoded);

            assertEq(decoded.hookAddress, hookAddress, "Address should match");
            assertEq(decoded.index, i, "Index should match");
        }
    }

    /// @notice Fuzz test for Hook encoding/decoding
    function testFuzzHook(address hookAddress_, uint8 index_) public {
        Hook memory hook = Hook({hookAddress: hookAddress_, index: index_});

        bytes31 encoded = ExchangeRateValidatorConfigLib.hookToBytes31(hook);
        Hook memory decoded = ExchangeRateValidatorConfigLib.bytes31ToHook(encoded);

        assertEq(decoded.hookAddress, hookAddress_, "Fuzz: Address should match");
        assertEq(decoded.index, index_, "Fuzz: Index should match");
    }

    /// @notice Test Hook encoding layout verification
    function testHookEncodingLayout() public {
        address hookAddress = address(0x1234567890123456789012345678901234567890);
        uint8 index = 7;

        Hook memory hook = Hook({hookAddress: hookAddress, index: index});
        bytes31 encoded = ExchangeRateValidatorConfigLib.hookToBytes31(hook);

        // Verify address is in bits 88-247
        uint256 packed = uint256(uint248(encoded));
        address extractedAddress = address(uint160(packed >> 88));
        assertEq(extractedAddress, hookAddress, "Address should be in bits 88-247");

        // Verify index is in bits 80-87
        uint8 extractedIndex = uint8((packed >> 80) & 0xFF);
        assertEq(extractedIndex, index, "Index should be in bits 80-87");
    }

    // ============ ValidatorData Tests ============

    /// @notice Test basic encoding and decoding of ValidatorData
    function testValidatorDataEncodeDecode() public {
        uint128 exchangeRate = 123456789012345678901234567890;
        uint120 threshold = 987654321098765432109876543210;

        ValidatorData memory validatorData = ValidatorData({exchangeRate: exchangeRate, threshold: threshold});

        bytes31 encoded = ExchangeRateValidatorConfigLib.validatorDataToBytes31(validatorData);
        ValidatorData memory decoded = ExchangeRateValidatorConfigLib.bytes31ToValidatorData(encoded);

        assertEq(decoded.exchangeRate, exchangeRate, "Decoded exchangeRate should match");
        assertEq(decoded.threshold, threshold, "Decoded threshold should match");
    }

    /// @notice Test ValidatorData with zero values
    function testValidatorDataZeroValues() public {
        ValidatorData memory validatorData = ValidatorData({exchangeRate: 0, threshold: 0});

        bytes31 encoded = ExchangeRateValidatorConfigLib.validatorDataToBytes31(validatorData);
        ValidatorData memory decoded = ExchangeRateValidatorConfigLib.bytes31ToValidatorData(encoded);

        assertEq(decoded.exchangeRate, 0, "ExchangeRate should be zero");
        assertEq(decoded.threshold, 0, "Threshold should be zero");
    }

    /// @notice Test ValidatorData with maximum values
    function testValidatorDataMaxValues() public {
        uint128 maxExchangeRate = type(uint128).max;
        uint120 maxThreshold = type(uint120).max;

        ValidatorData memory validatorData = ValidatorData({exchangeRate: maxExchangeRate, threshold: maxThreshold});

        bytes31 encoded = ExchangeRateValidatorConfigLib.validatorDataToBytes31(validatorData);
        ValidatorData memory decoded = ExchangeRateValidatorConfigLib.bytes31ToValidatorData(encoded);

        assertEq(decoded.exchangeRate, maxExchangeRate, "ExchangeRate should be max");
        assertEq(decoded.threshold, maxThreshold, "Threshold should be max");
    }

    /// @notice Test ValidatorData encoding layout verification
    function testValidatorDataEncodingLayout() public {
        uint128 exchangeRate = 0x12345678901234567890123456789012;
        uint120 threshold = 0xabcdef1234567890abcdef123456;

        ValidatorData memory validatorData = ValidatorData({exchangeRate: exchangeRate, threshold: threshold});

        bytes31 encoded = ExchangeRateValidatorConfigLib.validatorDataToBytes31(validatorData);

        // Verify threshold is in first 120 bits
        uint256 packed = uint256(uint248(encoded));
        uint120 extractedThreshold = uint120(packed & type(uint120).max);
        assertEq(extractedThreshold, threshold, "Threshold should be in first 120 bits");

        // Verify exchangeRate is in bits 120-247
        uint128 extractedExchangeRate = uint128(packed >> 120);
        assertEq(extractedExchangeRate, exchangeRate, "ExchangeRate should be in bits 120-247");
    }

    /// @notice Fuzz test for ValidatorData encoding/decoding
    function testFuzzValidatorData(uint128 exchangeRate_, uint120 threshold_) public {
        ValidatorData memory validatorData = ValidatorData({exchangeRate: exchangeRate_, threshold: threshold_});

        bytes31 encoded = ExchangeRateValidatorConfigLib.validatorDataToBytes31(validatorData);
        ValidatorData memory decoded = ExchangeRateValidatorConfigLib.bytes31ToValidatorData(encoded);

        assertEq(decoded.exchangeRate, exchangeRate_, "Fuzz: ExchangeRate should match");
        assertEq(decoded.threshold, threshold_, "Fuzz: Threshold should match");
    }

    // ============ parseConfigs Tests ============

    /// @notice Test parseConfigs with empty array
    function testParseConfigsEmpty() public {
        bytes32[] memory configs = new bytes32[](0);

        (
            Hook[] memory preHooks,
            Hook[] memory postHooks,
            ValidatorData memory validationData,
            uint256 index
        ) = ExchangeRateValidatorConfigLib.parseConfigs(configs);

        assertEq(preHooks.length, 10, "PreHooks should have 10 elements");
        assertEq(postHooks.length, 10, "PostHooks should have 10 elements");
        assertEq(index, type(uint256).max, "Index should be max if not found");

        // All hooks should be empty
        for (uint256 i = 0; i < 10; i++) {
            assertEq(preHooks[i].hookAddress, address(0), "PreHook should be empty");
            assertEq(postHooks[i].hookAddress, address(0), "PostHook should be empty");
        }
    }

    /// @notice Test parseConfigs with single pre-hook
    function testParseConfigsSinglePreHook() public {
        address hookAddress = address(0x1111111111111111111111111111111111111111);
        uint8 index = 3;

        Hook memory hook = Hook({hookAddress: hookAddress, index: index});
        bytes31 hookData = ExchangeRateValidatorConfigLib.hookToBytes31(hook);

        ExchangeRateValidatorConfig memory config = ExchangeRateValidatorConfig({
            typ: HookType.PREHOOKS,
            data: hookData
        });

        bytes32[] memory configs = new bytes32[](1);
        configs[0] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(config);

        (Hook[] memory preHooks, Hook[] memory postHooks, , ) = ExchangeRateValidatorConfigLib.parseConfigs(configs);

        assertEq(preHooks[index].hookAddress, hookAddress, "PreHook should be at correct index");
        assertEq(preHooks[index].index, index, "PreHook index should match");

        // Other positions should be empty
        for (uint256 i = 0; i < 10; i++) {
            if (i != index) {
                assertEq(preHooks[i].hookAddress, address(0), "Other preHook positions should be empty");
            }
        }

        // All postHooks should be empty
        for (uint256 i = 0; i < 10; i++) {
            assertEq(postHooks[i].hookAddress, address(0), "All postHooks should be empty");
        }
    }

    /// @notice Test parseConfigs with single post-hook
    function testParseConfigsSinglePostHook() public {
        address hookAddress = address(0x2222222222222222222222222222222222222222);
        uint8 index = 7;

        Hook memory hook = Hook({hookAddress: hookAddress, index: index});
        bytes31 hookData = ExchangeRateValidatorConfigLib.hookToBytes31(hook);

        ExchangeRateValidatorConfig memory config = ExchangeRateValidatorConfig({
            typ: HookType.POSTHOOKS,
            data: hookData
        });

        bytes32[] memory configs = new bytes32[](1);
        configs[0] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(config);

        (Hook[] memory preHooks, Hook[] memory postHooks, , ) = ExchangeRateValidatorConfigLib.parseConfigs(configs);

        assertEq(postHooks[index].hookAddress, hookAddress, "PostHook should be at correct index");
        assertEq(postHooks[index].index, index, "PostHook index should match");

        // All preHooks should be empty
        for (uint256 i = 0; i < 10; i++) {
            assertEq(preHooks[i].hookAddress, address(0), "All preHooks should be empty");
        }
    }

    /// @notice Test parseConfigs with validator
    function testParseConfigsValidator() public {
        uint128 exchangeRate = 1000000000000000000;
        uint120 threshold = 500000000000000000;

        ValidatorData memory validatorData = ValidatorData({exchangeRate: exchangeRate, threshold: threshold});

        bytes31 validatorDataBytes = ExchangeRateValidatorConfigLib.validatorDataToBytes31(validatorData);

        ExchangeRateValidatorConfig memory config = ExchangeRateValidatorConfig({
            typ: HookType.VALIDATOR,
            data: validatorDataBytes
        });

        bytes32[] memory configs = new bytes32[](1);
        configs[0] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(config);

        (, , ValidatorData memory decodedValidationData, uint256 index) = ExchangeRateValidatorConfigLib.parseConfigs(
            configs
        );

        assertEq(decodedValidationData.exchangeRate, exchangeRate, "ExchangeRate should match");
        assertEq(decodedValidationData.threshold, threshold, "Threshold should match");
        assertEq(index, 0, "Index should be 0");
    }

    /// @notice Test parseConfigs with multiple hooks at different indices
    function testParseConfigsMultipleHooks() public {
        bytes32[] memory configs = new bytes32[](5);

        // PreHook at index 0
        Hook memory preHook0 = Hook({hookAddress: address(0x1000), index: 0});
        configs[0] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.PREHOOKS,
                data: ExchangeRateValidatorConfigLib.hookToBytes31(preHook0)
            })
        );

        // PreHook at index 5
        Hook memory preHook5 = Hook({hookAddress: address(0x5000), index: 5});
        configs[1] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.PREHOOKS,
                data: ExchangeRateValidatorConfigLib.hookToBytes31(preHook5)
            })
        );

        // PostHook at index 2
        Hook memory postHook2 = Hook({hookAddress: address(0x2000), index: 2});
        configs[2] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.POSTHOOKS,
                data: ExchangeRateValidatorConfigLib.hookToBytes31(postHook2)
            })
        );

        // PostHook at index 9
        Hook memory postHook9 = Hook({hookAddress: address(0x9000), index: 9});
        configs[3] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.POSTHOOKS,
                data: ExchangeRateValidatorConfigLib.hookToBytes31(postHook9)
            })
        );

        // Validator
        ValidatorData memory validatorData = ValidatorData({exchangeRate: 123, threshold: 456});
        configs[4] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.VALIDATOR,
                data: ExchangeRateValidatorConfigLib.validatorDataToBytes31(validatorData)
            })
        );

        (
            Hook[] memory preHooks,
            Hook[] memory postHooks,
            ValidatorData memory decodedValidatorData,
            uint256 index
        ) = ExchangeRateValidatorConfigLib.parseConfigs(configs);

        // Verify preHooks
        assertEq(preHooks[0].hookAddress, address(0x1000), "PreHook 0 should be correct");
        assertEq(preHooks[0].index, 0, "PreHook 0 index should be correct");
        assertEq(preHooks[5].hookAddress, address(0x5000), "PreHook 5 should be correct");
        assertEq(preHooks[5].index, 5, "PreHook 5 index should be correct");

        // Verify postHooks
        assertEq(postHooks[2].hookAddress, address(0x2000), "PostHook 2 should be correct");
        assertEq(postHooks[2].index, 2, "PostHook 2 index should be correct");
        assertEq(postHooks[9].hookAddress, address(0x9000), "PostHook 9 should be correct");
        assertEq(postHooks[9].index, 9, "PostHook 9 index should be correct");

        // Verify validator
        assertEq(decodedValidatorData.exchangeRate, 123, "Validator exchangeRate should match");
        assertEq(decodedValidatorData.threshold, 456, "Validator threshold should match");
        assertEq(index, 4, "Validator index should be 4");
    }

    /// @notice Test parseConfigs with all 10 pre-hooks
    function testParseConfigsAllPreHooks() public {
        bytes32[] memory configs = new bytes32[](10);

        for (uint8 i = 0; i < 10; i++) {
            Hook memory hook = Hook({hookAddress: address(uint160(1000 + i)), index: i});
            configs[i] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
                ExchangeRateValidatorConfig({
                    typ: HookType.PREHOOKS,
                    data: ExchangeRateValidatorConfigLib.hookToBytes31(hook)
                })
            );
        }

        (Hook[] memory preHooks, , , ) = ExchangeRateValidatorConfigLib.parseConfigs(configs);

        for (uint256 i = 0; i < 10; i++) {
            assertEq(preHooks[i].hookAddress, address(uint160(1000 + i)), "PreHook address should match");
            assertEq(preHooks[i].index, i, "PreHook index should match");
        }
    }

    /// @notice Test parseConfigs with all 10 post-hooks
    function testParseConfigsAllPostHooks() public {
        bytes32[] memory configs = new bytes32[](10);

        for (uint8 i = 0; i < 10; i++) {
            Hook memory hook = Hook({hookAddress: address(uint160(2000 + i)), index: i});
            configs[i] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
                ExchangeRateValidatorConfig({
                    typ: HookType.POSTHOOKS,
                    data: ExchangeRateValidatorConfigLib.hookToBytes31(hook)
                })
            );
        }

        (, Hook[] memory postHooks, , ) = ExchangeRateValidatorConfigLib.parseConfigs(configs);

        for (uint256 i = 0; i < 10; i++) {
            assertEq(postHooks[i].hookAddress, address(uint160(2000 + i)), "PostHook address should match");
            assertEq(postHooks[i].index, i, "PostHook index should match");
        }
    }

    /// @notice Test parseConfigs with validator at different positions
    function testParseConfigsValidatorPosition() public {
        ValidatorData memory validatorData = ValidatorData({exchangeRate: 999, threshold: 888});

        // Validator at position 0
        bytes32[] memory configs1 = new bytes32[](1);
        configs1[0] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.VALIDATOR,
                data: ExchangeRateValidatorConfigLib.validatorDataToBytes31(validatorData)
            })
        );

        (, , , uint256 index1) = ExchangeRateValidatorConfigLib.parseConfigs(configs1);
        assertEq(index1, 0, "Validator index should be 0");

        // Validator at position 5
        bytes32[] memory configs2 = new bytes32[](6);
        for (uint256 i = 0; i < 5; i++) {
            Hook memory hook = Hook({hookAddress: address(uint160(i)), index: uint8(i)});
            configs2[i] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
                ExchangeRateValidatorConfig({
                    typ: HookType.PREHOOKS,
                    data: ExchangeRateValidatorConfigLib.hookToBytes31(hook)
                })
            );
        }
        configs2[5] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.VALIDATOR,
                data: ExchangeRateValidatorConfigLib.validatorDataToBytes31(validatorData)
            })
        );

        (, , , uint256 index2) = ExchangeRateValidatorConfigLib.parseConfigs(configs2);
        assertEq(index2, 5, "Validator index should be 5");
    }

    /// @notice Test parseConfigs with multiple validators (only first one is used)
    function testParseConfigsMultipleValidators() public {
        ValidatorData memory validatorData1 = ValidatorData({exchangeRate: 111, threshold: 222});
        ValidatorData memory validatorData2 = ValidatorData({exchangeRate: 333, threshold: 444});

        bytes32[] memory configs = new bytes32[](2);
        configs[0] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.VALIDATOR,
                data: ExchangeRateValidatorConfigLib.validatorDataToBytes31(validatorData1)
            })
        );
        configs[1] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.VALIDATOR,
                data: ExchangeRateValidatorConfigLib.validatorDataToBytes31(validatorData2)
            })
        );

        (, , ValidatorData memory decodedValidationData, uint256 index) = ExchangeRateValidatorConfigLib.parseConfigs(
            configs
        );

        // Should use first validator
        assertEq(decodedValidationData.exchangeRate, 111, "Should use first validator");
        assertEq(decodedValidationData.threshold, 222, "Should use first validator");
        assertEq(index, 0, "Index should be 0");
    }

    // ============ Round-trip Tests ============

    /// @notice Test complete round-trip: Config -> bytes32 -> Config -> bytes32
    function testRoundTripExchangeRateValidatorConfig() public {
        // Use a value that fits in bytes31 (use smaller hex value that fits in uint256 - 14 bytes = 28 hex chars)
        uint256 dataValue = 0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef12345678;
        bytes31 dataBytes31 = bytes31(uint248(dataValue));
        ExchangeRateValidatorConfig memory original = ExchangeRateValidatorConfig({
            typ: HookType.PREHOOKS,
            data: dataBytes31
        });

        bytes32 encoded1 = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(original);
        ExchangeRateValidatorConfig memory decoded = ExchangeRateValidatorConfigLib
            .bytes32ToExchangeRateValidatorConfig(encoded1);
        bytes32 encoded2 = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(decoded);

        assertEq(encoded1, encoded2, "Round-trip encoding should be consistent");
        assertEq(uint256(decoded.typ), uint256(original.typ), "Round-trip: Type should match");
        assertEq(uint256(uint248(decoded.data)), uint256(uint248(original.data)), "Round-trip: Data should match");
    }

    /// @notice Test complete round-trip: Hook -> bytes31 -> Hook -> bytes31
    function testRoundTripHook() public {
        Hook memory original = Hook({hookAddress: address(0x1234567890123456789012345678901234567890), index: 7});

        bytes31 encoded1 = ExchangeRateValidatorConfigLib.hookToBytes31(original);
        Hook memory decoded = ExchangeRateValidatorConfigLib.bytes31ToHook(encoded1);
        bytes31 encoded2 = ExchangeRateValidatorConfigLib.hookToBytes31(decoded);

        assertEq(uint256(uint248(encoded1)), uint256(uint248(encoded2)), "Round-trip encoding should be consistent");
        assertEq(decoded.hookAddress, original.hookAddress, "Round-trip: Address should match");
        assertEq(decoded.index, original.index, "Round-trip: Index should match");
    }

    /// @notice Test complete round-trip: ValidatorData -> bytes31 -> ValidatorData -> bytes31
    function testRoundTripValidatorData() public {
        ValidatorData memory original = ValidatorData({
            exchangeRate: 123456789012345678901234567890,
            threshold: 987654321098765432109876543210
        });

        bytes31 encoded1 = ExchangeRateValidatorConfigLib.validatorDataToBytes31(original);
        ValidatorData memory decoded = ExchangeRateValidatorConfigLib.bytes31ToValidatorData(encoded1);
        bytes31 encoded2 = ExchangeRateValidatorConfigLib.validatorDataToBytes31(decoded);

        assertEq(uint256(uint248(encoded1)), uint256(uint248(encoded2)), "Round-trip encoding should be consistent");
        assertEq(decoded.exchangeRate, original.exchangeRate, "Round-trip: ExchangeRate should match");
        assertEq(decoded.threshold, original.threshold, "Round-trip: Threshold should match");
    }
}
