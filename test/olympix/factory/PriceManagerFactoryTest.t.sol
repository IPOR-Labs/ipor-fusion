// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../test/OlympixUnitTest.sol";
import {PriceManagerFactory} from "../../../contracts/factory/PriceManagerFactory.sol";

import {PriceOracleMiddlewareManager} from "contracts/managers/price/PriceOracleMiddlewareManager.sol";
contract PriceManagerFactoryTest is OlympixUnitTest("PriceManagerFactory") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_create_EmitsEventAndDeploysManager() public {
            PriceManagerFactory factory = new PriceManagerFactory();
    
            uint256 index = 7;
            address accessManager = address(0xABCD);
            address priceOracleMiddleware = address(0x1234);
    
            vm.expectEmit(false, false, false, false);
            emit PriceManagerFactory.PriceManagerCreated(index, address(0), priceOracleMiddleware);
    
            address managerAddr = factory.create(index, accessManager, priceOracleMiddleware);
    
            assertTrue(managerAddr != address(0), "manager should be deployed");
            assertEq(
                PriceOracleMiddlewareManager(managerAddr).authority(),
                accessManager,
                "manager should be initialized with correct authority"
            );
            assertEq(
                PriceOracleMiddlewareManager(managerAddr).getPriceOracleMiddleware(),
                priceOracleMiddleware,
                "manager should be initialized with correct price oracle middleware"
            );
        }

    function test_clone_RevertWhenBaseAddressZero() public {
            PriceManagerFactory factory = new PriceManagerFactory();
    
            address baseAddress = address(0);
            uint256 index = 1;
            address accessManager = address(0xABCD);
            address priceOracleMiddleware = address(0x1234);
    
            vm.expectRevert(PriceManagerFactory.InvalidBaseAddress.selector);
            factory.clone(baseAddress, index, accessManager, priceOracleMiddleware);
        }
}