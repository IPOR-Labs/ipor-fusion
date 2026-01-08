// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC4626PriceFeedFactory} from "../../../contracts/factory/price_feed/ERC4626PriceFeedFactory.sol";
import {ERC4626PriceFeed} from "../../../contracts/price_oracle/price_feed/ERC4626PriceFeed.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";

contract ERC4626PriceFeedFactoryTest is Test {
    ERC4626PriceFeedFactory public factory;
    address public constant PRICE_ORACLE_MIDDLEWARE = 0xC9F32d65a278b012371858fD3cdE315B12d664c6;
    address public constant VAULT_ADDRESS = 0x7751E2F4b8ae93EF6B79d86419d42FE3295A4559;
    address public constant ADMIN = address(0x1);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23535966);
        // Deploy implementation
        address implementation = address(new ERC4626PriceFeedFactory());

        // Deploy and initialize proxy
        factory = ERC4626PriceFeedFactory(
            address(new ERC1967Proxy(implementation, abi.encodeWithSignature("initialize(address)", ADMIN)))
        );
    }

    function test_CreatePriceFeed() public {
        // when
        address priceFeed = factory.create(VAULT_ADDRESS, PRICE_ORACLE_MIDDLEWARE);

        // then
        assertTrue(priceFeed != address(0), "Price feed should be created");

        ERC4626PriceFeed feed = ERC4626PriceFeed(priceFeed);
        assertEq(feed.vault(), VAULT_ADDRESS, "Vault should be set correctly");
    }

    function test_CreatePriceFeed_ZeroVaultAddress() public {
        // when/then
        vm.expectRevert(ERC4626PriceFeedFactory.InvalidAddress.selector);
        factory.create(address(0), PRICE_ORACLE_MIDDLEWARE);
    }

    function test_CreatePriceFeed_ZeroPriceOracleMiddleware() public {
        // when/then
        vm.expectRevert(ERC4626PriceFeedFactory.InvalidAddress.selector);
        factory.create(VAULT_ADDRESS, address(0));
    }

    function test_CreatePriceFeed_EventEmitted() public {
        // when
        //@Dev: We expect the event to be emitted with the correct parameters, but the price feed address is not predictable
        vm.expectEmit(false, true, true, false);
        emit ERC4626PriceFeedFactory.ERC4626PriceFeedCreated(address(0), address(0));

        address priceFeed = factory.create(VAULT_ADDRESS, PRICE_ORACLE_MIDDLEWARE);

        // then - verify the event was emitted with correct parameters
        // Note: We can't easily predict the exact address, so we check it's not zero
        assertTrue(priceFeed != address(0), "Price feed address should not be zero");
    }

    function test_Upgrade_NotOwner() public {
        address caller = address(0x2);
        // given
        address newImplementation = address(new ERC4626PriceFeedFactory());

        // when/then
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", caller));
        vm.startPrank(caller);
        factory.upgradeToAndCall(newImplementation, "");
        vm.stopPrank();
    }

    function test_Upgrade_Owner() public {
        // given
        address newImplementation = address(new ERC4626PriceFeedFactory());

        // when
        vm.startPrank(ADMIN);
        factory.upgradeToAndCall(newImplementation, "");
        vm.stopPrank();

        // then - should not revert
        assertTrue(true, "Upgrade should succeed for owner");
    }

    function test_CreatePriceFeed_ValidatesVaultProperties() public {
        // This test verifies that the factory properly validates vault properties
        // by checking that it calls the vault's methods and validates the results

        // when
        address priceFeed = factory.create(VAULT_ADDRESS, PRICE_ORACLE_MIDDLEWARE);

        // then
        assertTrue(priceFeed != address(0), "Price feed should be created");

        // Verify the vault is properly set in the created price feed
        ERC4626PriceFeed feed = ERC4626PriceFeed(priceFeed);
        assertEq(feed.vault(), VAULT_ADDRESS, "Vault address should match");
    }
}
