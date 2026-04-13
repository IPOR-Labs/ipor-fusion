// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/readers/TacStakingDelegatorAddressReader.sol

import {TacStakingDelegatorAddressReader} from "contracts/readers/TacStakingDelegatorAddressReader.sol";
import {TacStakingStorageLib} from "contracts/fuses/tac/lib/TacStakingStorageLib.sol";
import {UniversalReader} from "contracts/universal_reader/UniversalReader.sol";
import {TacValidatorAddressConverter} from "contracts/fuses/tac/lib/TacValidatorAddressConverter.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract TacStakingDelegatorAddressReaderTest is OlympixUnitTest("TacStakingDelegatorAddressReader") {

    // Helper function that can be called via delegatecall to set storage
    function setTacStakingDelegator(address delegator_) external {
        TacStakingStorageLib.setTacStakingDelegator(delegator_);
    }

    function test_readTacStakingDelegatorAddress_branchTrue() public {
            // deploy the reader
            TacStakingDelegatorAddressReader reader = new TacStakingDelegatorAddressReader();

            // Use PlasmaVaultMock for delegatecall so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(reader), address(0));

            // set delegator in vault's storage via delegatecall
            address expectedDelegator = address(0x1234);
            vault.execute(
                address(this),
                abi.encodeWithSelector(this.setTacStakingDelegator.selector, expectedDelegator)
            );

            // Read via vault's delegatecall
            (bool ok, bytes memory ret) = address(vault).staticcall(
                abi.encodeWithSignature("readTacStakingDelegatorAddress()")
            );
            assertTrue(ok, "staticcall should succeed");
            address delegator = abi.decode(ret, (address));

            assertEq(delegator, expectedDelegator, "readTacStakingDelegatorAddress should return stored delegator");
        }

    function test_getTacStakingDelegatorAddress_viaUniversalReader() public {
            TacStakingDelegatorAddressReader reader = new TacStakingDelegatorAddressReader();

            // Simple test: just verify readTacStakingDelegatorAddress returns address(0) when nothing is set
            address delegator = reader.readTacStakingDelegatorAddress();
            assertEq(delegator, address(0), "should return zero when no delegator set");
        }

    function test_convertValidatorAddressToBytes32_roundTrip() public {
        // given
        TacStakingDelegatorAddressReader reader = new TacStakingDelegatorAddressReader();
        string memory validator = "cosmosvaloper1qqp9gqy9l9x4l7n9w8d2u0x9z0r5u6w5fjjjss";

        // when
        (bytes32 firstSlot, bytes32 secondSlot) = reader.convertValidatorAddressToBytes32(validator);
        string memory decoded = reader.convertBytes32ToValidatorAddress(firstSlot, secondSlot);

        // then
        assertEq(decoded, validator, "Round-trip conversion should preserve validator address");
    }

    function test_convertBytes32ToValidatorAddress_roundTrip() public {
            // given
            string memory validator = "cosmosvaloper1qqp9g3h0st8n6j6z0m2m6u0u5p4a8c9d0e7f6";

            // when: encode then decode
            (bytes32 first, bytes32 second) = TacValidatorAddressConverter.validatorAddressToBytes32(validator);
            TacStakingDelegatorAddressReader reader = new TacStakingDelegatorAddressReader();
            string memory decoded = reader.convertBytes32ToValidatorAddress(first, second);

            // then
            assertEq(decoded, validator, "Validator address should round-trip through bytes32 conversion");
        }
}
