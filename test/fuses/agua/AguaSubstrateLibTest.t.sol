// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AguaSubstrateLib, AguaSubstrate, AguaSubstrateType} from "../../../contracts/fuses/agua/lib/AguaSubstrateLib.sol";

/// @title AguaSubstrateLibTest
/// @notice Pure unit tests for encoding/decoding of Agua typed substrates. No fork required.
contract AguaSubstrateLibTest is Test {
    address public constant AGUA_VAULT = 0xa98b4A70E17e55045CDE4972B95Bc2E8CEC22a0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function testShouldRoundTripVaultSubstrate() public pure {
        AguaSubstrate memory substrate = AguaSubstrate({
            substrateType: AguaSubstrateType.VAULT,
            substrateAddress: AGUA_VAULT
        });

        bytes32 encoded = AguaSubstrateLib.substrateToBytes32(substrate);
        AguaSubstrate memory decoded = AguaSubstrateLib.bytes32ToSubstrate(encoded);

        assertEq(uint8(decoded.substrateType), uint8(AguaSubstrateType.VAULT), "type should round-trip to VAULT");
        assertEq(decoded.substrateAddress, AGUA_VAULT, "address should round-trip");
    }

    function testShouldRoundTripAssetSubstrate() public pure {
        AguaSubstrate memory substrate = AguaSubstrate({
            substrateType: AguaSubstrateType.ASSET,
            substrateAddress: USDC
        });

        bytes32 encoded = AguaSubstrateLib.substrateToBytes32(substrate);
        AguaSubstrate memory decoded = AguaSubstrateLib.bytes32ToSubstrate(encoded);

        assertEq(uint8(decoded.substrateType), uint8(AguaSubstrateType.ASSET), "type should round-trip to ASSET");
        assertEq(decoded.substrateAddress, USDC, "address should round-trip");
    }

    function testShouldEncodeTypeDiscriminatorInHighBits() public pure {
        bytes32 vaultEncoded = AguaSubstrateLib.substrateToBytes32(
            AguaSubstrate({substrateType: AguaSubstrateType.VAULT, substrateAddress: AGUA_VAULT})
        );
        bytes32 assetEncoded = AguaSubstrateLib.substrateToBytes32(
            AguaSubstrate({substrateType: AguaSubstrateType.ASSET, substrateAddress: AGUA_VAULT})
        );

        // Same address, different type → different encoding (discriminator placed above the 160-bit address)
        assertTrue(vaultEncoded != assetEncoded, "encodings must differ by type");

        // High bits hold the type discriminator
        assertEq(uint256(vaultEncoded) >> 160, uint256(AguaSubstrateType.VAULT), "VAULT discriminator");
        assertEq(uint256(assetEncoded) >> 160, uint256(AguaSubstrateType.ASSET), "ASSET discriminator");

        // Low 160 bits hold the address for both
        assertEq(address(uint160(uint256(vaultEncoded))), AGUA_VAULT, "low bits hold the address");
        assertEq(address(uint160(uint256(assetEncoded))), AGUA_VAULT, "low bits hold the address");
    }

    function testShouldDecodeUndefinedTypeForZeroDiscriminator() public pure {
        // bytes32 with only an address and zero type → UNDEFINED
        bytes32 raw = bytes32(uint256(uint160(USDC)));
        AguaSubstrate memory decoded = AguaSubstrateLib.bytes32ToSubstrate(raw);

        assertEq(uint8(decoded.substrateType), uint8(AguaSubstrateType.UNDEFINED), "zero discriminator is UNDEFINED");
        assertEq(decoded.substrateAddress, USDC, "address still decodes");
    }
}
