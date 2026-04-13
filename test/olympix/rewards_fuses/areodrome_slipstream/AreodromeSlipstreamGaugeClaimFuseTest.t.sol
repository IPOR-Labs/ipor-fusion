// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/rewards_fuses/areodrome_slipstream/AreodromeSlipstreamGaugeClaimFuse.sol

import {AreodromeSlipstreamGaugeClaimFuse} from "contracts/rewards_fuses/areodrome_slipstream/AreodromeSlipstreamGaugeClaimFuse.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
contract AreodromeSlipstreamGaugeClaimFuseTest is OlympixUnitTest("AreodromeSlipstreamGaugeClaimFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_claim_revertsOnEmptyArray_opix_target_branch_45_true() public {
            // deploy fuse with arbitrary marketId
            AreodromeSlipstreamGaugeClaimFuse fuse = new AreodromeSlipstreamGaugeClaimFuse(1);
    
            // given: empty gauges array
            address[] memory gauges = new address[](0);
    
            // then: expect custom error on next call
            vm.expectRevert(AreodromeSlipstreamGaugeClaimFuse.AerodromeSlipstreamGaugeClaimFuseEmptyArray.selector);
    
            // when: calling claim with empty array
            fuse.claim(gauges);
        }

    function test_claim_nonEmptyArray_opix_target_branch_47_false() public {
            // deploy fuse with arbitrary marketId
            AreodromeSlipstreamGaugeClaimFuse fuse = new AreodromeSlipstreamGaugeClaimFuse(1);
    
            // given: non-empty gauges array to make `len == 0` condition false
            address[] memory gauges = new address[](1);
            gauges[0] = address(0x1);
    
            // we don't set rewardsClaimManager, so the next revert will be due to zero address
            vm.expectRevert(AreodromeSlipstreamGaugeClaimFuse.AerodromeSlipstreamGaugeClaimFuseRewardsClaimManagerZeroAddress.selector);
    
            // when: calling claim with non-empty array, we enter the else branch of len==0 check
            fuse.claim(gauges);
        }
}