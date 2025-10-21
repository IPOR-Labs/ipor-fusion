// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {EnsoSubstrateLib, Substrat} from "../../../contracts/fuses/enso/EnsoSubstrateLib.sol";

/// @title EnsoSubstrateLibTest
/// @dev Test contract for EnsoSubstrateLib encoding and decoding functions
contract EnsoSubstrateLibTest is Test {
    using EnsoSubstrateLib for Substrat;

    /// @notice Test basic encoding and decoding of a Substrat struct
    function test_encode_decode_BasicSubstrat() public {
        address target = 0x1234567890123456789012345678901234567890;
        bytes4 functionSelector = bytes4(keccak256("transfer(address,uint256)"));

        Substrat memory substrat = Substrat({target_: target, functionSelector_: functionSelector});

        bytes32 encoded = EnsoSubstrateLib.encode(substrat);
        Substrat memory decoded = EnsoSubstrateLib.decode(encoded);

        assertEq(decoded.target_, target, "Decoded target should match original");
        assertEq(decoded.functionSelector_, functionSelector, "Decoded function selector should match original");
    }

    /// @notice Test encoding and decoding with zero address
    function test_encode_decode_ZeroAddress() public {
        address target = address(0);
        bytes4 functionSelector = 0x12345678;

        Substrat memory substrat = Substrat({target_: target, functionSelector_: functionSelector});

        bytes32 encoded = EnsoSubstrateLib.encode(substrat);
        Substrat memory decoded = EnsoSubstrateLib.decode(encoded);

        assertEq(decoded.target_, target, "Decoded zero address should match");
        assertEq(decoded.functionSelector_, functionSelector, "Decoded function selector should match");
    }

    /// @notice Test encoding and decoding with various function selectors
    function test_encode_decode_VariousSelectors() public {
        address target = 0xabCDEF1234567890ABcDEF1234567890aBCDeF12;

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = bytes4(keccak256("transfer(address,uint256)"));
        selectors[1] = bytes4(keccak256("approve(address,uint256)"));
        selectors[2] = bytes4(keccak256("balanceOf(address)"));
        selectors[3] = bytes4(0x00000000);
        selectors[4] = bytes4(0xFFFFFFFF);

        for (uint256 i = 0; i < selectors.length; i++) {
            Substrat memory substrat = Substrat({target_: target, functionSelector_: selectors[i]});

            bytes32 encoded = EnsoSubstrateLib.encode(substrat);
            Substrat memory decoded = EnsoSubstrateLib.decode(encoded);

            assertEq(
                decoded.target_,
                target,
                string.concat("Decoded target should match for selector ", vm.toString(i))
            );
            assertEq(
                decoded.functionSelector_,
                selectors[i],
                string.concat("Decoded selector should match for selector ", vm.toString(i))
            );
        }
    }

    /// @notice Test encodeRaw function
    function test_encodeRaw_BasicEncoding() public {
        address target = 0x9876543210987654321098765432109876543210;
        bytes4 functionSelector = bytes4(keccak256("swap(address,uint256)"));

        bytes32 encoded = EnsoSubstrateLib.encodeRaw(target, functionSelector);
        (address decodedTarget, bytes4 decodedSelector) = EnsoSubstrateLib.decodeRaw(encoded);

        assertEq(decodedTarget, target, "Decoded target should match original");
        assertEq(decodedSelector, functionSelector, "Decoded function selector should match original");
    }

    /// @notice Test decodeRaw function
    function test_decodeRaw_BasicDecoding() public {
        address target = 0xabCDeF0123456789AbcdEf0123456789aBCDEF01;
        bytes4 functionSelector = 0xABCD1234;

        bytes32 encoded = EnsoSubstrateLib.encodeRaw(target, functionSelector);
        (address decodedTarget, bytes4 decodedSelector) = EnsoSubstrateLib.decodeRaw(encoded);

        assertEq(decodedTarget, target, "Decoded target should match original");
        assertEq(decodedSelector, functionSelector, "Decoded function selector should match original");
    }

    /// @notice Test getTarget function
    function test_getTarget_ExtractAddress() public {
        address target = 0x1111111111111111111111111111111111111111;
        bytes4 functionSelector = 0x22222222;

        bytes32 encoded = EnsoSubstrateLib.encodeRaw(target, functionSelector);
        address extractedTarget = EnsoSubstrateLib.getTarget(encoded);

        assertEq(extractedTarget, target, "Extracted target should match original");
    }

    /// @notice Test getFunctionSelector function
    function test_getFunctionSelector_ExtractSelector() public {
        address target = 0x3333333333333333333333333333333333333333;
        bytes4 functionSelector = 0x44444444;

        bytes32 encoded = EnsoSubstrateLib.encodeRaw(target, functionSelector);
        bytes4 extractedSelector = EnsoSubstrateLib.getFunctionSelector(encoded);

        assertEq(extractedSelector, functionSelector, "Extracted function selector should match original");
    }

    /// @notice Test that encode/decode is reversible for multiple substrats
    function test_encode_decode_Reversibility() public {
        address[] memory targets = new address[](3);
        targets[0] = 0x0000000000000000000000000000000000000001;
        targets[1] = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
        targets[2] = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D; // Uniswap router

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = bytes4(keccak256("deposit()"));
        selectors[1] = bytes4(keccak256("withdraw(uint256)"));
        selectors[2] = bytes4(keccak256("swapExactTokensForTokens(uint256,uint256,address[],address,uint256)"));

        for (uint256 i = 0; i < targets.length; i++) {
            Substrat memory original = Substrat({target_: targets[i], functionSelector_: selectors[i]});

            bytes32 encoded = EnsoSubstrateLib.encode(original);
            Substrat memory decoded = EnsoSubstrateLib.decode(encoded);

            assertEq(decoded.target_, original.target_, "Reversibility: target should match");
            assertEq(decoded.functionSelector_, original.functionSelector_, "Reversibility: selector should match");
        }
    }

    /// @notice Test that encoding produces consistent results
    function test_encode_Consistency() public {
        address target = 0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF;
        bytes4 functionSelector = 0xCAFEBABE;

        Substrat memory substrat = Substrat({target_: target, functionSelector_: functionSelector});

        bytes32 encoded1 = EnsoSubstrateLib.encode(substrat);
        bytes32 encoded2 = EnsoSubstrateLib.encode(substrat);
        bytes32 encoded3 = EnsoSubstrateLib.encodeRaw(target, functionSelector);

        assertEq(encoded1, encoded2, "Multiple encode calls should produce same result");
        assertEq(encoded1, encoded3, "encode and encodeRaw should produce same result");
    }

    /// @notice Test encoding layout - verify bytes are in correct positions
    function test_encode_LayoutVerification() public {
        address target = 0x1234567890123456789012345678901234567890;
        bytes4 functionSelector = 0xABCDEF01;

        bytes32 encoded = EnsoSubstrateLib.encodeRaw(target, functionSelector);

        // Extract address manually from first 20 bytes
        address extractedAddress = address(uint160(uint256(encoded) >> 96));
        assertEq(extractedAddress, target, "Address should be in first 20 bytes");

        // Extract function selector manually from bytes 20-24
        bytes4 extractedSelector = bytes4(uint32(uint256(encoded) >> 64));
        assertEq(extractedSelector, functionSelector, "Function selector should be in bytes 20-24");
    }

    /// @notice Test with maximum address value
    function test_encode_decode_MaxAddress() public {
        address target = address(type(uint160).max);
        bytes4 functionSelector = 0x11223344;

        Substrat memory substrat = Substrat({target_: target, functionSelector_: functionSelector});

        bytes32 encoded = EnsoSubstrateLib.encode(substrat);
        Substrat memory decoded = EnsoSubstrateLib.decode(encoded);

        assertEq(decoded.target_, target, "Max address should be encoded/decoded correctly");
        assertEq(decoded.functionSelector_, functionSelector, "Function selector should be preserved");
    }

    /// @notice Fuzz test for encode/decode operations
    function testFuzz_encode_decode_Reversibility(address target_, bytes4 functionSelector_) public {
        Substrat memory substrat = Substrat({target_: target_, functionSelector_: functionSelector_});

        bytes32 encoded = EnsoSubstrateLib.encode(substrat);
        Substrat memory decoded = EnsoSubstrateLib.decode(encoded);

        assertEq(decoded.target_, target_, "Fuzz: Decoded target should match original");
        assertEq(decoded.functionSelector_, functionSelector_, "Fuzz: Decoded selector should match original");
    }

    /// @notice Fuzz test for encodeRaw/decodeRaw operations
    function testFuzz_encodeRaw_decodeRaw_Reversibility(address target_, bytes4 functionSelector_) public {
        bytes32 encoded = EnsoSubstrateLib.encodeRaw(target_, functionSelector_);
        (address decodedTarget, bytes4 decodedSelector) = EnsoSubstrateLib.decodeRaw(encoded);

        assertEq(decodedTarget, target_, "Fuzz: Decoded target should match original");
        assertEq(decodedSelector, functionSelector_, "Fuzz: Decoded selector should match original");
    }

    /// @notice Fuzz test for getTarget
    function testFuzz_getTarget(address target_, bytes4 functionSelector_) public {
        bytes32 encoded = EnsoSubstrateLib.encodeRaw(target_, functionSelector_);
        address extractedTarget = EnsoSubstrateLib.getTarget(encoded);

        assertEq(extractedTarget, target_, "Fuzz: Extracted target should match original");
    }

    /// @notice Fuzz test for getFunctionSelector
    function testFuzz_getFunctionSelector(address target_, bytes4 functionSelector_) public {
        bytes32 encoded = EnsoSubstrateLib.encodeRaw(target_, functionSelector_);
        bytes4 extractedSelector = EnsoSubstrateLib.getFunctionSelector(encoded);

        assertEq(extractedSelector, functionSelector_, "Fuzz: Extracted selector should match original");
    }

    /// @notice Test that different inputs produce different encodings
    function test_encode_UniquenessVerification() public {
        address target1 = 0x1111111111111111111111111111111111111111;
        address target2 = 0x2222222222222222222222222222222222222222;
        bytes4 selector1 = 0x11111111;
        bytes4 selector2 = 0x22222222;

        bytes32 encoded1 = EnsoSubstrateLib.encodeRaw(target1, selector1);
        bytes32 encoded2 = EnsoSubstrateLib.encodeRaw(target2, selector1);
        bytes32 encoded3 = EnsoSubstrateLib.encodeRaw(target1, selector2);
        bytes32 encoded4 = EnsoSubstrateLib.encodeRaw(target2, selector2);

        assertTrue(encoded1 != encoded2, "Different targets should produce different encodings");
        assertTrue(encoded1 != encoded3, "Different selectors should produce different encodings");
        assertTrue(encoded1 != encoded4, "Different targets and selectors should produce different encodings");
        assertTrue(encoded2 != encoded3, "Combinations should all be unique");
    }

    /// @notice Test real-world ERC20 function selectors
    function test_encode_decode_RealWorldSelectors() public {
        address usdcAddress = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        bytes4 transferSelector = bytes4(keccak256("transfer(address,uint256)"));
        bytes4 approveSelector = bytes4(keccak256("approve(address,uint256)"));
        bytes4 transferFromSelector = bytes4(keccak256("transferFrom(address,address,uint256)"));
        bytes4 balanceOfSelector = bytes4(keccak256("balanceOf(address)"));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = transferSelector;
        selectors[1] = approveSelector;
        selectors[2] = transferFromSelector;
        selectors[3] = balanceOfSelector;

        for (uint256 i = 0; i < selectors.length; i++) {
            Substrat memory substrat = Substrat({target_: usdcAddress, functionSelector_: selectors[i]});

            bytes32 encoded = EnsoSubstrateLib.encode(substrat);
            Substrat memory decoded = EnsoSubstrateLib.decode(encoded);

            assertEq(decoded.target_, usdcAddress, "USDC address should be preserved");
            assertEq(decoded.functionSelector_, selectors[i], "ERC20 selector should be preserved");
        }
    }
}
