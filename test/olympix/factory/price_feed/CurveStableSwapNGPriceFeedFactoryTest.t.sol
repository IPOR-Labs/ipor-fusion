// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {
    CurveStableSwapNGPriceFeedFactory
} from "contracts/factory/price_feed/CurveStableSwapNGPriceFeedFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @dev Target contract: contracts/factory/price_feed/CurveStableSwapNGPriceFeedFactory.sol
contract CurveStableSwapNGPriceFeedFactoryTest is OlympixUnitTest("CurveStableSwapNGPriceFeedFactory") {
    CurveStableSwapNGPriceFeedFactory internal factory;
    address internal admin;

    function setUp() public override {
        admin = makeAddr("admin");

        CurveStableSwapNGPriceFeedFactory implementation = new CurveStableSwapNGPriceFeedFactory();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeWithSelector(CurveStableSwapNGPriceFeedFactory.initialize.selector, admin)
        );
        factory = CurveStableSwapNGPriceFeedFactory(address(proxy));
    }

    function test_example_initializeSetsOwner() public view {
        assertEq(factory.owner(), admin, "initialize should set the factory admin as owner");
    }

    function test_example_reinitializeReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factory.initialize(makeAddr("otherAdmin"));
    }

    function test_example_implementationInitializeDisabled() public {
        CurveStableSwapNGPriceFeedFactory implementation = new CurveStableSwapNGPriceFeedFactory();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(admin);
    }
}
