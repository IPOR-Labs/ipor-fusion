// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/rewards_fuses/velodrome_superchain/VelodromeSuperchainSlipstreamGaugeClaimFuse.sol

import {VelodromeSuperchainSlipstreamGaugeClaimFuse} from "contracts/rewards_fuses/velodrome_superchain/VelodromeSuperchainSlipstreamGaugeClaimFuse.sol";
import {ILeafCLGauge} from "contracts/fuses/velodrome_superchain_slipstream/ext/ILeafCLGauge.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
contract VelodromeSuperchainSlipstreamGaugeClaimFuseTest is OlympixUnitTest("VelodromeSuperchainSlipstreamGaugeClaimFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_claim_RevertOnEmptyArray() public {
            VelodromeSuperchainSlipstreamGaugeClaimFuse fuse = new VelodromeSuperchainSlipstreamGaugeClaimFuse(1);
    
            // No need to configure rewardsClaimManager or substrates because we revert
            // on the empty array check before those are read.
            vm.expectRevert(VelodromeSuperchainSlipstreamGaugeClaimFuse.VelodromeSuperchainSlipstreamGaugeClaimFuseEmptyArray.selector);
            address[] memory gauges = new address[](0);
            fuse.claim(gauges);
        }
}