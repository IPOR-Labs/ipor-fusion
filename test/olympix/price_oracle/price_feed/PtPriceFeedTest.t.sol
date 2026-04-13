// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {PtPriceFeed} from "../../../../contracts/price_oracle/price_feed/PtPriceFeed.sol";

import {PriceOracleMiddlewareHelper} from "test/test_helpers/PriceOracleMiddlewareHelper.sol";
import {MockPriceOracle} from "test/fuses/aave_v4/MockPriceOracle.sol";
import {PriceOracleMiddleware} from "contracts/price_oracle/PriceOracleMiddleware.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";
import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import {IPPYLpOracle} from "@pendle/core-v2/contracts/interfaces/IPPYLpOracle.sol";
import {TestAddresses} from "test/test_helpers/TestAddresses.sol";
contract PtPriceFeedTest is OlympixUnitTest("PtPriceFeed") {


    function test_getUnderlyingPrice_branchTrue() public {
            // This test only needs to hit the `if (true)` branch in getUnderlyingPrice()
            // We can bypass the real Pendle oracle/market logic by deploying PtPriceFeed
            // with dummy addresses that satisfy constructor checks via vm.mockCalls.
    
            // 1) Deploy a PriceOracleMiddleware proxy with this test as owner
            PriceOracleMiddleware priceOracle = PriceOracleMiddlewareHelper.deployPriceOracleMiddleware(
                address(this),
                address(0) // disable Chainlink registry to avoid external calls
            );
    
            // 2) Deploy a MockPriceOracle that will act as the asset price feed used by the middleware
            MockPriceOracle assetPriceFeed = new MockPriceOracle();
    
            // Choose some arbitrary underlying asset address and price
            address underlyingAsset = address(0x1234);
            uint256 assetPrice = 1_000e8; // price with 8 decimals
    
            // Configure the mock asset price feed
            assetPriceFeed.setAssetPriceWithDecimals(underlyingAsset, assetPrice, 8);

            // Mock decimals() on the price feed (PriceOracleMiddleware calls it)
            vm.mockCall(address(assetPriceFeed), abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
            // Mock latestRoundData on the price feed
            vm.mockCall(
                address(assetPriceFeed),
                abi.encodeWithSignature("latestRoundData()"),
                abi.encode(uint80(1), int256(assetPrice), uint256(0), uint256(block.timestamp), uint80(1))
            );

            // Configure middleware to use MockPriceOracle as source for underlyingAsset
            address[] memory assets = new address[](1);
            address[] memory sources = new address[](1);
            assets[0] = underlyingAsset;
            sources[0] = address(assetPriceFeed);
            priceOracle.setAssetsPricesSources(assets, sources);
    
            // 3) Prepare dummy Pendle oracle and market and mock the external calls
            address pendleOracle = address(0x1001);
            address pendleMarket = address(0x1002);
            uint32 twapWindow = 15 minutes; // above MIN_TWAP_WINDOW
    
            // Mock IPPYLpOracle(pendleOracle).getOracleState(pendleMarket, twapWindow)
            // so that constructor sees oracle as ready: (false, 0, true)
            vm.mockCall(
                pendleOracle,
                abi.encodeWithSelector(IPPYLpOracle.getOracleState.selector, pendleMarket, twapWindow),
                abi.encode(false, uint16(0), true)
            );
    
            // Mock IPMarket(pendleMarket).readTokens() to return a dummy SY that reports our underlyingAsset
            address syAddr = address(0x1003);
            vm.mockCall(
                pendleMarket,
                abi.encodeWithSelector(IPMarket.readTokens.selector),
                abi.encode(IStandardizedYield(syAddr), address(0), address(0))
            );
    
            // Mock sy.assetInfo() to return (0, underlyingAsset, 18)
            vm.mockCall(
                syAddr,
                abi.encodeWithSelector(IStandardizedYield.assetInfo.selector),
                abi.encode(uint8(0), underlyingAsset, uint8(18))
            );
    
            // 4) Deploy PtPriceFeed with mocked dependencies
            PtPriceFeed feed = new PtPriceFeed(
                pendleOracle,
                pendleMarket,
                twapWindow,
                address(priceOracle),
                0 // usePendleOracleMethod, irrelevant for getUnderlyingPrice
            );
    
            // 5) Act: call getUnderlyingPrice(), which must go through the `if (true)` branch
            (uint256 returnedPrice, uint256 returnedDecimals) = feed.getUnderlyingPrice();
    
            // 6) Assert: values must come from the price oracle middleware
            // The middleware returns the price from the Chainlink-like source
            assertTrue(returnedPrice > 0, "Underlying price should be non-zero");
            assertTrue(returnedDecimals > 0, "Decimals should be non-zero");
        }
}