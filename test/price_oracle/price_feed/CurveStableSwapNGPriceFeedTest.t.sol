// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {CurveStableSwapNGPriceFeed} from "../../../contracts/price_oracle/price_feed/CurveStableSwapNGPriceFeed.sol";
import {USDPriceFeed} from "../../../contracts/price_oracle/price_feed/USDPriceFeed.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract CurveStableSwapNGPriceFeedTest is Test {
    using SafeCast for int256;

    address public constant PRICE_ORACLE_MIDDLEWARE = 0xB7018C15279E0f5990613cc00A91b6032066f2f7;
    address public constant PRICE_ORACLE_OWNER = 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569;
    address public oneDollarPriceFeed;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22894761);
        oneDollarPriceFeed = address(new USDPriceFeed());
    }

    function testShouldReturnPriceForCurveStableSwapNGUsdcUsdf() external {
        //given
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address usdf = 0xFa2B947eEc368f42195f24F36d2aF29f7c24CeC2;

        address curvePool = 0x72310DAAed61321b02B08A547150c07522c6a976;

        address[] memory assets = new address[](2);
        assets[0] = usdc;
        assets[1] = usdf;

        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = oneDollarPriceFeed;
        priceFeeds[1] = oneDollarPriceFeed;

        vm.startPrank(PRICE_ORACLE_OWNER);
        /// @dev set the price feeds for the assets, for simplicity we use the same price feed for all the assets
        IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE).setAssetsPricesSources(assets, priceFeeds);
        vm.stopPrank();

        //when
        CurveStableSwapNGPriceFeed priceFeed = new CurveStableSwapNGPriceFeed(curvePool, PRICE_ORACLE_MIDDLEWARE);

        //then
        (, int256 price, , , ) = priceFeed.latestRoundData();

        assertEq(price.toUint256(), 1003204027187410119, "price should be 1003204027187410119");
    }

    function testShouldReturnPriceForCurveStableSwapNGUsdcUsdt() external {
        //given
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address usdt = 0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85;

        address curvePool = 0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85;

        address[] memory assets = new address[](2);
        assets[0] = usdc;
        assets[1] = usdt;

        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = oneDollarPriceFeed;
        priceFeeds[1] = oneDollarPriceFeed;

        vm.startPrank(PRICE_ORACLE_OWNER);
        /// @dev set the price feeds for the assets, for simplicity we use the same price feed for all the assets
        IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE).setAssetsPricesSources(assets, priceFeeds);
        vm.stopPrank();

        //when
        CurveStableSwapNGPriceFeed priceFeed = new CurveStableSwapNGPriceFeed(curvePool, PRICE_ORACLE_MIDDLEWARE);

        //then
        (, int256 price, , , ) = priceFeed.latestRoundData();

        assertEq(price.toUint256(), 1008975118800000000, "price should be 1008975118800000000");
    }

    // Constructor tests
    function testShouldDeploySuccessfullyWithValidParameters() external {
        // given
        address curvePool = 0x72310DAAed61321b02B08A547150c07522c6a976;
        address priceOracleMiddleware = PRICE_ORACLE_MIDDLEWARE;

        // when
        CurveStableSwapNGPriceFeed priceFeed = new CurveStableSwapNGPriceFeed(curvePool, priceOracleMiddleware);

        // then
        assertEq(priceFeed.CURVE_STABLE_SWAP_NG(), curvePool, "CURVE_STABLE_SWAP_NG should be set correctly");
        assertEq(
            priceFeed.PRICE_ORACLE_MIDDLEWARE(),
            priceOracleMiddleware,
            "PRICE_ORACLE_MIDDLEWARE should be set correctly"
        );
        assertEq(priceFeed.N_COINS(), 2, "N_COINS should be 2 for this pool");
        assertEq(priceFeed.DECIMALS_LP(), 18, "DECIMALS_LP should be 18");
        assertEq(priceFeed.coins(0), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "First coin should be USDC");
        assertEq(priceFeed.coins(1), 0xFa2B947eEc368f42195f24F36d2aF29f7c24CeC2, "Second coin should be USDF");
    }

    function testShouldRevertWhenCurveStableSwapNGIsZeroAddress() external {
        // given
        address curvePool = address(0);
        address priceOracleMiddleware = PRICE_ORACLE_MIDDLEWARE;

        // when & then
        vm.expectRevert(CurveStableSwapNGPriceFeed.ZeroAddress.selector);
        new CurveStableSwapNGPriceFeed(curvePool, priceOracleMiddleware);
    }

    function testShouldRevertWhenPriceOracleMiddlewareIsZeroAddress() external {
        // given
        address curvePool = 0x72310DAAed61321b02B08A547150c07522c6a976;
        address priceOracleMiddleware = address(0);

        // when & then
        vm.expectRevert(CurveStableSwapNGPriceFeed.ZeroAddress.selector);
        new CurveStableSwapNGPriceFeed(curvePool, priceOracleMiddleware);
    }

    function testShouldRevertWhenBothParametersAreZeroAddress() external {
        // given
        address curvePool = address(0);
        address priceOracleMiddleware = address(0);

        // when & then
        vm.expectRevert(CurveStableSwapNGPriceFeed.ZeroAddress.selector);
        new CurveStableSwapNGPriceFeed(curvePool, priceOracleMiddleware);
    }

    function testShouldInitializeCoinsArrayCorrectly() external {
        // given
        address curvePool = 0x72310DAAed61321b02B08A547150c07522c6a976;
        address priceOracleMiddleware = PRICE_ORACLE_MIDDLEWARE;

        // when
        CurveStableSwapNGPriceFeed priceFeed = new CurveStableSwapNGPriceFeed(curvePool, priceOracleMiddleware);

        // then
        assertEq(priceFeed.coins(0), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "First coin should be USDC");
        assertEq(priceFeed.coins(1), 0xFa2B947eEc368f42195f24F36d2aF29f7c24CeC2, "Second coin should be USDF");
    }

    function testShouldSetImmutableVariablesCorrectly() external {
        // given
        address curvePool = 0x72310DAAed61321b02B08A547150c07522c6a976;
        address priceOracleMiddleware = PRICE_ORACLE_MIDDLEWARE;

        // when
        CurveStableSwapNGPriceFeed priceFeed = new CurveStableSwapNGPriceFeed(curvePool, priceOracleMiddleware);

        // then
        assertEq(priceFeed.CURVE_STABLE_SWAP_NG(), curvePool, "CURVE_STABLE_SWAP_NG immutable should be set");
        assertEq(
            priceFeed.PRICE_ORACLE_MIDDLEWARE(),
            priceOracleMiddleware,
            "PRICE_ORACLE_MIDDLEWARE immutable should be set"
        );
        assertEq(priceFeed.N_COINS(), 2, "N_COINS immutable should be set to 2");
        assertEq(priceFeed.DECIMALS_LP(), 18, "DECIMALS_LP immutable should be set to 18");
    }
}
