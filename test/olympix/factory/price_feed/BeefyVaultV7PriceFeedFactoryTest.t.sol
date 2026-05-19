// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/factory/price_feed/BeefyVaultV7PriceFeedFactory.sol

import {BeefyVaultV7PriceFeedFactory} from "contracts/factory/price_feed/BeefyVaultV7PriceFeedFactory.sol";

import {BeefyVaultV7PriceFeed} from "contracts/price_oracle/price_feed/BeefyVaultV7PriceFeed.sol";
import {MockPriceOracle} from "test/fuses/aave_v4/MockPriceOracle.sol";
import {MockToken} from "test/managers/MockToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
contract BeefyVaultV7PriceFeedFactoryTest is OlympixUnitTest("BeefyVaultV7PriceFeedFactory") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_initialize_RevertOnZeroAdmin() public {
            BeefyVaultV7PriceFeedFactory impl = new BeefyVaultV7PriceFeedFactory();
    
            // Deploy UUPS proxy pointing to implementation
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                "" // no initialization call in constructor
            );
    
            // Interact with factory via proxy
            BeefyVaultV7PriceFeedFactory factory = BeefyVaultV7PriceFeedFactory(address(proxy));
    
            // Expect revert from factory's InvalidAddress error when admin is zero
            vm.expectRevert(BeefyVaultV7PriceFeedFactory.InvalidAddress.selector);
            factory.initialize(address(0));
        }
}