// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {BeefyVaultV7PriceFeed} from "../../../contracts/price_oracle/price_feed/BeefyVaultV7PriceFeed.sol";
import {IBeefyVaultV7} from "../../../contracts/price_oracle/price_feed/ext/IBeefyVaultV7.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {USDPriceFeed} from "../../../contracts/price_oracle/price_feed/USDPriceFeed.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract BeefyVaultV7PriceFeedTest is Test {
    address public constant PRICE_ORACLE_MIDDLEWARE = 0xB7018C15279E0f5990613cc00A91b6032066f2f7;
    address public constant PRICE_ORACLE_OWNER = 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569;
    address public oneDollarPriceFeed;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22894761);
        oneDollarPriceFeed = address(new USDPriceFeed());
    }

    function testShouldReturnPriceForBeefyVaultV7() external {
        //given
        address beefyVault = 0x0014E0be19De3118b5b29842dd1696a2A98EB9Db;

        ERC20Upgradeable want = IBeefyVaultV7(beefyVault).want();

        address[] memory assets = new address[](1);
        assets[0] = address(want);

        address[] memory priceFeeds = new address[](1);
        priceFeeds[0] = oneDollarPriceFeed;

        /// @dev set the price feeds for the assets, for simplicity we use the same price feed for all the assets
        vm.startPrank(PRICE_ORACLE_OWNER);
        IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE).setAssetsPricesSources(assets, priceFeeds);
        vm.stopPrank();

        //when

        BeefyVaultV7PriceFeed priceFeed = new BeefyVaultV7PriceFeed(beefyVault, PRICE_ORACLE_MIDDLEWARE);

        // then
        (, int256 price, , , ) = priceFeed.latestRoundData();
        assertEq(price, 1013869649889381869, "price should be 1013869649889381869");
    }

    function testShouldReturnPriceForBeefyVaultV7USDOUSDOPLUS() external {
        //given
        address beefyVault = 0x6E0d7f2929194cEa155FFC809BBf941EC5732395;

        ERC20Upgradeable want = IBeefyVaultV7(beefyVault).want();

        address[] memory assets = new address[](1);
        assets[0] = address(want);

        address[] memory priceFeeds = new address[](1);
        priceFeeds[0] = oneDollarPriceFeed;

        /// @dev set the price feeds for the assets, for simplicity we use the same price feed for all the assets
        vm.startPrank(PRICE_ORACLE_OWNER);
        IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE).setAssetsPricesSources(assets, priceFeeds);
        vm.stopPrank();

        //when

        BeefyVaultV7PriceFeed priceFeed = new BeefyVaultV7PriceFeed(beefyVault, PRICE_ORACLE_MIDDLEWARE);

        // then
        (, int256 price, , , ) = priceFeed.latestRoundData();
        assertEq(price, 1003490595866690462, "price should be 1003490595866690462");
    }
}
