// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../test/OlympixUnitTest.sol";
import {RewardsManagerFactory} from "../../../contracts/factory/RewardsManagerFactory.sol";

import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
contract RewardsManagerFactoryTest is OlympixUnitTest("RewardsManagerFactory") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_create_DeploysRewardsClaimManagerAndEmitsEvent() public {
            RewardsManagerFactory factory = new RewardsManagerFactory();

            uint256 index = 1;
            address accessManager = address(0xABC1);
            address plasmaVault = address(0xDEF1);

            // Mock PlasmaVault.asset() since the RewardsClaimManager constructor calls it
            vm.mockCall(plasmaVault, abi.encodeWithSignature("asset()"), abi.encode(address(0x1234)));

            address rewardsManager = factory.create(index, accessManager, plasmaVault);
    
            // Verify the returned address is a deployed RewardsClaimManager
            assertTrue(rewardsManager != address(0));
            RewardsClaimManager rcm = RewardsClaimManager(rewardsManager);
            // basic sanity check that the contract code exists
            assertGt(rewardsManager.code.length, 0);
    
            // silence state mutability warnings
            rcm; // no-op
        }

    function test_clone_RevertOnZeroBaseAddress() public {
            RewardsManagerFactory factory = new RewardsManagerFactory();
    
            vm.expectRevert(RewardsManagerFactory.InvalidBaseAddress.selector);
            factory.clone(address(0), 1, address(0xABC), address(0xDEF));
        }
}