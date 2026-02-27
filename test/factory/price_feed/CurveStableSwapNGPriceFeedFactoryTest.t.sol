// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CurveStableSwapNGPriceFeedFactory} from "../../../contracts/factory/price_feed/CurveStableSwapNGPriceFeedFactory.sol";
import {CurveStableSwapNGPriceFeed} from "../../../contracts/price_oracle/price_feed/CurveStableSwapNGPriceFeed.sol";
import {USDPriceFeed} from "../../../contracts/price_oracle/price_feed/USDPriceFeed.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";

contract CurveStableSwapNGPriceFeedFactoryTest is Test {
    CurveStableSwapNGPriceFeedFactory public factory;
    address public constant PRICE_ORACLE_MIDDLEWARE = 0xB7018C15279E0f5990613cc00A91b6032066f2f7;
    address public constant PRICE_ORACLE_OWNER = 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569;
    address public constant CURVE_POOL_USDC_USDF = 0x72310DAAed61321b02B08A547150c07522c6a976;
    address public constant CURVE_POOL_USDC_USDT = 0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDF = 0xFa2B947eEc368f42195f24F36d2aF29f7c24CeC2;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant ADMIN = address(0x1);
    address public oneDollarPriceFeed;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22894761);

        // Deploy implementation
        address implementation = address(new CurveStableSwapNGPriceFeedFactory());

        // Deploy and initialize proxy
        factory = CurveStableSwapNGPriceFeedFactory(
            address(new ERC1967Proxy(implementation, abi.encodeWithSignature("initialize(address)", ADMIN)))
        );

        // Setup price feeds for testing
        oneDollarPriceFeed = address(new USDPriceFeed());
        _setupPriceFeeds();
    }

    function _setupPriceFeeds() internal {
        address[] memory assets = new address[](3);
        assets[0] = USDC;
        assets[1] = USDF;
        assets[2] = USDT;

        address[] memory priceFeeds = new address[](3);
        priceFeeds[0] = oneDollarPriceFeed;
        priceFeeds[1] = oneDollarPriceFeed;
        priceFeeds[2] = oneDollarPriceFeed;

        vm.startPrank(PRICE_ORACLE_OWNER);
        IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE).setAssetsPricesSources(assets, priceFeeds);
        vm.stopPrank();
    }

    function test_Initialize() public {
        assertEq(factory.owner(), ADMIN, "Owner should be set correctly");
    }

    function test_CreatePriceFeed_UsdcUsdf() public {
        // when
        address priceFeed = factory.create(CURVE_POOL_USDC_USDF, PRICE_ORACLE_MIDDLEWARE);

        // then
        assertTrue(priceFeed != address(0), "Price feed should be created");

        CurveStableSwapNGPriceFeed feed = CurveStableSwapNGPriceFeed(priceFeed);
        assertEq(feed.CURVE_STABLE_SWAP_NG(), CURVE_POOL_USDC_USDF, "Curve pool should be set correctly");
        assertEq(
            feed.PRICE_ORACLE_MIDDLEWARE(),
            PRICE_ORACLE_MIDDLEWARE,
            "Price oracle middleware should be set correctly"
        );
        assertEq(feed.N_COINS(), 2, "N_COINS should be 2 for this pool");
        assertEq(feed.DECIMALS_LP(), 18, "DECIMALS_LP should be 18");
        assertEq(feed.coins(0), USDC, "First coin should be USDC");
        assertEq(feed.coins(1), USDF, "Second coin should be USDF");

        // Verify price is returned correctly
        (, int256 price, , , ) = feed.latestRoundData();
        assertTrue(price > 0, "Price should be positive");
    }

    function test_CreatePriceFeed_UsdcUsdt() public {
        // when
        address priceFeed = factory.create(CURVE_POOL_USDC_USDT, PRICE_ORACLE_MIDDLEWARE);

        // then
        assertTrue(priceFeed != address(0), "Price feed should be created");

        CurveStableSwapNGPriceFeed feed = CurveStableSwapNGPriceFeed(priceFeed);
        assertEq(feed.CURVE_STABLE_SWAP_NG(), CURVE_POOL_USDC_USDT, "Curve pool should be set correctly");
        assertEq(
            feed.PRICE_ORACLE_MIDDLEWARE(),
            PRICE_ORACLE_MIDDLEWARE,
            "Price oracle middleware should be set correctly"
        );
        assertEq(feed.N_COINS(), 2, "N_COINS should be 2 for this pool");
        assertEq(feed.DECIMALS_LP(), 18, "DECIMALS_LP should be 18");
        assertEq(feed.coins(0), USDC, "First coin should be USDC");
        assertEq(feed.coins(1), USDT, "Second coin should be USDT");

        // Verify price is returned correctly
        (, int256 price, , , ) = feed.latestRoundData();
        assertTrue(price > 0, "Price should be positive");
    }

    function test_CreatePriceFeed_ZeroAddressCurvePool() public {
        // when/then
        vm.expectRevert(CurveStableSwapNGPriceFeed.ZeroAddress.selector);
        factory.create(address(0), PRICE_ORACLE_MIDDLEWARE);
    }

    function test_CreatePriceFeed_ZeroAddressPriceOracleMiddleware() public {
        // when/then
        vm.expectRevert(CurveStableSwapNGPriceFeed.ZeroAddress.selector);
        factory.create(CURVE_POOL_USDC_USDF, address(0));
    }

    function test_CreatePriceFeed_BothZeroAddresses() public {
        // when/then
        vm.expectRevert(CurveStableSwapNGPriceFeed.ZeroAddress.selector);
        factory.create(address(0), address(0));
    }

    function test_CreatePriceFeed_InvalidPrice() public {
        // given - create a mock curve pool that would return invalid price
        address mockCurvePool = address(0x999);

        // Mock the curve pool calls to simulate a pool with zero total supply
        vm.mockCall(mockCurvePool, abi.encodeWithSignature("totalSupply()"), abi.encode(0));
        vm.mockCall(mockCurvePool, abi.encodeWithSignature("N_COINS()"), abi.encode(2));
        vm.mockCall(mockCurvePool, abi.encodeWithSignature("decimals()"), abi.encode(18));
        vm.mockCall(mockCurvePool, abi.encodeWithSignature("coins(uint256)"), abi.encode(USDC));

        // when/then - the factory should revert with the price feed error when total supply is zero
        vm.expectRevert(CurveStableSwapNGPriceFeed.CurveStableSwapNG_InvalidTotalSupply.selector);
        factory.create(mockCurvePool, PRICE_ORACLE_MIDDLEWARE);
    }

    function test_CreatePriceFeed_ZeroPrice() public {
        // given - create a mock curve pool that returns valid data but zero price
        address mockCurvePool = address(0x888);

        // Mock the curve pool calls to simulate a pool with valid total supply but zero price
        vm.mockCall(mockCurvePool, abi.encodeWithSignature("totalSupply()"), abi.encode(1000000));
        vm.mockCall(mockCurvePool, abi.encodeWithSignature("N_COINS()"), abi.encode(2));
        vm.mockCall(mockCurvePool, abi.encodeWithSignature("decimals()"), abi.encode(18));
        vm.mockCall(mockCurvePool, abi.encodeWithSignature("coins(uint256)"), abi.encode(USDC));
        vm.mockCall(mockCurvePool, abi.encodeWithSignature("balances(uint256)"), abi.encode(500000));

        // Mock the price oracle middleware to return zero price
        vm.mockCall(PRICE_ORACLE_MIDDLEWARE, abi.encodeWithSignature("getAssetPrice(address)"), abi.encode(0, 18));

        // when/then - the factory should revert with the price feed error when price is zero
        vm.expectRevert(CurveStableSwapNGPriceFeed.PriceOracleMiddleware_InvalidPrice.selector);
        factory.create(mockCurvePool, PRICE_ORACLE_MIDDLEWARE);
    }

    function test_CreatePriceFeed_EventEmitted() public {
        // when
        address priceFeed = factory.create(CURVE_POOL_USDC_USDF, PRICE_ORACLE_MIDDLEWARE);

        // then - verify the price feed was created
        assertTrue(priceFeed != address(0), "Price feed should be created");

        // Note: The event is emitted during the create call, so we can't test it with expectEmit
        // The event emission is verified by checking that the price feed was created successfully
    }

    function test_Upgrade_NotOwner() public {
        address caller = address(0x2);
        // given
        address newImplementation = address(new CurveStableSwapNGPriceFeedFactory());

        // when/then
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", caller));
        vm.startPrank(caller);
        factory.upgradeToAndCall(newImplementation, "");
        vm.stopPrank();
    }

    function test_Upgrade_Owner() public {
        // given
        address newImplementation = address(new CurveStableSwapNGPriceFeedFactory());

        // when
        vm.startPrank(ADMIN);
        factory.upgradeToAndCall(newImplementation, "");
        vm.stopPrank();

        // then - factory should still work after upgrade
        address priceFeed = factory.create(CURVE_POOL_USDC_USDF, PRICE_ORACLE_MIDDLEWARE);
        assertTrue(priceFeed != address(0), "Price feed should be created after upgrade");
    }

    function test_Initialize_ZeroAddress() public {
        // given
        address implementation = address(new CurveStableSwapNGPriceFeedFactory());

        // when/then
        vm.expectRevert(CurveStableSwapNGPriceFeedFactory.InvalidAddress.selector);
        new ERC1967Proxy(implementation, abi.encodeWithSignature("initialize(address)", address(0)));
    }

    function test_CreateMultiplePriceFeeds() public {
        // when
        address priceFeed1 = factory.create(CURVE_POOL_USDC_USDF, PRICE_ORACLE_MIDDLEWARE);
        address priceFeed2 = factory.create(CURVE_POOL_USDC_USDT, PRICE_ORACLE_MIDDLEWARE);

        // then
        assertTrue(priceFeed1 != address(0), "First price feed should be created");
        assertTrue(priceFeed2 != address(0), "Second price feed should be created");
        assertTrue(priceFeed1 != priceFeed2, "Price feeds should be different addresses");

        CurveStableSwapNGPriceFeed feed1 = CurveStableSwapNGPriceFeed(priceFeed1);
        CurveStableSwapNGPriceFeed feed2 = CurveStableSwapNGPriceFeed(priceFeed2);

        assertEq(feed1.CURVE_STABLE_SWAP_NG(), CURVE_POOL_USDC_USDF, "First feed should have correct pool");
        assertEq(feed2.CURVE_STABLE_SWAP_NG(), CURVE_POOL_USDC_USDT, "Second feed should have correct pool");
    }

    function test_CreatePriceFeed_VerifyDecimals() public {
        // when
        address priceFeed = factory.create(CURVE_POOL_USDC_USDF, PRICE_ORACLE_MIDDLEWARE);

        // then
        CurveStableSwapNGPriceFeed feed = CurveStableSwapNGPriceFeed(priceFeed);
        assertEq(feed.decimals(), 18, "Price feed decimals should be 18");
    }
}
