// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/rewards_fuses/merkl/MerklClaimFuse.sol

import {MerklClaimFuse} from "contracts/rewards_fuses/merkl/MerklClaimFuse.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";
contract MerklClaimFuseTest is OlympixUnitTest("MerklClaimFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_claim_RevertWhenRewardsClaimManagerZeroAddress() public {
            // Deploy MerklClaimFuse with a non-zero distributor to satisfy constructor
            MerklClaimFuse fuse = new MerklClaimFuse(address(0x1234));
    
            // Prepare minimal, but structurally valid, Merkl claim parameters
            address[] memory tokens = new address[](1);
            tokens[0] = address(0x1);
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 0;
            bytes32[][] memory proofs = new bytes32[][](1);
            proofs[0] = new bytes32[](0);
            address[] memory doNotTransfer = new address[](0);
    
            // Because this test is executing in its own context, PlasmaVaultLib.getRewardsClaimManagerAddress()
            // will read the zero address from storage, making the branch condition true
            vm.expectRevert(abi.encodeWithSelector(MerklClaimFuse.MerklClaimFuseRewardsClaimManagerZeroAddress.selector, address(fuse)));
            fuse.claim(tokens, amounts, proofs, doNotTransfer);
        }
}