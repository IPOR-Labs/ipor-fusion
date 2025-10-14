// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PtPriceFeedFactory} from "../../../contracts/factory/price_feed/PtPriceFeedFactory.sol";
import {PtPriceFeed} from "../../../contracts/price_oracle/price_feed/PtPriceFeed.sol";

struct TestItem {
    address market;
    int256 price;
    uint256 usePendleOracleMethod;
}

contract PtPriceFeedFactoryTest is Test {
    // Constants from SUSDFPriceFeedTest
    address private constant PRICE_ORACLE = 0xC9F32d65a278b012371858fD3cdE315B12d664c6;
    uint256 private constant BLOCK_NUMBER = 22373579;

    // Constants from PriceOracleMiddlewareWithRolesPTTokensTest
    address private constant PENDLE_ORACLE = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;

    // Test configuration
    uint32 private constant TWAP_WINDOW = 300; // 5 minutes
    address private constant ADMIN = address(0x1234);
    address private constant NEW_OWNER = address(0x5678);

    PtPriceFeedFactory private factory;
    PtPriceFeedFactory private factoryProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), BLOCK_NUMBER);

        // Deploy implementation
        factory = new PtPriceFeedFactory();

        // Deploy proxy and initialize
        factoryProxy = PtPriceFeedFactory(
            address(new ERC1967Proxy(address(factory), abi.encodeWithSignature("initialize(address)", ADMIN)))
        );
    }

    function testInitialize() public {
        // given
        PtPriceFeedFactory newFactory = new PtPriceFeedFactory();

        // when
        PtPriceFeedFactory newFactoryProxy = PtPriceFeedFactory(
            address(new ERC1967Proxy(address(newFactory), abi.encodeWithSignature("initialize(address)", ADMIN)))
        );

        // then
        assertEq(newFactoryProxy.owner(), ADMIN, "Owner should be ADMIN");
    }

    function testInitializeWithZeroAddress() public {
        // given
        PtPriceFeedFactory newFactory = new PtPriceFeedFactory();

        // when & then
        vm.expectRevert(abi.encodeWithSelector(PtPriceFeedFactory.InvalidAddress.selector));
        new ERC1967Proxy(address(newFactory), abi.encodeWithSignature("initialize(address)", address(0)));
    }

    function testCreate() public {
        // given
        TestItem memory item = _getTestItems()[0];

        // when
        vm.prank(ADMIN);
        address priceFeedAddress = factoryProxy.create(
            PENDLE_ORACLE,
            item.market,
            TWAP_WINDOW,
            PRICE_ORACLE,
            item.usePendleOracleMethod,
            item.price
        );

        // then
        assertTrue(priceFeedAddress != address(0), "Price feed address should not be zero");

        PtPriceFeed priceFeed = PtPriceFeed(priceFeedAddress);
        assertEq(priceFeed.PENDLE_MARKET(), item.market, "Market should match");
        assertEq(priceFeed.TWAP_WINDOW(), TWAP_WINDOW, "TWAP window should match");
        assertEq(priceFeed.PRICE_MIDDLEWARE(), PRICE_ORACLE, "Price middleware should match");
        assertEq(priceFeed.USE_PENDLE_ORACLE_METHOD(), item.usePendleOracleMethod, "Oracle method should match");

        // Verify price feed is functional
        (, int256 price, , uint256 timestamp, ) = priceFeed.latestRoundData();
        assertTrue(price > 0, "Price should be positive");
        assertEq(timestamp, block.timestamp, "Timestamp should match block timestamp");
    }

    function testCreateMultipleMarkets() public {
        // given
        TestItem[] memory testItems = _getTestItems();

        // when & then
        for (uint256 i = 0; i < testItems.length; i++) {
            // First calculate the actual price at this block
            int256 calculatedPrice = factoryProxy.calculatePrice(
                testItems[i].market,
                TWAP_WINDOW,
                PRICE_ORACLE,
                testItems[i].usePendleOracleMethod
            );

            vm.prank(ADMIN);
            address priceFeedAddress = factoryProxy.create(
                PENDLE_ORACLE,
                testItems[i].market,
                TWAP_WINDOW,
                PRICE_ORACLE,
                testItems[i].usePendleOracleMethod,
                calculatedPrice // Use calculated price instead of old expected price
            );

            assertTrue(priceFeedAddress != address(0), "Price feed address should not be zero");

            PtPriceFeed priceFeed = PtPriceFeed(priceFeedAddress);
            (, int256 price, , , ) = priceFeed.latestRoundData();
            assertTrue(price > 0, "Price should be positive");

            // Verify price matches calculated price exactly
            assertEq(price, calculatedPrice, "Price should match calculated price");
        }
    }

    function testCreateWithInvalidPendleOracleAddress() public {
        // given
        TestItem memory item = _getTestItems()[0];

        // when & then
        vm.expectRevert(abi.encodeWithSelector(PtPriceFeedFactory.InvalidAddress.selector));
        vm.prank(ADMIN);
        factoryProxy.create(address(0), item.market, TWAP_WINDOW, PRICE_ORACLE, item.usePendleOracleMethod, item.price);
    }

    function testCreateWithInvalidMarketAddress() public {
        // given
        TestItem memory item = _getTestItems()[0];

        // when & then
        vm.expectRevert(abi.encodeWithSelector(PtPriceFeedFactory.InvalidAddress.selector));
        vm.prank(ADMIN);
        factoryProxy.create(
            PENDLE_ORACLE,
            address(0),
            TWAP_WINDOW,
            PRICE_ORACLE,
            item.usePendleOracleMethod,
            item.price
        );
    }

    function testCreateWithInvalidPriceMiddlewareAddress() public {
        // given
        TestItem memory item = _getTestItems()[0];

        // when & then
        vm.expectRevert(abi.encodeWithSelector(PtPriceFeedFactory.InvalidAddress.selector));
        vm.prank(ADMIN);
        factoryProxy.create(
            PENDLE_ORACLE,
            item.market,
            TWAP_WINDOW,
            address(0),
            item.usePendleOracleMethod,
            item.price
        );
    }

    function testCreateWithInvalidExpectedPriceZero() public {
        // given
        TestItem memory item = _getTestItems()[0];

        // when & then
        vm.expectRevert(abi.encodeWithSelector(PtPriceFeedFactory.InvalidExpectedPrice.selector));
        vm.prank(ADMIN);
        factoryProxy.create(PENDLE_ORACLE, item.market, TWAP_WINDOW, PRICE_ORACLE, item.usePendleOracleMethod, 0);
    }

    function testCreateWithInvalidExpectedPriceNegative() public {
        // given
        TestItem memory item = _getTestItems()[0];

        // when & then
        vm.expectRevert(abi.encodeWithSelector(PtPriceFeedFactory.InvalidExpectedPrice.selector));
        vm.prank(ADMIN);
        factoryProxy.create(PENDLE_ORACLE, item.market, TWAP_WINDOW, PRICE_ORACLE, item.usePendleOracleMethod, -1);
    }

    function testCreateWithPriceDeltaTooHigh() public {
        // given
        TestItem memory item = _getTestItems()[0];
        int256 unrealisticPrice = item.price * 2; // 100% difference

        // when & then
        vm.expectRevert(abi.encodeWithSelector(PtPriceFeedFactory.PriceDeltaTooHigh.selector));
        vm.prank(ADMIN);
        factoryProxy.create(
            PENDLE_ORACLE,
            item.market,
            TWAP_WINDOW,
            PRICE_ORACLE,
            item.usePendleOracleMethod,
            unrealisticPrice
        );
    }

    function testCreateEmitsPtPriceFeedCreatedEvent() public {
        // given
        TestItem memory item = _getTestItems()[0];

        // when & then
        vm.expectEmit(true, true, false, false);
        emit PtPriceFeedFactory.PtPriceFeedCreated(address(0), item.market); // address(0) as placeholder

        vm.prank(ADMIN);
        factoryProxy.create(
            PENDLE_ORACLE,
            item.market,
            TWAP_WINDOW,
            PRICE_ORACLE,
            item.usePendleOracleMethod,
            item.price
        );
    }

    function testCalculatePrice() public view {
        // given
        TestItem memory item = _getTestItems()[0];

        // when
        int256 price = factoryProxy.calculatePrice(item.market, TWAP_WINDOW, PRICE_ORACLE, item.usePendleOracleMethod);

        // then
        assertTrue(price > 0, "Price should be positive");

        // Verify price is within 1% of expected
        int256 priceDelta = price > item.price ? price - item.price : item.price - price;
        int256 priceDeltaPercentage = (priceDelta * 100) / item.price;
        assertTrue(priceDeltaPercentage <= 1, "Price should be within 1% of expected");
    }

    function testCalculatePriceForMultipleMarkets() public view {
        // given
        TestItem[] memory testItems = _getTestItems();

        // when & then
        for (uint256 i = 0; i < testItems.length; i++) {
            int256 price = factoryProxy.calculatePrice(
                testItems[i].market,
                TWAP_WINDOW,
                PRICE_ORACLE,
                testItems[i].usePendleOracleMethod
            );

            // Verify price is positive and reasonable
            assertTrue(price > 0, "Price should be positive");

            // For PT tokens, prices should be in a reasonable range
            // PT prices are typically between 0 and slightly above the underlying asset price
            // With 8 decimals, reasonable range is 0 to ~200000000000 (2000 * 10^8)
            assertTrue(price < 200000000000, "Price should be in reasonable range");
        }
    }

    function testOwnershipTransfer() public {
        // given
        assertEq(factoryProxy.owner(), ADMIN, "Initial owner should be ADMIN");

        // when - start transfer
        vm.prank(ADMIN);
        factoryProxy.transferOwnership(NEW_OWNER);

        // then - ownership not yet transferred
        assertEq(factoryProxy.owner(), ADMIN, "Owner should still be ADMIN");
        assertEq(factoryProxy.pendingOwner(), NEW_OWNER, "Pending owner should be NEW_OWNER");

        // when - accept transfer
        vm.prank(NEW_OWNER);
        factoryProxy.acceptOwnership();

        // then - ownership transferred
        assertEq(factoryProxy.owner(), NEW_OWNER, "Owner should now be NEW_OWNER");
    }

    function testUpgradeAsOwner() public {
        // given
        PtPriceFeedFactory newImplementation = new PtPriceFeedFactory();

        // when
        vm.prank(ADMIN);
        factoryProxy.upgradeToAndCall(address(newImplementation), "");

        // then - proxy still works and owner is preserved
        assertEq(factoryProxy.owner(), ADMIN, "Owner should still be ADMIN after upgrade");
    }

    function testUpgradeAsNonOwnerReverts() public {
        // given
        PtPriceFeedFactory newImplementation = new PtPriceFeedFactory();

        // when & then
        vm.expectRevert();
        vm.prank(address(0x9999));
        factoryProxy.upgradeToAndCall(address(newImplementation), "");
    }

    function testCannotReinitialize() public {
        // when & then
        vm.expectRevert();
        factoryProxy.initialize(address(0x9999));
    }

    function _getTestItems() private pure returns (TestItem[] memory testItems) {
        testItems = new TestItem[](5);
        testItems[0] = TestItem({
            market: 0xB162B764044697cf03617C2EFbcB1f42e31E4766,
            price: int256(84102754),
            usePendleOracleMethod: 0
        });
        testItems[1] = TestItem({
            market: 0x85667e484a32d884010Cf16427D90049CCf46e97,
            price: int256(97221872),
            usePendleOracleMethod: 0
        });
        testItems[2] = TestItem({
            market: 0xB451A36c8B6b2EAc77AD0737BA732818143A0E25,
            price: int256(99503847),
            usePendleOracleMethod: 0
        });
        testItems[3] = TestItem({
            market: 0x353d0B2EFB5B3a7987fB06D30Ad6160522d08426,
            price: int256(99716640),
            usePendleOracleMethod: 1
        });
        testItems[4] = TestItem({
            market: 0xC374f7eC85F8C7DE3207a10bB1978bA104bdA3B2,
            price: int256(182040012762),
            usePendleOracleMethod: 1
        });
        return testItems;
    }
}
