// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../test/OlympixUnitTest.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";

import {PriceOracleMiddleware} from "contracts/price_oracle/PriceOracleMiddleware.sol";
import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PriceOracleMiddlewareStorageLib} from "contracts/price_oracle/PriceOracleMiddlewareStorageLib.sol";
import {IPriceFeed} from "contracts/price_oracle/price_feed/IPriceFeed.sol";
contract PriceOracleMiddlewareTest is OlympixUnitTest("PriceOracleMiddleware") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_getAssetsPrices_RevertsOnEmptyArray_opix_branch_76_true() public {
            PriceOracleMiddleware middleware = new PriceOracleMiddleware(address(0));
            middleware.initialize(address(this));
    
            address[] memory assets = new address[](0);
    
            vm.expectRevert(IPriceOracleMiddleware.EmptyArrayNotSupported.selector);
            middleware.getAssetsPrices(assets);
        }

    function test_getAssetsPrices_NonEmptyArray_opix_branch_78_false() public {
            // Arrange: deploy middleware with Chainlink registry disabled so _getAssetPrice
            // will revert with UnsupportedAsset for an unknown asset, but only
            // after the branch on assetsLength != 0 has been taken.
            PriceOracleMiddleware middleware = new PriceOracleMiddleware(address(0));
            middleware.initialize(address(this));

            address[] memory assets = new address[](1);
            assets[0] = address(0x1234);

            // Expect revert from unsupported asset (after passing the empty-array check)
            vm.expectRevert(IPriceOracleMiddleware.UnsupportedAsset.selector);
            middleware.getAssetsPrices(assets);
        }

    function test_getSourceOfAssetPrice_ReturnsStoredSource_opix_branch_94_true() public {
            // Deploy middleware with any Chainlink registry (value irrelevant for this test)
            PriceOracleMiddleware middleware = new PriceOracleMiddleware(address(0));
            middleware.initialize(address(this));

            // Prepare asset and source addresses
            address asset = address(0xABCD);
            address source = address(0xDEAD);

            // Set the asset price source via the middleware's owner function
            address[] memory assets = new address[](1);
            address[] memory sources = new address[](1);
            assets[0] = asset;
            sources[0] = source;
            middleware.setAssetsPricesSources(assets, sources);

            // When: calling getSourceOfAssetPrice, it should return the stored source
            address returnedSource = middleware.getSourceOfAssetPrice(asset);

            // Then: assert we hit the true branch and get the correct value
            assertEq(returnedSource, source, "getSourceOfAssetPrice should return stored source address");
        }

    function test_setAssetsPricesSources_EmptyArraysRevert() public {
            // Deploy middleware with dummy Chainlink registry (non-zero so CHAINLINK_FEED_REGISTRY != address(0))
            PriceOracleMiddleware middleware = new PriceOracleMiddleware(address(0x1));
    
            // Initialize ownership to this test contract so onlyOwner modifier passes
            middleware.initialize(address(this));
    
            address[] memory assets = new address[](0);
            address[] memory sources = new address[](0);
    
            vm.expectRevert(IPriceOracleMiddleware.EmptyArrayNotSupported.selector);
            middleware.setAssetsPricesSources(assets, sources);
        }

    function test_setAssetsPricesSources_ArrayLengthMismatch_opix_branch_113_true() public {
            // Deploy middleware with non-zero Chainlink registry so CHAINLINK_FEED_REGISTRY != address(0)
            PriceOracleMiddleware middleware = new PriceOracleMiddleware(address(0x1));
            // Initialize ownership to this test contract so onlyOwner modifier passes
            middleware.initialize(address(this));
    
            // Prepare mismatched arrays to trigger the `assetsLength != sourcesLength` branch
            address[] memory assets = new address[](2);
            address[] memory sources = new address[](1);
            assets[0] = address(0xA1);
            assets[1] = address(0xA2);
            sources[0] = address(0xB1);
    
            vm.expectRevert(IPriceOracleMiddleware.ArrayLengthMismatch.selector);
            middleware.setAssetsPricesSources(assets, sources);
        }

    function test_getAssetPrice_ZeroAssetReverts_opix_branch_137_true() public {
        // Deploy middleware with non-zero Chainlink registry so CHAINLINK_FEED_REGISTRY != address(0)
        PriceOracleMiddleware middleware = new PriceOracleMiddleware(address(0x1));
        middleware.initialize(address(this));
    
        // Expect revert from _getAssetPrice when asset_ == address(0)
        vm.expectRevert(IPriceOracleMiddleware.UnsupportedAsset.selector);
        middleware.getAssetPrice(address(0));
    }

    function test_getAssetPrice_NoCustomSourceAndNoChainlink_revertsUnsupportedAsset_opix_branch_152_true() public {
            // CHAINLINK_FEED_REGISTRY set to address(0) to force branch where registry is disabled
            PriceOracleMiddleware middleware = new PriceOracleMiddleware(address(0));
            middleware.initialize(address(this));
    
            // Use non-zero asset so the zero-asset check passes and we reach the CHAINLINK_FEED_REGISTRY == address(0) branch
            address someAsset = address(0x1234);
    
            vm.expectRevert(IPriceOracleMiddleware.UnsupportedAsset.selector);
            middleware.getAssetPrice(someAsset);
        }

    function test_getAssetPrice_RevertOnNonPositivePrice_opix_branch_174_true() public {
            // Deploy middleware with CHAINLINK_FEED_REGISTRY set to this test contract address.
            // This makes calls to FeedRegistryInterface(CHAINLINK_FEED_REGISTRY) route back here,
            // where we return a zero price to trigger the `assetPrice <= 0` branch.
            PriceOracleMiddleware middleware = new PriceOracleMiddleware(address(this));
            middleware.initialize(address(this));
    
            // Prepare a dummy asset address. It will be passed into our mocked
            // FeedRegistryInterface implementation below.
            address someAsset = address(0x1234);
    
            // Expect the custom error emitted when assetPrice <= 0 after conversion to WAD.
            vm.expectRevert(IPriceOracleMiddleware.UnexpectedPriceResult.selector);
    
            // This call will internally hit _getAssetPrice, which will:
            // - see no custom source for `someAsset`
            // - use CHAINLINK_FEED_REGISTRY == address(this)
            // - call our mocked latestRoundData and decimals below
            // - compute assetPrice == 0
            // - hit `if (assetPrice <= 0)` branch and revert with UnexpectedPriceResult.
            middleware.getAssetPrice(someAsset);
        }
    
        // ===== Mock Chainlink FeedRegistryInterface for this test =====
    
        function latestRoundData(address /*base*/, address /*quote*/)
            external
            pure
            returns (uint80, int256, uint256, uint256, uint80)
        {
            // Return price = 0 to ensure assetPrice becomes 0 and triggers the branch
            return (0, int256(0), 0, 0, 0);
        }
    
        function decimals(address /*base*/, address /*quote*/) external pure returns (uint8) {
            // Any valid decimals value works; choose 8 like standard Chainlink feeds
            return 8;
        }
}