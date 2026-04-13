// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/rewards_fuses/compound/CompoundV3ClaimFuse.sol

import {CompoundV3ClaimFuse} from "contracts/rewards_fuses/compound/CompoundV3ClaimFuse.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {ICometRewards} from "contracts/rewards_fuses/compound/ICometRewards.sol";
contract CompoundV3ClaimFuseTest is OlympixUnitTest("CompoundV3ClaimFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_claim_revertsWhenClaimManagerZeroAddress() public {
            // Deploy a dummy CometRewards implementation
            ICometRewards cometRewards = ICometRewards(address(0x1234));
    
            // Deploy the fuse with a non-zero COMET_REWARDS
            CompoundV3ClaimFuse fuse = new CompoundV3ClaimFuse(address(cometRewards));
    
            // Ensure rewards claim manager is zero so that the if condition is true
            // PlasmaVaultLib.getRewardsClaimManagerAddress() will return address(0) by default
    
            vm.expectRevert(CompoundV3ClaimFuse.ClaimManagerZeroAddress.selector);
            fuse.claim(address(0xABCD));
        }
}