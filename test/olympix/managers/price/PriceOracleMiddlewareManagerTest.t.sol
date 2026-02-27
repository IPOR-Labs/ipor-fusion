// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {PriceOracleMiddlewareManager} from "../../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";

import {MockPriceOracle} from "test/fuses/aave_v4/MockPriceOracle.sol";
import {IporFusionAccessManager} from "contracts/managers/access/IporFusionAccessManager.sol";
import {PriceOracleMiddlewareManager} from "contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
import {PriceOracleMiddlewareManagerLib} from "contracts/managers/price/PriceOracleMiddlewareManagerLib.sol";
import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {IPriceFeed} from "contracts/price_oracle/price_feed/IPriceFeed.sol";
import {IporMath} from "contracts/libraries/math/IporMath.sol";
contract PriceOracleMiddlewareManagerTest is OlympixUnitTest("PriceOracleMiddlewareManager") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_initialize_RevertWhenInitialAuthorityZero_opix_target_branch_70_true() public {
            // Arrange: zero authority to trigger InvalidAuthority in _initialize
            address initialAuthority = address(0);
            MockPriceOracle mockOracle = new MockPriceOracle();
            address middleware = address(mockOracle);
    
            // Act & Assert: constructor should revert with InvalidAuthority
            vm.expectRevert(PriceOracleMiddlewareManager.InvalidAuthority.selector);
            new PriceOracleMiddlewareManager(initialAuthority, middleware);
        }

    function test_initialize_RevertWhenPriceOracleMiddlewareZero_opix_target_branch_76_true() public {
            // Arrange: valid non-zero authority, zero middleware to trigger InvalidPriceOracleMiddleware
            address initialAuthority = address(0xA1);
            address zeroMiddleware = address(0);
    
            // Act & Assert: constructor should revert with InvalidPriceOracleMiddleware
            vm.expectRevert(PriceOracleMiddlewareManager.InvalidPriceOracleMiddleware.selector);
            new PriceOracleMiddlewareManager(initialAuthority, zeroMiddleware);
        }

    function test_setAssetsPriceSources_RevertOnEmptyAssetsArray_opix_target_branch_96_true() public {
            // Arrange: deploy a real AccessManager authority so `restricted` checks can pass
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);
    
            // Deploy a mock middleware and the manager using that AccessManager as authority
            MockPriceOracle mockOracle = new MockPriceOracle();
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(
                address(accessManager),
                address(mockOracle)
            );
    
            // Grant this test contract permission to call setAssetsPriceSources via AccessManager
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = PriceOracleMiddlewareManager.setAssetsPriceSources.selector;
            uint64 roleId = 0;
            accessManager.setTargetFunctionRole(address(manager), selectors, roleId);
            accessManager.grantRole(roleId, address(this), 0);
    
            // Prepare EMPTY arrays to trigger the `assetsLength == 0` branch
            address[] memory assets = new address[](0);
            address[] memory sources = new address[](0);
    
            // Act & Assert: expect the custom EmptyArrayNotSupported error when assets_.length == 0
            vm.expectRevert(PriceOracleMiddlewareManager.EmptyArrayNotSupported.selector);
            manager.setAssetsPriceSources(assets, sources);
        }

    function test_setAssetsPriceSources_NonEmptyArrays_EntersElseBranch_opix_target_branch_98_false() public {
            // Arrange: deploy a real AccessManager authority so `restricted` checks can pass
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);
    
            // Deploy a mock middleware and the manager using that AccessManager as authority
            MockPriceOracle mockOracle = new MockPriceOracle();
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(
                address(accessManager),
                address(mockOracle)
            );
    
            // Grant this test contract permission to call setAssetsPriceSources via AccessManager
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = PriceOracleMiddlewareManager.setAssetsPriceSources.selector;
            uint64 roleId = 0;
            accessManager.setTargetFunctionRole(address(manager), selectors, roleId);
            accessManager.grantRole(roleId, address(this), 0);
    
            // Prepare non-empty, matching-length arrays so `assetsLength == 0` is false
            address[] memory assets = new address[](1);
            address[] memory sources = new address[](1);
            assets[0] = address(0x1);
            sources[0] = address(0x2);
    
            // Act: call the function; it should not revert and should enter the `else { assert(true); }` branch
            manager.setAssetsPriceSources(assets, sources);
        }

    function test_setAssetsPriceSources_ArrayLengthMismatch_opix_target_branch_101_true() public {
            // Arrange: deploy AccessManager authority
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);
    
            // Deploy a non-zero middleware (mock oracle implements IPriceOracleMiddleware)
            MockPriceOracle mockOracle = new MockPriceOracle();
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(
                address(accessManager),
                address(mockOracle)
            );
    
            // Grant this test contract permission to call setAssetsPriceSources via AccessManager
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = PriceOracleMiddlewareManager.setAssetsPriceSources.selector;
            uint64 roleId = 0;
            accessManager.setTargetFunctionRole(address(manager), selectors, roleId);
            accessManager.grantRole(roleId, address(this), 0);
    
            // Prepare mismatched arrays so `assetsLength != sourcesLength` is TRUE
            address[] memory assets = new address[](2);
            assets[0] = address(0xA1);
            assets[1] = address(0xA2);
    
            address[] memory sources = new address[](1);
            sources[0] = address(0xB1);
    
            // Act & Assert: expect ArrayLengthMismatch revert hitting opix-target-branch-101-True
            vm.expectRevert(PriceOracleMiddlewareManager.ArrayLengthMismatch.selector);
            manager.setAssetsPriceSources(assets, sources);
        }

    function test_removeAssetsPriceSources_revertsOnEmptyArray_opix_branch_119_true() public {
            // Arrange: deploy a real AccessManager authority so `restricted` checks can pass
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);
    
            // Deploy manager with that AccessManager as authority
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(
                address(accessManager),
                address(0x1234)
            );
    
            // Grant caller permission to call removeAssetsPriceSources via AccessManager
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = PriceOracleMiddlewareManager.removeAssetsPriceSources.selector;
            accessManager.setTargetFunctionRole(address(manager), selectors, 0);
            accessManager.grantRole(0, address(this), 0);
    
            // Act & Assert: with empty array we should hit the branch `if (assetsLength == 0)` and revert
            vm.expectRevert(PriceOracleMiddlewareManager.EmptyArrayNotSupported.selector);
            address[] memory emptyAssets = new address[](0);
            manager.removeAssetsPriceSources(emptyAssets);
        }

    function test_removeAssetsPriceSources_NonEmptyArray_hitsElseBranch_opix_target_branch_121_true() public {
            // Arrange: deploy a real AccessManager so `restricted` checks can pass
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);
    
            // Deploy a mock price oracle middleware (implementation details not important for this branch)
            MockPriceOracle mockOracle = new MockPriceOracle();
    
            // Deploy manager with that AccessManager as authority and mock oracle as middleware
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(
                address(accessManager),
                address(mockOracle)
            );
    
            // Grant caller permission to call setAssetsPriceSources and removeAssetsPriceSources via AccessManager
            bytes4[] memory selectors = new bytes4[](2);
            selectors[0] = PriceOracleMiddlewareManager.setAssetsPriceSources.selector;
            selectors[1] = PriceOracleMiddlewareManager.removeAssetsPriceSources.selector;
            accessManager.setTargetFunctionRole(address(manager), selectors, 0);
            accessManager.grantRole(0, address(this), 0);
    
            // Configure a dummy asset/source so the removal loop has something to process
            address[] memory assets = new address[](1);
            address[] memory sources = new address[](1);
            assets[0] = address(0x1234);
            sources[0] = address(0x5678);
    
            vm.startPrank(address(this));
            manager.setAssetsPriceSources(assets, sources);
    
            // Act: call removeAssetsPriceSources with NON-empty array so
            // `if (assetsLength == 0)` is false and the ELSE branch is entered
            manager.removeAssetsPriceSources(assets);
            vm.stopPrank();
    
            // Assert: source mapping should be cleared
            address sourceAfter = PriceOracleMiddlewareManagerLib.getSourceOfAssetPrice(assets[0]);
            assertEq(sourceAfter, address(0), "source should be removed");
        }

    function test_updatePriceValidation_RevertOnEmptyArray_opix_target_branch_169_true() public {
            // Arrange: deploy a real AccessManager authority so `restricted` checks can pass
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);
    
            // Dummy non-zero middleware implementing IPriceOracleMiddleware interface
            IPriceOracleMiddleware dummyMiddleware = IPriceOracleMiddleware(address(0x2));
    
            // Deploy manager with AccessManager as authority and dummy middleware
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(
                address(accessManager),
                address(dummyMiddleware)
            );
    
            // Grant this test contract permission to call updatePriceValidation via AccessManager
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = PriceOracleMiddlewareManager.updatePriceValidation.selector;
            accessManager.setTargetFunctionRole(address(manager), selectors, 0);
            accessManager.grantRole(0, address(this), 0);
    
            // Act & Assert: calling with empty arrays should hit opix-target-branch-169-True and revert
            vm.expectRevert(PriceOracleMiddlewareManager.EmptyArrayNotSupported.selector);
            manager.updatePriceValidation(new address[](0), new uint256[](0));
        }

    function test_updatePriceValidation_ArrayLengthMismatch_opix_target_branch_174_true() public {
            // Arrange: deploy AccessManager authority
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);
    
            // Deploy a non-zero middleware (mock oracle implements IPriceOracleMiddleware)
            MockPriceOracle mockOracle = new MockPriceOracle();
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(
                address(accessManager),
                address(mockOracle)
            );
    
            // Grant this test contract permission to call updatePriceValidation via AccessManager
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = PriceOracleMiddlewareManager.updatePriceValidation.selector;
            uint64 roleId = 0;
            accessManager.setTargetFunctionRole(address(manager), selectors, roleId);
            accessManager.grantRole(roleId, address(this), 0);
    
            // Prepare mismatched arrays: assets_.length = 2, maxPricesDelta_.length = 1
            address[] memory assets = new address[](2);
            assets[0] = address(0xA1);
            assets[1] = address(0xA2);
    
            uint256[] memory maxDeltas = new uint256[](1);
            maxDeltas[0] = 1e17; // 10%
    
            // Act & Assert: should hit `if (assetsLength != maxPricesDelta_.length)` and revert
            vm.expectRevert(PriceOracleMiddlewareManager.ArrayLengthMismatch.selector);
            manager.updatePriceValidation(assets, maxDeltas);
        }

    function test_removePriceValidation_RevertOnEmptyArray_opix_target_branch_188_true() public {
            // Arrange: deploy a real AccessManager authority so `restricted` checks can pass
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);
    
            // Deploy a mock price oracle middleware (non-zero address)
            MockPriceOracle mockOracle = new MockPriceOracle();
    
            // Deploy manager with AccessManager as authority and mock oracle as middleware
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(
                address(accessManager),
                address(mockOracle)
            );
    
            // Grant this test contract permission to call removePriceValidation via AccessManager
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = PriceOracleMiddlewareManager.removePriceValidation.selector;
            uint64 roleId = 0;
            accessManager.setTargetFunctionRole(address(manager), selectors, roleId);
            accessManager.grantRole(roleId, address(this), 0);
    
            // Act & Assert: calling with an empty array should hit opix-target-branch-188-True
            // and revert with EmptyArrayNotSupported
            address[] memory emptyAssets = new address[](0);
            vm.expectRevert(PriceOracleMiddlewareManager.EmptyArrayNotSupported.selector);
            manager.removePriceValidation(emptyAssets);
        }

    function test_removePriceValidation_NonEmptyArray_hitsElseBranch_opix_target_branch_190_false() public {
            // Arrange: deploy a real AccessManager so `restricted` checks can pass
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);
    
            // Deploy a mock price oracle middleware (just needs to be non-zero and valid)
            MockPriceOracle mockOracle = new MockPriceOracle();
    
            // Deploy manager with that AccessManager as authority and mock oracle as middleware
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(
                address(accessManager),
                address(mockOracle)
            );
    
            // Grant caller permission to call removePriceValidation via AccessManager
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = PriceOracleMiddlewareManager.removePriceValidation.selector;
            // Use roleId 0 for simplicity
            accessManager.setTargetFunctionRole(address(manager), selectors, 0);
            accessManager.grantRole(0, address(this), 0);
    
            // Prepare a NON-empty assets array so `assetsLength == 0` is false
            address[] memory assets = new address[](1);
            assets[0] = address(0xA);
    
            // Act: call removePriceValidation with non-empty array
            // This makes the `if (assetsLength == 0)` condition false, so the
            // opix-target-branch-190 else-branch is executed.
            manager.removePriceValidation(assets);
        }

    function test_validateAllAssetsPrices_EmptyConfiguredAssets_TakesEarlyReturnBranch_opix_target_branch_219_true() public {
            // Arrange: deploy a real AccessManager authority so `restricted` checks can pass
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);
    
            // Deploy manager with that AccessManager as authority and a non-zero middleware address
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(
                address(accessManager),
                address(0x1234)
            );
    
            // Configure AccessManager so this test contract can call the restricted function
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = PriceOracleMiddlewareManager.validateAllAssetsPrices.selector;
            accessManager.setTargetFunctionRole(address(manager), selectors, 0);
            accessManager.grantRole(0, address(this), 0);
    
            // Sanity: there should be no configured price validation assets, so internal assets array will be empty
            address[] memory initiallyConfigured = manager.getConfiguredPriceValidationAssets();
            assertEq(initiallyConfigured.length, 0);
    
            // Act: call validateAllAssetsPrices. With assetsLength == 0 it should take the early-return
            // branch at line marked opix-target-branch-219-True and not revert.
            manager.validateAllAssetsPrices();
        }

    function test_validateAllAssetsPrices_UsesConfiguredAssetsAndElseBranch_opix_target_branch_221_true() public {
            // Arrange: set up a real AccessManager authority so `restricted` passes
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);
    
            // Deploy middleware and manager
            PriceOracleMiddlewareMock middleware = new PriceOracleMiddlewareMock(address(0x1234), 18, address(0));
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(address(accessManager), address(middleware));
    
            // Configure AccessManager so this test contract can call the restricted functions
            bytes4[] memory selectors = new bytes4[](3);
            selectors[0] = PriceOracleMiddlewareManager.updatePriceValidation.selector;
            selectors[1] = PriceOracleMiddlewareManager.validateAllAssetsPrices.selector;
            selectors[2] = PriceOracleMiddlewareManager.getConfiguredPriceValidationAssets.selector;
            // roleId 0 is arbitrary here
            accessManager.setTargetFunctionRole(address(manager), selectors, 0);
            accessManager.grantRole(0, address(this), 0);
    
            // Configure one asset for price validation so assetsLength > 0
            address asset = address(0xAA);
            address[] memory assets = new address[](1);
            assets[0] = asset;
            uint256[] memory maxDeltas = new uint256[](1);
            maxDeltas[0] = 1e17; // 10%
    
            manager.updatePriceValidation(assets, maxDeltas);
    
            // Configure middleware source and a non‑zero price so validation logic runs
            address[] memory sources = new address[](1);
            sources[0] = address(0); // PriceOracleMiddlewareMock ignores this
            middleware.setAssetsPricesSources(assets, sources);
    
            // Act: call validateAllAssetsPrices
            // Since configured assets length > 0, the `if (assetsLength == 0)` check is FALSE
            // and execution enters the `else` branch marked by opix-target-branch-221.
            manager.validateAllAssetsPrices();
    
            // Assert: basic sanity check that the configured assets array is indeed non-empty
            address[] memory configured = manager.getConfiguredPriceValidationAssets();
            assertEq(configured.length, 1);
            assertEq(configured[0], asset);
        }

    function test_validateAssetsPrices_EmptyArrayReturnsEarly_opix_target_branch_239_true() public {
            // Arrange: deploy AccessManager authority and mock oracle
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);
            MockPriceOracle mockOracle = new MockPriceOracle();
    
            // Deploy manager with AccessManager as authority
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(
                address(accessManager),
                address(mockOracle)
            );
    
            // Grant a role and bind it to validateAssetsPrices on the manager so restricted() passes
            uint64 roleId = 1;
            accessManager.grantRole(roleId, address(this), 0);
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = PriceOracleMiddlewareManager.validateAssetsPrices.selector;
            accessManager.setTargetFunctionRole(address(manager), selectors, roleId);
    
            // Act: call with empty array so assetsLength == 0 and early-return branch is taken
            address[] memory emptyAssets = new address[](0);
            manager.validateAssetsPrices(emptyAssets);
        }

    function test_validateAssetsPrices_NonEmptyArray_hitsElseBranch_opix_target_branch_241_true() public {
            // Arrange: deploy AccessManager authority and grant this test full access
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);
    
            // Role 0 is super-admin in IporFusionAccessManager; grant it to this test
            accessManager.grantRole(0, address(this), 0);
    
            // Allow this test to call validateAssetsPrices on the manager via AccessManager
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = PriceOracleMiddlewareManager.validateAssetsPrices.selector;
            accessManager.setTargetFunctionRole(address(this), selectors, 0);
    
            // Deploy middleware and manager with AccessManager as authority
            MockPriceOracle middleware = new MockPriceOracle();
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(address(accessManager), address(middleware));
    
            // Now wire AccessManager permission for the *manager* target instead of this test contract
            selectors[0] = PriceOracleMiddlewareManager.validateAssetsPrices.selector;
            accessManager.setTargetFunctionRole(address(manager), selectors, 0);
    
            // Configure a single asset price so _getAssetPrice succeeds
            address asset = address(0xA1);
            middleware.setAssetPriceWithDecimals(asset, 1e8, 8); // price > 0, 8 decimals
    
            address[] memory assets = new address[](1);
            assets[0] = asset;
    
            // Act: non-empty array => assetsLength != 0, we take the `else` branch of `if (assetsLength == 0)`
            manager.validateAssetsPrices(assets);
            // Assert: reaching here without revert means the else-branch was executed successfully
        }

    function test_getAssetsPrices_RevertsOnEmptyArray_opix_target_branch_275_true() public {
            // Deploy a minimal manager instance using the same constructor pattern as production
            // Note: initialAuthority just needs to be a non-zero address; middleware also non-zero
            address dummyAuthority = address(0x1);
            address dummyMiddleware = address(0x2);
    
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(dummyAuthority, dummyMiddleware);
    
            address[] memory emptyAssets = new address[](0);
    
            vm.expectRevert(PriceOracleMiddlewareManager.EmptyArrayNotSupported.selector);
            manager.getAssetsPrices(emptyAssets);
        }

    function test_getAssetPrice_RevertOnZeroAssetAddress_opix_target_branch_299_true() public {
            // Arrange: deploy AccessManager authority so `restricted` checks (if any) could pass
            address dummyAuthority = address(0x1);
    
            // Deploy a non-zero middleware (MockPriceOracle implements IPriceOracleMiddleware)
            MockPriceOracle mockOracle = new MockPriceOracle();
    
            // Deploy manager with non-zero authority and middleware so constructor does not revert
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(
                dummyAuthority,
                address(mockOracle)
            );
    
            // Act & Assert: calling getAssetPrice with asset_ == address(0) should hit
            // the `if (asset_ == address(0))` branch and revert with UnsupportedAsset
            vm.expectRevert(PriceOracleMiddlewareManager.UnsupportedAsset.selector);
            manager.getAssetPrice(address(0));
        }
}