// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../test/OlympixUnitTest.sol";
import {WithdrawManagerFactory} from "../../../contracts/factory/WithdrawManagerFactory.sol";

import {WithdrawManager} from "contracts/managers/withdraw/WithdrawManager.sol";
contract WithdrawManagerFactoryTest is OlympixUnitTest("WithdrawManagerFactory") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_create_DeploysWithdrawManagerAndEmitsEvent() public {
            WithdrawManagerFactory factory = new WithdrawManagerFactory();
            uint256 index = 1;
            address accessManager = address(0xABCD);
    
            vm.expectEmit(false, false, false, false);
            emit WithdrawManagerFactory.WithdrawManagerCreated(index, address(0), accessManager);
    
            address withdrawManagerAddr = factory.create(index, accessManager);
    
            assertTrue(withdrawManagerAddr != address(0), "withdrawManager should be deployed");
        }

    function test_clone_RevertsOnZeroBaseAddress() public {
            WithdrawManagerFactory factory = new WithdrawManagerFactory();
            address baseAddress = address(0);
            uint256 index = 1;
            address accessManager = address(0x1234);
    
            vm.expectRevert(WithdrawManagerFactory.InvalidBaseAddress.selector);
            factory.clone(baseAddress, index, accessManager);
        }
}