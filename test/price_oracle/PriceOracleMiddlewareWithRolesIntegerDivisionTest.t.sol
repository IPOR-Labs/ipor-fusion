// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddlewareWithRoles} from "../../contracts/price_oracle/PriceOracleMiddlewareWithRoles.sol";
import {PtPriceFeed} from "../../contracts/price_oracle/price_feed/PtPriceFeed.sol";
import {IPriceOracleMiddleware} from "../../contracts/price_oracle/IPriceOracleMiddleware.sol";

contract PriceOracleMiddlewareWithRolesIntegerDivisionTest is Test {
    address private constant CHAINLINK_FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address public constant ADMIN = 0xD92E9F039E4189c342b4067CC61f5d063960D248;

    PriceOracleMiddlewareWithRoles private priceOracleMiddlewareProxy;

    // Using MARCKET_SUSDE from the original test
    address private constant PENDLE_MARKET = 0xB162B764044697cf03617C2EFbcB1f42e31E4766;
    address public constant PENDLE_ORACLE = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
    uint32 private constant TWAP_WINDOW = 300;
    uint256 private constant USE_PENDLE_ORACLE_METHOD = 0;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22061720);
        PriceOracleMiddlewareWithRoles implementation = new PriceOracleMiddlewareWithRoles(CHAINLINK_FEED_REGISTRY);

        priceOracleMiddlewareProxy = PriceOracleMiddlewareWithRoles(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", ADMIN)))
        );

        vm.startPrank(ADMIN);
        priceOracleMiddlewareProxy.grantRole(priceOracleMiddlewareProxy.ADD_PT_TOKEN_PRICE(), ADMIN);
        vm.stopPrank();
    }

    function testShouldRevertWithNearlyTwoPercentDeviation() public {
        // 1. Determine the actual price
        PtPriceFeed tempFeed = new PtPriceFeed(
            PENDLE_ORACLE,
            PENDLE_MARKET,
            TWAP_WINDOW,
            address(priceOracleMiddlewareProxy),
            USE_PENDLE_ORACLE_METHOD
        );

        (, int256 actualPrice, , , ) = tempFeed.latestRoundData();
        require(actualPrice > 0, "Actual price should be positive");

        // 2. Calculate expected price for ~1.98% deviation
        // actual = expected * 1.0198
        // expected = actual / 1.0198
        int256 expectedPrice = (actualPrice * 10000) / 10198;

        // 3. Expect revert
        vm.expectRevert(IPriceOracleMiddleware.PriceDeltaTooHigh.selector);
        vm.startPrank(ADMIN);
        priceOracleMiddlewareProxy.createAndAddPtTokenPriceFeed(
            PENDLE_ORACLE,
            PENDLE_MARKET,
            TWAP_WINDOW,
            expectedPrice,
            USE_PENDLE_ORACLE_METHOD
        );
        vm.stopPrank();
    }

    function testShouldRevertWithJustOverOnePercentDeviation() public {
        PtPriceFeed tempFeed = new PtPriceFeed(
            PENDLE_ORACLE,
            PENDLE_MARKET,
            TWAP_WINDOW,
            address(priceOracleMiddlewareProxy),
            USE_PENDLE_ORACLE_METHOD
        );
        (, int256 actualPrice, , , ) = tempFeed.latestRoundData();

        // 1.01% deviation.
        // actual = expected * 1.0101
        // expected = actual / 1.0101
        int256 expectedPrice = (actualPrice * 10000) / 10101;

        vm.expectRevert(IPriceOracleMiddleware.PriceDeltaTooHigh.selector);
        vm.startPrank(ADMIN);
        priceOracleMiddlewareProxy.createAndAddPtTokenPriceFeed(
            PENDLE_ORACLE,
            PENDLE_MARKET,
            TWAP_WINDOW,
            expectedPrice,
            USE_PENDLE_ORACLE_METHOD
        );
        vm.stopPrank();
    }

    function testShouldAcceptJustUnderOnePercentDeviation() public {
        PtPriceFeed tempFeed = new PtPriceFeed(
            PENDLE_ORACLE,
            PENDLE_MARKET,
            TWAP_WINDOW,
            address(priceOracleMiddlewareProxy),
            USE_PENDLE_ORACLE_METHOD
        );
        (, int256 actualPrice, , , ) = tempFeed.latestRoundData();

        // 0.99% deviation.
        // actual = expected * 1.0099
        // expected = actual / 1.0099
        int256 expectedPrice = (actualPrice * 10000) / 10099;

        // Should pass
        vm.startPrank(ADMIN);
        priceOracleMiddlewareProxy.createAndAddPtTokenPriceFeed(
            PENDLE_ORACLE,
            PENDLE_MARKET,
            TWAP_WINDOW,
            expectedPrice,
            USE_PENDLE_ORACLE_METHOD
        );
        vm.stopPrank();
    }
}
