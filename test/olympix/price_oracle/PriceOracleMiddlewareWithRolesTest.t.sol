// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../test/OlympixUnitTest.sol";
import {PriceOracleMiddlewareWithRoles} from "../../../contracts/price_oracle/PriceOracleMiddlewareWithRoles.sol";

import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PriceOracleMiddlewareWithRoles} from "contracts/price_oracle/PriceOracleMiddlewareWithRoles.sol";
import {IporFusionAccessControl} from "contracts/price_oracle/IporFusionAccessControl.sol";
contract PriceOracleMiddlewareWithRolesTest is OlympixUnitTest("PriceOracleMiddlewareWithRoles") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_getAssetsPrices_RevertsOnEmptyArray_opix_target_branch_103_true() public {
            // PriceOracleMiddlewareWithRoles is UUPS and must be called via proxy in production,
            // but its initialize function can be called on the implementation once in tests.
            PriceOracleMiddlewareWithRoles oracle = new PriceOracleMiddlewareWithRoles(address(0));
    
            // initialize was already invoked in the constructor chain (via UUPS/AccessControl initializer),
            // so calling it again would revert with InvalidInitialization. We don't need to reinitialize
            // for this negative test because getAssetsPrices only depends on the input array length
            // to hit the targeted branch.
    
            address[] memory assets = new address[](0);
    
            vm.expectRevert(IPriceOracleMiddleware.EmptyArrayNotSupported.selector);
            oracle.getAssetsPrices(assets);
        }

    function test_getAssetsPrices_NonEmptyArray_HitsElseBranch_opix_target_branch_105_false() public {
        // deploy implementation with Chainlink disabled
        PriceOracleMiddlewareWithRoles oracle = new PriceOracleMiddlewareWithRoles(address(0));
    
        // prepare non-empty array to avoid the revert and hit the `else` branch after the length check
        address[] memory assets = new address[](1);
        assets[0] = address(0x1);
    
        // getAssetsPrices will now proceed past the initial `if (assetsLength == 0)` check
        // and enter the annotated else-branch, but will eventually revert with UnsupportedAsset
        vm.expectRevert(IPriceOracleMiddleware.UnsupportedAsset.selector);
        oracle.getAssetsPrices(assets);
    }

    function test_getAssetPrice_RevertOnZeroAddress_opix_target_branch_240_true() public {
            // Deploy oracle with Chainlink disabled so only custom feeds are used
            PriceOracleMiddlewareWithRoles oracle = new PriceOracleMiddlewareWithRoles(address(0));
    
            // Call getAssetPrice with zero address to trigger the `if (asset_ == address(0))` branch
            vm.expectRevert(IPriceOracleMiddleware.UnsupportedAsset.selector);
            oracle.getAssetPrice(address(0));
        }

    function test_getAssetPrice_ChainlinkFallbackBranch_opix_target_branch_257_true() public {
            // Deploy oracle with a non-zero Chainlink registry address so fallback path is enabled
            address fakeRegistry = address(0x1234);
            PriceOracleMiddlewareWithRoles oracle = new PriceOracleMiddlewareWithRoles(fakeRegistry);

            // Mock the Chainlink registry call to revert so the try/catch catches it
            vm.mockCallRevert(fakeRegistry, bytes(""), bytes(""));

            // Use a non-zero asset address so that:
            // - asset_ == address(0) is false
            // - source == address(0) (no custom source configured)
            // - CHAINLINK_FEED_REGISTRY != address(0), so the `else` branch at line 257 is executed
            address asset = address(0xABCD);

            // The subsequent Chainlink call will fail and bubble up as UnsupportedAsset
            vm.expectRevert(IPriceOracleMiddleware.UnsupportedAsset.selector);
            oracle.getAssetPrice(asset);
        }
}