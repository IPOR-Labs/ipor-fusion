// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {TacStakingEmergencyFuse} from "../../../../contracts/fuses/tac/TacStakingEmergencyFuse.sol";

import {TacStakingStorageLib} from "contracts/fuses/tac/lib/TacStakingStorageLib.sol";
import {TacStakingDelegator} from "contracts/fuses/tac/TacStakingDelegator.sol";
import {MockStaking} from "test/fuses/tac/MockStaking.sol";
contract TacStakingEmergencyFuseTest is OlympixUnitTest("TacStakingEmergencyFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_exit_RevertsWhenDelegatorAddressZero() public {
            // Ensure no delegator is set in storage so getTacStakingDelegator() returns address(0)
            // (default for uninitialized storage)
    
            TacStakingEmergencyFuse fuse = new TacStakingEmergencyFuse(1);
    
            vm.expectRevert(TacStakingEmergencyFuse.TacStakingEmergencyFuseInvalidDelegatorAddress.selector);
            fuse.exit();
        }
}