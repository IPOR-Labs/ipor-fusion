// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {MidasSubstrateLibCaller} from "test/test_helpers/lib_callers/MidasSubstrateLibCaller.sol";
import {MidasSubstrateLib, MidasSubstrate, MidasSubstrateType} from "contracts/fuses/midas/lib/MidasSubstrateLib.sol";

/// @dev Target contract: contracts/fuses/midas/lib/MidasSubstrateLib.sol (via MidasSubstrateLibCaller harness)
contract MidasSubstrateLibTest is OlympixUnitTest("MidasSubstrateLibCaller") {
    MidasSubstrateLibCaller internal caller;

    function setUp() public override {
        caller = new MidasSubstrateLibCaller();
    }

    function test_example_substrateRoundTrip() public view {
        MidasSubstrate memory substrate = MidasSubstrate({
            substrateType: MidasSubstrateType.M_TOKEN,
            substrateAddress: address(0xBEEF)
        });

        bytes32 encoded = caller.substrateToBytes32(substrate);
        MidasSubstrate memory decoded = caller.bytes32ToSubstrate(encoded);

        assertEq(uint8(decoded.substrateType), uint8(MidasSubstrateType.M_TOKEN), "type should survive round trip");
        assertEq(decoded.substrateAddress, address(0xBEEF), "address should survive round trip");
    }

    function test_example_encodingLayout() public view {
        MidasSubstrate memory substrate = MidasSubstrate({
            substrateType: MidasSubstrateType.DEPOSIT_VAULT,
            substrateAddress: address(0xCAFE)
        });

        bytes32 encoded = caller.substrateToBytes32(substrate);

        // layout: [type (96 bits) | address (160 bits)]
        assertEq(
            uint256(encoded),
            uint256(uint160(address(0xCAFE))) | (uint256(MidasSubstrateType.DEPOSIT_VAULT) << 160),
            "encoding must place type above bit 160 and address below"
        );
    }

    function test_example_validateMTokenGranted_revertsWhenNotGranted() public {
        address mToken = address(0xABCD);

        vm.expectRevert(
            abi.encodeWithSelector(
                MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector,
                uint8(MidasSubstrateType.M_TOKEN),
                mToken
            )
        );
        caller.validateMTokenGranted(1, mToken);
    }

    function test_validateDepositVaultGranted_RevertsWhenNotGranted() public {
            uint256 marketId = 1;
            address depositVault = address(0xDEAD);
    
            vm.expectRevert(
                abi.encodeWithSelector(
                    MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector,
                    uint8(MidasSubstrateType.DEPOSIT_VAULT),
                    depositVault
                )
            );
    
            caller.validateDepositVaultGranted(marketId, depositVault);
        }
}