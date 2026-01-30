// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AaveV4SubstrateLib, AaveV4SubstrateType} from "../../../contracts/fuses/aave_v4/AaveV4SubstrateLib.sol";

/// @title AaveV4SubstrateLibTest
/// @notice Unit tests for AaveV4SubstrateLib encoding and decoding
contract AaveV4SubstrateLibTest is Test {
    address public constant SAMPLE_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant SAMPLE_SPOKE = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // ============ Encode Tests ============

    function testShouldEncodeAssetSubstrate() public pure {
        // when
        bytes32 encoded = AaveV4SubstrateLib.encodeAsset(SAMPLE_ADDRESS);

        // then
        uint8 flag = uint8(uint256(encoded) >> 248);
        assertEq(flag, uint8(AaveV4SubstrateType.Asset), "Flag should be 1 (Asset)");

        address decoded = address(uint160(uint256(encoded)));
        assertEq(decoded, SAMPLE_ADDRESS, "Address should be preserved");
    }

    function testShouldEncodeSpokeSubstrate() public pure {
        // when
        bytes32 encoded = AaveV4SubstrateLib.encodeSpoke(SAMPLE_SPOKE);

        // then
        uint8 flag = uint8(uint256(encoded) >> 248);
        assertEq(flag, uint8(AaveV4SubstrateType.Spoke), "Flag should be 2 (Spoke)");

        address decoded = address(uint160(uint256(encoded)));
        assertEq(decoded, SAMPLE_SPOKE, "Address should be preserved");
    }

    // ============ Decode Type Tests ============

    function testShouldDecodeAssetSubstrateType() public pure {
        // given
        bytes32 encoded = AaveV4SubstrateLib.encodeAsset(SAMPLE_ADDRESS);

        // when
        AaveV4SubstrateType substrateType = AaveV4SubstrateLib.decodeSubstrateType(encoded);

        // then
        assertEq(uint8(substrateType), uint8(AaveV4SubstrateType.Asset));
    }

    function testShouldDecodeSpokeSubstrateType() public pure {
        // given
        bytes32 encoded = AaveV4SubstrateLib.encodeSpoke(SAMPLE_SPOKE);

        // when
        AaveV4SubstrateType substrateType = AaveV4SubstrateLib.decodeSubstrateType(encoded);

        // then
        assertEq(uint8(substrateType), uint8(AaveV4SubstrateType.Spoke));
    }

    // ============ Decode Address Tests ============

    function testShouldDecodeAddressFromAssetSubstrate() public pure {
        // given
        bytes32 encoded = AaveV4SubstrateLib.encodeAsset(SAMPLE_ADDRESS);

        // when
        address decoded = AaveV4SubstrateLib.decodeAddress(encoded);

        // then
        assertEq(decoded, SAMPLE_ADDRESS);
    }

    function testShouldDecodeAddressFromSpokeSubstrate() public pure {
        // given
        bytes32 encoded = AaveV4SubstrateLib.encodeSpoke(SAMPLE_SPOKE);

        // when
        address decoded = AaveV4SubstrateLib.decodeAddress(encoded);

        // then
        assertEq(decoded, SAMPLE_SPOKE);
    }

    // ============ Zero/Undefined Tests ============

    function testShouldReturnUndefinedForZeroBytes32() public pure {
        // when
        AaveV4SubstrateType substrateType = AaveV4SubstrateLib.decodeSubstrateType(bytes32(0));

        // then
        assertEq(uint8(substrateType), uint8(AaveV4SubstrateType.Undefined));
    }

    // ============ isAssetSubstrate Tests ============

    function testShouldReturnTrueForIsAssetSubstrate() public pure {
        // given
        bytes32 encoded = AaveV4SubstrateLib.encodeAsset(SAMPLE_ADDRESS);

        // then
        assertTrue(AaveV4SubstrateLib.isAssetSubstrate(encoded));
    }

    function testShouldReturnFalseForIsAssetSubstrateWhenSpoke() public pure {
        // given
        bytes32 encoded = AaveV4SubstrateLib.encodeSpoke(SAMPLE_SPOKE);

        // then
        assertFalse(AaveV4SubstrateLib.isAssetSubstrate(encoded));
    }

    function testShouldReturnFalseForIsAssetSubstrateWhenZero() public pure {
        // then
        assertFalse(AaveV4SubstrateLib.isAssetSubstrate(bytes32(0)));
    }

    // ============ isSpokeSubstrate Tests ============

    function testShouldReturnTrueForIsSpokeSubstrate() public pure {
        // given
        bytes32 encoded = AaveV4SubstrateLib.encodeSpoke(SAMPLE_SPOKE);

        // then
        assertTrue(AaveV4SubstrateLib.isSpokeSubstrate(encoded));
    }

    function testShouldReturnFalseForIsSpokeSubstrateWhenAsset() public pure {
        // given
        bytes32 encoded = AaveV4SubstrateLib.encodeAsset(SAMPLE_ADDRESS);

        // then
        assertFalse(AaveV4SubstrateLib.isSpokeSubstrate(encoded));
    }

    function testShouldReturnFalseForIsSpokeSubstrateWhenZero() public pure {
        // then
        assertFalse(AaveV4SubstrateLib.isSpokeSubstrate(bytes32(0)));
    }

    // ============ Round-trip Tests ============

    function testShouldEncodeAndDecodeRoundTrip() public pure {
        // Asset round-trip
        bytes32 assetEncoded = AaveV4SubstrateLib.encodeAsset(SAMPLE_ADDRESS);
        assertEq(AaveV4SubstrateLib.decodeAddress(assetEncoded), SAMPLE_ADDRESS);
        assertTrue(AaveV4SubstrateLib.isAssetSubstrate(assetEncoded));

        // Spoke round-trip
        bytes32 spokeEncoded = AaveV4SubstrateLib.encodeSpoke(SAMPLE_SPOKE);
        assertEq(AaveV4SubstrateLib.decodeAddress(spokeEncoded), SAMPLE_SPOKE);
        assertTrue(AaveV4SubstrateLib.isSpokeSubstrate(spokeEncoded));
    }

    function testShouldProduceDifferentEncodingsForSameAddress() public pure {
        // given
        address addr = SAMPLE_ADDRESS;

        // when
        bytes32 assetEncoded = AaveV4SubstrateLib.encodeAsset(addr);
        bytes32 spokeEncoded = AaveV4SubstrateLib.encodeSpoke(addr);

        // then
        assertTrue(assetEncoded != spokeEncoded, "Same address as Asset vs Spoke must produce different bytes32");
    }

    // ============ Edge Case Tests ============

    function testShouldHandleMaxAddress() public pure {
        // given
        address maxAddr = address(type(uint160).max);

        // when
        bytes32 assetEncoded = AaveV4SubstrateLib.encodeAsset(maxAddr);
        bytes32 spokeEncoded = AaveV4SubstrateLib.encodeSpoke(maxAddr);

        // then
        assertEq(AaveV4SubstrateLib.decodeAddress(assetEncoded), maxAddr);
        assertEq(AaveV4SubstrateLib.decodeAddress(spokeEncoded), maxAddr);
        assertTrue(AaveV4SubstrateLib.isAssetSubstrate(assetEncoded));
        assertTrue(AaveV4SubstrateLib.isSpokeSubstrate(spokeEncoded));
    }

    function testShouldHandleZeroAddress() public pure {
        // when
        bytes32 assetEncoded = AaveV4SubstrateLib.encodeAsset(address(0));
        bytes32 spokeEncoded = AaveV4SubstrateLib.encodeSpoke(address(0));

        // then - type flag is preserved even with zero address
        assertTrue(AaveV4SubstrateLib.isAssetSubstrate(assetEncoded));
        assertTrue(AaveV4SubstrateLib.isSpokeSubstrate(spokeEncoded));
        assertEq(AaveV4SubstrateLib.decodeAddress(assetEncoded), address(0));
        assertEq(AaveV4SubstrateLib.decodeAddress(spokeEncoded), address(0));

        // And they differ from bare bytes32(0)
        assertTrue(assetEncoded != bytes32(0));
        assertTrue(spokeEncoded != bytes32(0));
    }

    // ============ Fuzz Tests ============

    function testFuzzEncodeDecodeAsset(address addr_) public pure {
        // when
        bytes32 encoded = AaveV4SubstrateLib.encodeAsset(addr_);

        // then
        assertEq(AaveV4SubstrateLib.decodeAddress(encoded), addr_);
        assertTrue(AaveV4SubstrateLib.isAssetSubstrate(encoded));
        assertFalse(AaveV4SubstrateLib.isSpokeSubstrate(encoded));
        assertEq(uint8(AaveV4SubstrateLib.decodeSubstrateType(encoded)), uint8(AaveV4SubstrateType.Asset));
    }

    function testFuzzEncodeDecodeSpoke(address addr_) public pure {
        // when
        bytes32 encoded = AaveV4SubstrateLib.encodeSpoke(addr_);

        // then
        assertEq(AaveV4SubstrateLib.decodeAddress(encoded), addr_);
        assertTrue(AaveV4SubstrateLib.isSpokeSubstrate(encoded));
        assertFalse(AaveV4SubstrateLib.isAssetSubstrate(encoded));
        assertEq(uint8(AaveV4SubstrateLib.decodeSubstrateType(encoded)), uint8(AaveV4SubstrateType.Spoke));
    }

    // ============ Invalid Flag Tests ============

    function testShouldReturnUndefinedForInvalidFlag() public pure {
        // given - construct bytes32 with flag = 3 (invalid, beyond Spoke=2)
        bytes32 invalidSubstrate = bytes32(uint256(3) << 248 | uint256(uint160(SAMPLE_ADDRESS)));

        // when
        AaveV4SubstrateType substrateType = AaveV4SubstrateLib.decodeSubstrateType(invalidSubstrate);

        // then
        assertEq(uint8(substrateType), uint8(AaveV4SubstrateType.Undefined));
    }

    function testShouldReturnUndefinedForMaxFlag() public pure {
        // given - construct bytes32 with flag = 255 (max uint8)
        bytes32 invalidSubstrate = bytes32(uint256(255) << 248 | uint256(uint160(SAMPLE_ADDRESS)));

        // when
        AaveV4SubstrateType substrateType = AaveV4SubstrateLib.decodeSubstrateType(invalidSubstrate);

        // then
        assertEq(uint8(substrateType), uint8(AaveV4SubstrateType.Undefined));
    }
}
