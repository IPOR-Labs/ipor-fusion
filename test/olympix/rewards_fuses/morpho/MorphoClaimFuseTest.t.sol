// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/rewards_fuses/morpho/MorphoClaimFuse.sol

import {MorphoClaimFuse} from "contracts/rewards_fuses/morpho/MorphoClaimFuse.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
contract MorphoClaimFuseTest is OlympixUnitTest("MorphoClaimFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_claim_RevertsWhenRewardsClaimManagerZero_branch78True() public {
            // arrange
            uint256 marketId = 1;
            MorphoClaimFuse fuse = new MorphoClaimFuse(marketId);
    
            // we want to hit the first if-branch where rewardsClaimManager == address(0)
            // The production code reads RewardsClaimManager address from PlasmaVaultLib.
            // Olympix tests provide environment where this value is zero by default for this unit test target,
            // so we only need to trigger the call and assert on the revert.
    
            address universalRewardsDistributor = address(0x1234); // non-zero to avoid second revert being hit first
            address rewardsToken = address(0xDEAD);
            uint256 claimable = 0;
            bytes32[] memory proof = new bytes32[](0);
    
            // act & assert: expect revert due to zero RewardsClaimManager address
            vm.expectRevert(
                abi.encodeWithSelector(MorphoClaimFuse.MorphoClaimFuseRewardsClaimManagerZeroAddress.selector, address(fuse))
            );
    
            fuse.claim(universalRewardsDistributor, rewardsToken, claimable, proof);
        }
}