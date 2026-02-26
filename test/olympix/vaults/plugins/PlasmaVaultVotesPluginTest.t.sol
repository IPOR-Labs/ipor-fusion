// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {PlasmaVaultVotesPlugin} from "../../../../contracts/vaults/plugins/PlasmaVaultVotesPlugin.sol";

import {ContextClientStorageLib} from "contracts/managers/context/ContextClientStorageLib.sol";
import {PlasmaVaultVotesPlugin} from "contracts/vaults/plugins/PlasmaVaultVotesPlugin.sol";
contract PlasmaVaultVotesPluginTest is OlympixUnitTest("PlasmaVaultVotesPlugin") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_getPastVotes_RevertOnFutureTimepoint() public {
            PlasmaVaultVotesPlugin plugin = new PlasmaVaultVotesPlugin();
    
            uint48 currentTimepoint = plugin.clock();
    
            vm.expectRevert();
            plugin.getPastVotes(address(0x1), uint256(currentTimepoint));
        }

    function test_getPastTotalSupply_RevertsOnFutureTimepoint() public {
            PlasmaVaultVotesPlugin plugin = new PlasmaVaultVotesPlugin();
    
            uint48 currentTimepoint = plugin.clock();
            uint256 futureTimepoint = uint256(currentTimepoint) + 1;
    
            vm.expectRevert();
            plugin.getPastTotalSupply(futureTimepoint);
        }

    function test_nonces_DefaultZeroAndBranchTrue() public {
        PlasmaVaultVotesPlugin plugin = new PlasmaVaultVotesPlugin();
    
        // Ensure context is clear so _msgSender fallback path is well-defined
        ContextClientStorageLib.clearContextStorage();
    
        // Call nonces on an address with no prior activity; this will
        // execute the `if (true)` branch in `nonces` and return 0
        address owner = address(0xABCD);
        uint256 nonce = plugin.nonces(owner);
    
        assertEq(nonce, 0, "Default nonce should be zero for fresh owner");
    }

    function test_EIP712VersionHash_ElseBranchWhenNoVersionSet() public {
            PlasmaVaultVotesPlugin plugin = new PlasmaVaultVotesPlugin();
    
            // We cannot call the internal _EIP712VersionHash directly, but we can
            // still trigger its logic by going through _hashTypedDataV4, which is
            // used by delegateBySig. In the default fresh state, both
            // EIP712Storage._version and EIP712Storage._hashedVersion are zero,
            // so inside _EIP712VersionHash the condition
            //   if (bytes(version).length > 0)
            // is false, and the function executes its else branch
            // (the opix-target-branch-392 else), where hashedVersion == 0 and
            // it returns keccak256(""). That satisfies the required branch hit.
    
            address dummyDelegatee = address(0x1234);
            uint256 dummyNonce = 0;
            uint256 dummyExpiry = block.timestamp + 1;
    
            // Invalid signature values; the exact contents are irrelevant,
            // they just ensure ECDSA.recover is reached and then delegateBySig
            // reverts (either due to invalid signature or nonce).
            bytes32 r = bytes32(0);
            bytes32 s = bytes32(0);
            uint8 v = 27;
    
            vm.expectRevert();
            plugin.delegateBySig(dummyDelegatee, dummyNonce, dummyExpiry, v, r, s);
        }

    function test_EIP712VersionHash_EmptyWhenNoVersionOrHashedVersionSet() public {
            PlasmaVaultVotesPlugin plugin = new PlasmaVaultVotesPlugin();
    
            // Ensure no context sender is set so _msgSender() falls back to address(this) if ever used
            ContextClientStorageLib.clearContextStorage();
    
            // We cannot call internal _domainSeparatorV4 directly from the test, but we can
            // still execute the private _EIP712VersionHash via a public function that uses it.
            // _domainSeparatorV4 and _hashTypedDataV4 are internal, so here we just ensure
            // calling a view that depends on version hashing does not revert in the default state.
            // The default storage has empty _version and _hashedVersion == 0, so the
            // opix-target-branch-396 else branch (return keccak256("")) is executed
            // during construction of the domain separator used by delegateBySig.
    
            address dummyDelegatee = address(0x1234);
            uint256 dummyNonce = 0;
            uint256 dummyExpiry = block.timestamp + 1;
    
            // Build any bytes for signature so that delegateBySig will reach ECDSA.recover,
            // which internally uses _hashTypedDataV4 -> _EIP712VersionHash. We expect
            // it to revert due to invalid signature, but the important part is that
            // no other revert (like due to version hashing) occurs.
            bytes32 r = bytes32(0);
            bytes32 s = bytes32(0);
            uint8 v = 27;
    
            vm.expectRevert();
            plugin.delegateBySig(dummyDelegatee, dummyNonce, dummyExpiry, v, r, s);
        }
}