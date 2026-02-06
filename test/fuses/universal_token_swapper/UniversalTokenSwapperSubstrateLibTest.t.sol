// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {UniversalTokenSwapperSubstrateLib, UniversalTokenSwapperSubstrateType} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperSubstrateLib.sol";

/// @title UniversalTokenSwapperSubstrateLibTest
/// @notice Unit tests for UniversalTokenSwapperSubstrateLib encoding/decoding
contract UniversalTokenSwapperSubstrateLibTest is Test {
    // Test addresses
    address internal constant TEST_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant TEST_TARGET = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    // ==================== Token Substrate Tests ====================

    function testEncodeTokenSubstrate() public pure {
        bytes32 encoded = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(TEST_TOKEN);

        // Check type byte is Token (1)
        uint8 substrateType = uint8(uint256(encoded) >> 248);
        assertEq(substrateType, uint8(UniversalTokenSwapperSubstrateType.Token), "Type should be Token");

        // Check address is encoded correctly
        address decodedAddress = address(uint160(uint256(encoded)));
        assertEq(decodedAddress, TEST_TOKEN, "Address should match");
    }

    function testDecodeTokenSubstrate() public pure {
        bytes32 encoded = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(TEST_TOKEN);
        address decoded = UniversalTokenSwapperSubstrateLib.decodeToken(encoded);
        assertEq(decoded, TEST_TOKEN, "Decoded token should match original");
    }

    function testIsTokenSubstrate() public pure {
        bytes32 tokenSubstrate = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(TEST_TOKEN);
        bytes32 targetSubstrate = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(TEST_TARGET);
        bytes32 slippageSubstrate = UniversalTokenSwapperSubstrateLib.encodeSlippageSubstrate(1e16);

        assertTrue(UniversalTokenSwapperSubstrateLib.isTokenSubstrate(tokenSubstrate), "Should be token substrate");
        assertFalse(UniversalTokenSwapperSubstrateLib.isTokenSubstrate(targetSubstrate), "Should not be token substrate");
        assertFalse(UniversalTokenSwapperSubstrateLib.isTokenSubstrate(slippageSubstrate), "Should not be token substrate");
    }

    function testFuzzEncodeDecodeToken(address token_) public {
        vm.assume(token_ != address(0));
        bytes32 encoded = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(token_);
        address decoded = UniversalTokenSwapperSubstrateLib.decodeToken(encoded);
        assertEq(decoded, token_, "Fuzz: Decoded token should match original");
        assertTrue(UniversalTokenSwapperSubstrateLib.isTokenSubstrate(encoded), "Fuzz: Should be token substrate");
    }

    // ==================== Target Substrate Tests ====================

    function testEncodeTargetSubstrate() public pure {
        bytes32 encoded = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(TEST_TARGET);

        // Check type byte is Target (2)
        uint8 substrateType = uint8(uint256(encoded) >> 248);
        assertEq(substrateType, uint8(UniversalTokenSwapperSubstrateType.Target), "Type should be Target");

        // Check address is encoded correctly
        address decodedAddress = address(uint160(uint256(encoded)));
        assertEq(decodedAddress, TEST_TARGET, "Address should match");
    }

    function testDecodeTargetSubstrate() public pure {
        bytes32 encoded = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(TEST_TARGET);
        address decoded = UniversalTokenSwapperSubstrateLib.decodeTarget(encoded);
        assertEq(decoded, TEST_TARGET, "Decoded target should match original");
    }

    function testIsTargetSubstrate() public pure {
        bytes32 tokenSubstrate = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(TEST_TOKEN);
        bytes32 targetSubstrate = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(TEST_TARGET);
        bytes32 slippageSubstrate = UniversalTokenSwapperSubstrateLib.encodeSlippageSubstrate(1e16);

        assertFalse(UniversalTokenSwapperSubstrateLib.isTargetSubstrate(tokenSubstrate), "Should not be target substrate");
        assertTrue(UniversalTokenSwapperSubstrateLib.isTargetSubstrate(targetSubstrate), "Should be target substrate");
        assertFalse(UniversalTokenSwapperSubstrateLib.isTargetSubstrate(slippageSubstrate), "Should not be target substrate");
    }

    function testFuzzEncodeDecodeTarget(address target_) public {
        vm.assume(target_ != address(0));
        bytes32 encoded = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(target_);
        address decoded = UniversalTokenSwapperSubstrateLib.decodeTarget(encoded);
        assertEq(decoded, target_, "Fuzz: Decoded target should match original");
        assertTrue(UniversalTokenSwapperSubstrateLib.isTargetSubstrate(encoded), "Fuzz: Should be target substrate");
    }

    // ==================== Slippage Substrate Tests ====================

    function testEncodeSlippageSubstrate() public pure {
        uint256 slippage = 1e16; // 1%
        bytes32 encoded = UniversalTokenSwapperSubstrateLib.encodeSlippageSubstrate(slippage);

        // Check type byte is Slippage (3)
        uint8 substrateType = uint8(uint256(encoded) >> 248);
        assertEq(substrateType, uint8(UniversalTokenSwapperSubstrateType.Slippage), "Type should be Slippage");

        // Check slippage is encoded correctly
        uint256 decodedSlippage = uint256(encoded) & type(uint248).max;
        assertEq(decodedSlippage, slippage, "Slippage should match");
    }

    function testDecodeSlippageSubstrate() public pure {
        uint256 slippage = 5e16; // 5%
        bytes32 encoded = UniversalTokenSwapperSubstrateLib.encodeSlippageSubstrate(slippage);
        uint256 decoded = UniversalTokenSwapperSubstrateLib.decodeSlippage(encoded);
        assertEq(decoded, slippage, "Decoded slippage should match original");
    }

    function testIsSlippageSubstrate() public pure {
        bytes32 tokenSubstrate = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(TEST_TOKEN);
        bytes32 targetSubstrate = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(TEST_TARGET);
        bytes32 slippageSubstrate = UniversalTokenSwapperSubstrateLib.encodeSlippageSubstrate(1e16);

        assertFalse(UniversalTokenSwapperSubstrateLib.isSlippageSubstrate(tokenSubstrate), "Should not be slippage substrate");
        assertFalse(UniversalTokenSwapperSubstrateLib.isSlippageSubstrate(targetSubstrate), "Should not be slippage substrate");
        assertTrue(UniversalTokenSwapperSubstrateLib.isSlippageSubstrate(slippageSubstrate), "Should be slippage substrate");
    }

    function testSlippageSubstrateMaxValue() public pure {
        uint256 maxSlippage = type(uint248).max;
        bytes32 encoded = UniversalTokenSwapperSubstrateLib.encodeSlippageSubstrate(maxSlippage);
        uint256 decoded = UniversalTokenSwapperSubstrateLib.decodeSlippage(encoded);
        assertEq(decoded, maxSlippage, "Max slippage should be preserved");
    }

    function testSlippageSubstrateOverflowReverts() public {
        uint256 overflowSlippage = uint256(type(uint248).max) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalTokenSwapperSubstrateLib.UniversalTokenSwapperSubstrateLibSlippageOverflow.selector,
                overflowSlippage
            )
        );
        this.encodeSlippageExternal(overflowSlippage);
    }

    /// @notice External wrapper for testing revert
    function encodeSlippageExternal(uint256 slippage_) external pure returns (bytes32) {
        return UniversalTokenSwapperSubstrateLib.encodeSlippageSubstrate(slippage_);
    }

    function testFuzzEncodeDecodeSlippage(uint248 slippage_) public pure {
        uint256 slippage = uint256(slippage_);
        bytes32 encoded = UniversalTokenSwapperSubstrateLib.encodeSlippageSubstrate(slippage);
        uint256 decoded = UniversalTokenSwapperSubstrateLib.decodeSlippage(encoded);
        assertEq(decoded, slippage, "Fuzz: Decoded slippage should match original");
        assertTrue(UniversalTokenSwapperSubstrateLib.isSlippageSubstrate(encoded), "Fuzz: Should be slippage substrate");
    }

    // ==================== Substrate Type Tests ====================

    function testDecodeSubstrateType() public pure {
        bytes32 tokenSubstrate = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(TEST_TOKEN);
        bytes32 targetSubstrate = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(TEST_TARGET);
        bytes32 slippageSubstrate = UniversalTokenSwapperSubstrateLib.encodeSlippageSubstrate(1e16);

        assertEq(
            uint8(UniversalTokenSwapperSubstrateLib.decodeSubstrateType(tokenSubstrate)),
            uint8(UniversalTokenSwapperSubstrateType.Token),
            "Token type"
        );
        assertEq(
            uint8(UniversalTokenSwapperSubstrateLib.decodeSubstrateType(targetSubstrate)),
            uint8(UniversalTokenSwapperSubstrateType.Target),
            "Target type"
        );
        assertEq(
            uint8(UniversalTokenSwapperSubstrateLib.decodeSubstrateType(slippageSubstrate)),
            uint8(UniversalTokenSwapperSubstrateType.Slippage),
            "Slippage type"
        );
    }

    function testUnknownSubstrateType() public pure {
        // bytes32 with type = 0 (Unknown)
        bytes32 unknownSubstrate = bytes32(uint256(uint160(TEST_TOKEN)));

        assertEq(
            uint8(UniversalTokenSwapperSubstrateLib.decodeSubstrateType(unknownSubstrate)),
            uint8(UniversalTokenSwapperSubstrateType.Unknown),
            "Should be Unknown type"
        );
        assertFalse(UniversalTokenSwapperSubstrateLib.isTokenSubstrate(unknownSubstrate), "Not token");
        assertFalse(UniversalTokenSwapperSubstrateLib.isTargetSubstrate(unknownSubstrate), "Not target");
        assertFalse(UniversalTokenSwapperSubstrateLib.isSlippageSubstrate(unknownSubstrate), "Not slippage");
    }

    // ==================== Edge Cases ====================

    function testZeroAddressTokenReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalTokenSwapperSubstrateLib.UniversalTokenSwapperSubstrateLibZeroAddress.selector
            )
        );
        this.encodeTokenExternal(address(0));
    }

    function testZeroAddressTargetReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalTokenSwapperSubstrateLib.UniversalTokenSwapperSubstrateLibZeroAddress.selector
            )
        );
        this.encodeTargetExternal(address(0));
    }

    /// @notice External wrapper for testing revert
    function encodeTokenExternal(address token_) external pure returns (bytes32) {
        return UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(token_);
    }

    /// @notice External wrapper for testing revert
    function encodeTargetExternal(address target_) external pure returns (bytes32) {
        return UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(target_);
    }

    function testZeroSlippage() public pure {
        bytes32 encoded = UniversalTokenSwapperSubstrateLib.encodeSlippageSubstrate(0);
        uint256 decoded = UniversalTokenSwapperSubstrateLib.decodeSlippage(encoded);
        assertEq(decoded, 0, "Zero slippage should be preserved");
        assertTrue(UniversalTokenSwapperSubstrateLib.isSlippageSubstrate(encoded), "Should still be slippage substrate");
    }

    function testCommonSlippageValues() public pure {
        // Test common slippage values used in DeFi
        uint256[] memory slippages = new uint256[](5);
        slippages[0] = 1e15;  // 0.1%
        slippages[1] = 5e15;  // 0.5%
        slippages[2] = 1e16;  // 1%
        slippages[3] = 5e16;  // 5%
        slippages[4] = 1e17;  // 10%

        for (uint256 i; i < slippages.length; ++i) {
            bytes32 encoded = UniversalTokenSwapperSubstrateLib.encodeSlippageSubstrate(slippages[i]);
            uint256 decoded = UniversalTokenSwapperSubstrateLib.decodeSlippage(encoded);
            assertEq(decoded, slippages[i], "Common slippage value should be preserved");
        }
    }

    // ==================== Substrate Differentiation Tests ====================

    function testSameAddressDifferentTypes() public pure {
        // Same address encoded as Token and Target should produce different substrates
        address sameAddress = TEST_TOKEN;

        bytes32 asToken = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(sameAddress);
        bytes32 asTarget = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(sameAddress);

        // They should be different because type byte differs
        assertTrue(asToken != asTarget, "Same address with different types should produce different substrates");

        // But should decode to same address
        assertEq(
            UniversalTokenSwapperSubstrateLib.decodeToken(asToken),
            UniversalTokenSwapperSubstrateLib.decodeTarget(asTarget),
            "Decoded addresses should match"
        );
    }
}
