// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../test/OlympixUnitTest.sol";
import {AccessManagerFactory} from "../../../contracts/factory/AccessManagerFactory.sol";

import {IporFusionAccessManager} from "contracts/managers/access/IporFusionAccessManager.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
contract AccessManagerFactoryTest is OlympixUnitTest("AccessManagerFactory") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_create_AlwaysExecutesTrueBranch() public {
            AccessManagerFactory factory = new AccessManagerFactory();
    
            uint256 index = 1;
            address initialAuthority = address(0x1234);
            uint256 redemptionDelayInSeconds = 100;
    
            address accessManager = factory.create(index, initialAuthority, redemptionDelayInSeconds);
    
            assertTrue(accessManager != address(0));
        }

    function test_clone_RevertWhenBaseAddressZero() public {
            AccessManagerFactory factory = new AccessManagerFactory();
    
            address baseAddress = address(0);
            uint256 index = 1;
            address initialAuthority = address(0x1234);
            uint256 redemptionDelayInSeconds = 100;
    
            vm.expectRevert(AccessManagerFactory.InvalidBaseAddress.selector);
            factory.clone(baseAddress, index, initialAuthority, redemptionDelayInSeconds);
        }
}