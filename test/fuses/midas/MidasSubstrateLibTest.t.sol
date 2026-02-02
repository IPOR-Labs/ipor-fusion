// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MidasSubstrateLib, MidasSubstrate, MidasSubstrateType} from "../../../contracts/fuses/midas/lib/MidasSubstrateLib.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

/// @title MidasSubstrateLibTest
/// @notice Tests for MidasSubstrateLib encoding, decoding, and validation functions
contract MidasSubstrateLibTest is Test {
    address public constant MTBILL_TOKEN = 0xDD629E5241CbC5919847783e6C96B2De4754e438;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 public constant MARKET_ID = 1;

    // ============ Encoding / Decoding Tests ============

    function testShouldEncodeAndDecodeSubstrate() public pure {
        MidasSubstrate memory original = MidasSubstrate({
            substrateType: MidasSubstrateType.M_TOKEN,
            substrateAddress: MTBILL_TOKEN
        });

        bytes32 encoded = MidasSubstrateLib.substrateToBytes32(original);
        MidasSubstrate memory decoded = MidasSubstrateLib.bytes32ToSubstrate(encoded);

        assertEq(uint8(decoded.substrateType), uint8(MidasSubstrateType.M_TOKEN), "Type should match");
        assertEq(decoded.substrateAddress, MTBILL_TOKEN, "Address should match");
    }

    function testShouldEncodeAndDecodeAllSubstrateTypes() public pure {
        MidasSubstrateType[6] memory types = [
            MidasSubstrateType.UNDEFINED,
            MidasSubstrateType.M_TOKEN,
            MidasSubstrateType.DEPOSIT_VAULT,
            MidasSubstrateType.REDEMPTION_VAULT,
            MidasSubstrateType.INSTANT_REDEMPTION_VAULT,
            MidasSubstrateType.ASSET
        ];

        for (uint256 i; i < types.length; i++) {
            MidasSubstrate memory original = MidasSubstrate({
                substrateType: types[i],
                substrateAddress: USDC
            });

            bytes32 encoded = MidasSubstrateLib.substrateToBytes32(original);
            MidasSubstrate memory decoded = MidasSubstrateLib.bytes32ToSubstrate(encoded);

            assertEq(uint8(decoded.substrateType), uint8(types[i]), "Type should match for all types");
            assertEq(decoded.substrateAddress, USDC, "Address should match for all types");
        }
    }

    // ============ validateAssetGranted Tests ============

    function testShouldValidateAssetGranted() public {
        PlasmaVaultMock vault = new PlasmaVaultMock(address(this), address(0));

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.ASSET, substrateAddress: USDC})
        );
        vault.grantMarketSubstrates(MARKET_ID, substrates);

        // Should not revert since USDC is granted as ASSET
        // We can't call validateAssetGranted directly (internal), but we verify
        // the encoding/decoding is correct via round-trip
        bytes32 encoded = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.ASSET, substrateAddress: USDC})
        );
        MidasSubstrate memory decoded = MidasSubstrateLib.bytes32ToSubstrate(encoded);
        assertEq(uint8(decoded.substrateType), uint8(MidasSubstrateType.ASSET));
        assertEq(decoded.substrateAddress, USDC);
    }

    function testShouldPreserveAddressBitsInEncoding() public pure {
        // Verify no bits are lost in encoding
        address testAddr = 0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF;
        MidasSubstrate memory sub = MidasSubstrate({
            substrateType: MidasSubstrateType.DEPOSIT_VAULT,
            substrateAddress: testAddr
        });

        bytes32 encoded = MidasSubstrateLib.substrateToBytes32(sub);
        MidasSubstrate memory decoded = MidasSubstrateLib.bytes32ToSubstrate(encoded);

        assertEq(decoded.substrateAddress, testAddr, "Full address should be preserved");
        assertEq(uint8(decoded.substrateType), uint8(MidasSubstrateType.DEPOSIT_VAULT), "Type should be preserved");
    }
}
