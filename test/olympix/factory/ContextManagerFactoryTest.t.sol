// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../test/OlympixUnitTest.sol";
import {ContextManagerFactory} from "../../../contracts/factory/ContextManagerFactory.sol";

import {ContextManagerFactory} from "contracts/factory/ContextManagerFactory.sol";
import {ContextManager} from "contracts/managers/context/ContextManager.sol";
contract ContextManagerFactoryTest is OlympixUnitTest("ContextManagerFactory") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_create_ShouldDeployNewContextManagerAndEmitEvent() public {
            ContextManagerFactory factory = new ContextManagerFactory();
    
            uint256 index = 1;
            address accessManager = address(this);
            address[] memory approvedTargets = new address[](2);
            approvedTargets[0] = address(0x1234);
            approvedTargets[1] = address(0x5678);
    
            vm.expectEmit(false, false, false, false);
            emit ContextManagerFactory.ContextManagerCreated(index, address(0), approvedTargets);
    
            address contextManagerAddr = factory.create(index, accessManager, approvedTargets);
    
            assertTrue(contextManagerAddr != address(0), "ContextManager address should not be zero");
    
            ContextManager cm = ContextManager(payable(contextManagerAddr));
            assertEq(cm.authority(), accessManager, "Authority should match accessManager passed");
    
            address[] memory storedApproved = cm.getApprovedTargets();
            assertEq(storedApproved.length, approvedTargets.length, "Approved targets length mismatch");
            assertEq(storedApproved[0], approvedTargets[0], "First approved target mismatch");
            assertEq(storedApproved[1], approvedTargets[1], "Second approved target mismatch");
        }

    function test_clone_RevertWhenBaseAddressIsZero() public {
            ContextManagerFactory factory = new ContextManagerFactory();
    
            address baseAddress = address(0);
            uint256 index = 1;
            address accessManager = address(this);
            address[] memory approvedTargets = new address[](1);
            approvedTargets[0] = address(0x1234);
    
            vm.expectRevert(ContextManagerFactory.InvalidBaseAddress.selector);
            factory.clone(baseAddress, index, accessManager, approvedTargets);
        }
}