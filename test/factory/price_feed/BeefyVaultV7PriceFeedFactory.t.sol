// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BeefyVaultV7PriceFeedFactory} from "../../../contracts/factory/price_feed/BeefyVaultV7PriceFeedFactory.sol";
import {BeefyVaultV7PriceFeed} from "../../../contracts/price_oracle/price_feed/BeefyVaultV7PriceFeed.sol";
import {IBeefyVaultV7} from "../../../contracts/price_oracle/price_feed/ext/IBeefyVaultV7.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {USDPriceFeed} from "../../../contracts/price_oracle/price_feed/USDPriceFeed.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract BeefyVaultV7PriceFeedFactoryTest is Test {
    BeefyVaultV7PriceFeedFactory public factory;
    address public constant PRICE_ORACLE_MIDDLEWARE = 0xB7018C15279E0f5990613cc00A91b6032066f2f7;
    address public constant PRICE_ORACLE_OWNER = 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569;
    address public constant ADMIN = address(0x1);
    address public oneDollarPriceFeed;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22894761);

        // Deploy implementation
        address implementation = address(new BeefyVaultV7PriceFeedFactory());

        // Deploy and initialize proxy
        factory = BeefyVaultV7PriceFeedFactory(
            address(new ERC1967Proxy(implementation, abi.encodeWithSignature("initialize(address)", ADMIN)))
        );

        // Setup price feeds for testing
        oneDollarPriceFeed = address(new USDPriceFeed());
    }

    function testShouldCreateBeefyVaultV7PriceFeed() external {
        // given
        address beefyVault = 0x0014E0be19De3118b5b29842dd1696a2A98EB9Db;
        ERC20Upgradeable want = IBeefyVaultV7(beefyVault).want();

        address[] memory assets = new address[](1);
        assets[0] = address(want);

        address[] memory priceFeeds = new address[](1);
        priceFeeds[0] = oneDollarPriceFeed;

        // Set the price feeds for the assets
        vm.startPrank(PRICE_ORACLE_OWNER);
        IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE).setAssetsPricesSources(assets, priceFeeds);
        vm.stopPrank();

        // when
        address priceFeed = factory.create(beefyVault, PRICE_ORACLE_MIDDLEWARE);

        // then
        assertTrue(priceFeed != address(0), "Price feed should not be zero address");

        // Verify the price feed returns the expected price
        (, int256 price, , , ) = BeefyVaultV7PriceFeed(priceFeed).latestRoundData();
        assertEq(price, 1013869649889381869, "Price should be 1013869649889381869");
    }

    function testShouldCreateBeefyVaultV7PriceFeedUSDOUSDOPLUS() external {
        // given
        address beefyVault = 0x6E0d7f2929194cEa155FFC809BBf941EC5732395;
        ERC20Upgradeable want = IBeefyVaultV7(beefyVault).want();

        address[] memory assets = new address[](1);
        assets[0] = address(want);

        address[] memory priceFeeds = new address[](1);
        priceFeeds[0] = oneDollarPriceFeed;

        // Set the price feeds for the assets
        vm.startPrank(PRICE_ORACLE_OWNER);
        IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE).setAssetsPricesSources(assets, priceFeeds);
        vm.stopPrank();

        // when
        address priceFeed = factory.create(beefyVault, PRICE_ORACLE_MIDDLEWARE);

        // then
        assertTrue(priceFeed != address(0), "Price feed should not be zero address");

        // Verify the price feed returns the expected price
        (, int256 price, , , ) = BeefyVaultV7PriceFeed(priceFeed).latestRoundData();
        assertEq(price, 1003490595866690462, "Price should be 1003490595866690462");
    }

    function testShouldRevertWhenBeefyVaultIsZeroAddress() external {
        // when & then
        vm.expectRevert(BeefyVaultV7PriceFeed.ZeroAddress.selector);
        factory.create(address(0), PRICE_ORACLE_MIDDLEWARE);
    }

    function testShouldRevertWhenPriceOracleMiddlewareIsZeroAddress() external {
        // when & then
        vm.expectRevert(BeefyVaultV7PriceFeed.ZeroAddress.selector);
        factory.create(0x0014E0be19De3118b5b29842dd1696a2A98EB9Db, address(0));
    }

    function testShouldEmitBeefyVaultV7PriceFeedCreatedEvent() external {
        // given
        address beefyVault = 0x0014E0be19De3118b5b29842dd1696a2A98EB9Db;
        ERC20Upgradeable want = IBeefyVaultV7(beefyVault).want();

        address[] memory assets = new address[](1);
        assets[0] = address(want);

        address[] memory priceFeeds = new address[](1);
        priceFeeds[0] = oneDollarPriceFeed;

        // Set the price feeds for the assets
        vm.startPrank(PRICE_ORACLE_OWNER);
        IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE).setAssetsPricesSources(assets, priceFeeds);
        vm.stopPrank();

        // when & then
        vm.expectEmit(true, true, true, false);
        emit BeefyVaultV7PriceFeedFactory.BeefyVaultV7PriceFeedCreated(address(0), beefyVault, PRICE_ORACLE_MIDDLEWARE);
        factory.create(beefyVault, PRICE_ORACLE_MIDDLEWARE);
    }
}
