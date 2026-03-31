// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {ConfigureInstantWithdrawalFuse} from "../../../../contracts/fuses/maintenance/ConfigureInstantWithdrawalFuse.sol";

import {ConfigureInstantWithdrawalFuse, ExitNotSupported} from "contracts/fuses/maintenance/ConfigureInstantWithdrawalFuse.sol";
contract ConfigureInstantWithdrawalFuseTest is OlympixUnitTest("ConfigureInstantWithdrawalFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_exit_RevertsWithExitNotSupported() public {
            ConfigureInstantWithdrawalFuse fuse = new ConfigureInstantWithdrawalFuse(1);
    
            vm.expectRevert(ExitNotSupported.selector);
            fuse.exit("");
        }
}