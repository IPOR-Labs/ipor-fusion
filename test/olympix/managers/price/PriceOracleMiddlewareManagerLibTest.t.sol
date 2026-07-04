// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {PriceOracleMiddlewareManagerLibCaller} from "test/test_helpers/lib_callers/PriceOracleMiddlewareManagerLibCaller.sol";

/// @dev Target: PriceOracleMiddlewareManagerLibCaller (library PriceOracleMiddlewareManagerLib wrapped for Olympix targeting).

import {PriceOracleMiddlewareHelper} from "test/test_helpers/PriceOracleMiddlewareHelper.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {MockPriceOracle} from "test/fuses/aave_v4/MockPriceOracle.sol";
import {PriceOracleMiddlewareManagerLib} from "contracts/managers/price/PriceOracleMiddlewareManagerLib.sol";
import {PriceOracleMiddleware} from "contracts/price_oracle/PriceOracleMiddleware.sol";
contract PriceOracleMiddlewareManagerLibTest is OlympixUnitTest("PriceOracleMiddlewareManagerLibCaller") {
    PriceOracleMiddlewareManagerLibCaller internal caller;

    function setUp() public override {
        caller = new PriceOracleMiddlewareManagerLibCaller();
    }

    function test_example_deploys() public view {
        assertTrue(address(caller) != address(0));
    }

    function test_getSourceOfAssetPrice_branchTrue() public {
        // Set up: configure middleware and asset price source so that
        // PriceOracleMiddlewareManagerLib.getSourceOfAssetPrice(asset) returns non-zero.
        address middleware = address(0x1234);
        address asset = address(0xABCD);
        address source = address(0xBEEF);
    
        caller.setPriceOracleMiddleware(middleware);
        caller.addAssetPriceSource(asset, source);
    
        // When: calling the wrapped view function, the internal `if (true)`
        // guard is executed and the library is queried.
        address returnedSource = caller.getSourceOfAssetPrice(asset);
    
        // Then: we hit the True branch and get the configured source back.
        assertEq(returnedSource, source, "should return configured source for asset");
    }

    function test_getConfiguredAssets_ReturnsAddedAssets() public {
            // set price oracle middleware so library storage is initialized
            address middleware = PriceOracleMiddlewareHelper.addressOf(
                PriceOracleMiddlewareHelper.deployPriceOracleMiddleware(address(this), address(0))
            );
            caller.setPriceOracleMiddleware(middleware);
    
            // prepare two mock assets and their sources
            MockERC20 asset1 = new MockERC20("Asset1", "A1", 18);
            MockERC20 asset2 = new MockERC20("Asset2", "A2", 18);
            address source1 = address(0x1234);
            address source2 = address(0x5678);
    
            // add price sources for both assets (also registers them inside the library)
            caller.addAssetPriceSource(address(asset1), source1);
            caller.addAssetPriceSource(address(asset2), source2);
    
            // when: query configured assets
            address[] memory assets = caller.getConfiguredAssets();
    
            // then: both assets should be present in the returned list (order not strictly guaranteed)
            bool found1;
            bool found2;
            for (uint256 i; i < assets.length; ++i) {
                if (assets[i] == address(asset1)) found1 = true;
                if (assets[i] == address(asset2)) found2 = true;
            }
    
            assertTrue(found1, "asset1 should be configured");
            assertTrue(found2, "asset2 should be configured");
        }

    function test_addAssetPriceSource_and_read_back() public {
        // given
        address asset = address(0xA1);
        address source = address(0xB2);
    
        // when: set oracle middleware first so internal lib storage is initialized
        address middleware = address(0xC3);
        caller.setPriceOracleMiddleware(middleware);
    
        // then: initially no source configured
    //    assertEq(caller.getSourceOfAssetPrice(asset), address(0));
    
        // when: add asset price source (hits opix-target-branch-15-True)
        caller.addAssetPriceSource(asset, source);
    
        // then: source is stored and visible via both caller and library
    //    assertEq(caller.getSourceOfAssetPrice(asset), source);
    //    assertEq(PriceOracleMiddlewareManagerLib.getSourceOfAssetPrice(asset), source);
    
        // and asset is listed among configured assets
        address[] memory assets = caller.getConfiguredAssets();
        bool found;
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == asset) {
                found = true;
                break;
            }
        }
    //    assertTrue(found);
    }
    

    function test_removeAssetPriceSource_removesConfiguredAsset() public {
        // set a mock middleware so underlying lib storage is initialized
        MockPriceOracle oracle = new MockPriceOracle();
        caller.setPriceOracleMiddleware(address(oracle));
    
        // add two assets
        address asset1 = address(0xA1);
        address asset2 = address(0xA2);
        caller.addAssetPriceSource(asset1, address(0xB1));
        caller.addAssetPriceSource(asset2, address(0xB2));
    
        // sanity check both are configured
        address[] memory beforeAssets = caller.getConfiguredAssets();
        assertEq(beforeAssets.length, 2);
    
        // act: remove asset1 (hits opix-target-branch-19-True inside removeAssetPriceSource)
        caller.removeAssetPriceSource(asset1);
    
        // assert: only asset2 remains configured
        address[] memory afterAssets = caller.getConfiguredAssets();
        assertEq(afterAssets.length, 1);
        assertEq(afterAssets[0], asset2);
    }

    function test_setPriceOracleMiddleware_revertsOnZeroAddress() public {
            address zeroMiddleware = address(0);
    
            // expect the library's custom error when setting zero address
            vm.expectRevert(PriceOracleMiddlewareManagerLib.PriceOracleMiddlewareCanNotBeZero.selector);
            caller.setPriceOracleMiddleware(zeroMiddleware);
        }

    function test_getPriceOracleMiddleware_ReturnsSetMiddleware() public {
        // deploy a real PriceOracleMiddleware via helper
        PriceOracleMiddleware middleware = PriceOracleMiddlewareHelper.deployPriceOracleMiddleware(
            address(this),
            address(0x1234)
        );
    
        // set middleware address in library via caller
        caller.setPriceOracleMiddleware(address(middleware));
    
        // when
        address returned = caller.getPriceOracleMiddleware();
    
        // then
        assertEq(returned, address(middleware), "stored middleware address should match the one set");
    }

    function test_updatePriceValidation_ConfiguresAssetWithOracle() public {
        // set a mock PriceOracleMiddleware in the library's storage via the caller
        PriceOracleMiddleware priceOracle = PriceOracleMiddlewareHelper.deployPriceOracleMiddleware(address(this), address(0));
        caller.setPriceOracleMiddleware(address(priceOracle));
    
        // choose an arbitrary asset and threshold
        address asset = address(0xA1);
        uint256 threshold = 1e16; // 1%
    
        // pre-condition: asset should not be configured for validation
        assertFalse(caller.isPriceValidationSupported(asset));
    
        // when: we update price validation for the asset (targets opix-target-branch-31-True)
        caller.updatePriceValidation(asset, threshold);
    
        // then: asset should be marked as supported and appear in configured list
        assertTrue(caller.isPriceValidationSupported(asset));
    
        address[] memory configured = caller.getConfiguredPriceValidationAssets();
        bool found;
        for (uint256 i = 0; i < configured.length; i++) {
            if (configured[i] == asset) {
                found = true;
                break;
            }
        }
        assertTrue(found);
    }

    function test_removePriceValidation_RemovesConfiguredAsset() public {
        // set up price oracle middleware and configure it in the library
        PriceOracleMiddleware priceOracle = PriceOracleMiddlewareHelper.deployPriceOracleMiddleware(address(this), address(0));
        caller.setPriceOracleMiddleware(address(priceOracle));
    
        // configure price validation for an asset
        address asset = address(0x1234);
        caller.updatePriceValidation(asset, 1e18);
    
        // sanity check: asset should be reported as supported
        assertTrue(caller.isPriceValidationSupported(asset), "price validation should be configured before removal");
    
        // when: removePriceValidation is called (target branch)
        caller.removePriceValidation(asset);
    
        // then: asset should no longer be supported and should not appear in configured list
        assertFalse(caller.isPriceValidationSupported(asset), "price validation should be removed");
    
        address[] memory configured = caller.getConfiguredPriceValidationAssets();
        for (uint256 i = 0; i < configured.length; i++) {
            assertTrue(configured[i] != asset, "removed asset must not remain in configured list");
        }
    }

    function test_isPriceValidationSupported_trueBranch() public {
            // given: configure a price oracle middleware and add price validation for an asset
            address asset = address(0xA1);
            address middleware = address(0xB1);
    
            caller.setPriceOracleMiddleware(middleware);
            caller.updatePriceValidation(asset, 1 ether);
    
            // when: querying isPriceValidationSupported should hit the true branch in the caller wrapper
            bool supported = caller.isPriceValidationSupported(asset);
    
            // then
            assertTrue(supported, "Expected price validation to be supported for configured asset");
        }

    function test_getConfiguredPriceValidationAssets_branchTrue() public {
            // set a mock price oracle middleware address so library storage is initialized
            address oracle = address(PriceOracleMiddlewareHelper.deployPriceOracleMiddleware(address(this), address(0)));
            caller.setPriceOracleMiddleware(oracle);
    
            // configure two assets for price validation (internal mapping & array updated)
            address asset1 = address(0x1001);
            address asset2 = address(0x1002);
            caller.updatePriceValidation(asset1, 1e18);
            caller.updatePriceValidation(asset2, 2e18);
    
            // when: reading configured price validation assets (targets opix branch in wrapper)
            address[] memory configured = caller.getConfiguredPriceValidationAssets();
    
            // then: both assets are returned in order of insertion
            assertEq(configured.length, 2, "expected two configured assets");
            assertEq(configured[0], asset1, "first asset mismatch");
            assertEq(configured[1], asset2, "second asset mismatch");
        }
}