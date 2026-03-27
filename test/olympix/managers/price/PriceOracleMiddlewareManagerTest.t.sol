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

    function skiptest_validateAllAssetsPrices_UsesConfiguredAssetsAndElseBranch_opix_target_branch_221_true() public {
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

    function skiptest_validateAssetsPrices_NonEmptyArray_hitsElseBranch_opix_target_branch_241_true() public {
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

    function test_getPriceOracleMiddleware_ReturnsStoredAddress_opix_target_branch_142_true() public {
            // Arrange: deploy AccessManager authority
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);
    
            // Deploy mock middleware and manager
            MockPriceOracle mockOracle = new MockPriceOracle();
            address middleware = address(mockOracle);
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(
                address(accessManager),
                middleware
            );
    
            // Act: read the middleware address via the getter
            address returned = manager.getPriceOracleMiddleware();
    
            // Assert: it should match what was set during initialization
            assertEq(returned, middleware, "PriceOracleMiddleware address mismatch");
        }

    function test_getSourceOfAssetPrice_UsesLibraryAndReturnsConfiguredSource_opix_target_branch_151_true() public {
            // Arrange: deploy AccessManager authority
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);

            // Deploy a non-zero middleware (MockPriceOracle implements IPriceOracleMiddleware)
            MockPriceOracle mockOracle = new MockPriceOracle();

            // Deploy manager with AccessManager as authority and mock oracle as middleware
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(
                address(accessManager),
                address(mockOracle)
            );

            // Grant permission to call setAssetsPriceSources
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = PriceOracleMiddlewareManager.setAssetsPriceSources.selector;
            accessManager.setTargetFunctionRole(address(manager), selectors, 0);
            accessManager.grantRole(0, address(this), 0);

            // Configure a price source via the manager's external function
            address asset = address(0xABCD);
            address source = address(0xDEAD);
            address[] memory assets = new address[](1);
            address[] memory sources = new address[](1);
            assets[0] = asset;
            sources[0] = source;
            manager.setAssetsPriceSources(assets, sources);

            // Act: call the view function
            address returnedSource = manager.getSourceOfAssetPrice(asset);

            // Assert: it should return the same source we configured
            assertEq(returnedSource, source, "getSourceOfAssetPrice should return configured source");
        }

    function test_getConfiguredAssets_ReturnsFromLib_opix_target_branch_159_true() public {
            // Arrange: deploy manager with real AccessManager and valid middleware
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);
            MockPriceOracle mockOracle = new MockPriceOracle();
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(address(accessManager), address(mockOracle));

            // Grant permission to call setAssetsPriceSources
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = PriceOracleMiddlewareManager.setAssetsPriceSources.selector;
            accessManager.setTargetFunctionRole(address(manager), selectors, 0);
            accessManager.grantRole(0, address(this), 0);

            // Configure assets via the manager's external function
            address[] memory assets = new address[](2);
            address[] memory sources = new address[](2);
            assets[0] = address(0xA1);
            assets[1] = address(0xA2);
            sources[0] = address(0xB1);
            sources[1] = address(0xB2);
            manager.setAssetsPriceSources(assets, sources);

            // Act: call getConfiguredAssets
            address[] memory configured = manager.getConfiguredAssets();

            // Assert: we get back the two assets we configured
            assertEq(configured.length, 2, "configured assets length");
            assertEq(configured[0], assets[0], "first configured asset");
            assertEq(configured[1], assets[1], "second configured asset");
        }

    function test_updatePriceValidation_NonEmptyEqualLengthArrays_hitsElseBranch_opix_target_branch_176_false() public {
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
    
            // Prepare NON-empty, equal-length arrays so:
            // - assetsLength == 0 is FALSE (takes the else branch at opix-target-branch-169-False)
            // - assetsLength != maxPricesDelta_.length is FALSE (takes the else branch at opix-target-branch-176-False)
            address[] memory assets = new address[](2);
            uint256[] memory maxDeltas = new uint256[](2);
            assets[0] = address(0xA1);
            assets[1] = address(0xA2);
            maxDeltas[0] = 1e17; // 10%
            maxDeltas[1] = 2e17; // 20%
    
            // Act: should execute without revert and hit the `else { assert(true); }` branch
            manager.updatePriceValidation(assets, maxDeltas);
    
            // Assert: basic sanity - configurations are stored in the lib
            (uint256 storedMaxDelta0,,) = manager.getPriceValidationInfo(assets[0]);
            (uint256 storedMaxDelta1,,) = manager.getPriceValidationInfo(assets[1]);
            assertEq(storedMaxDelta0, maxDeltas[0], "max delta for asset 0 should be stored");
            assertEq(storedMaxDelta1, maxDeltas[1], "max delta for asset 1 should be stored");
        }

    function test_validateAllAssetsPrices_NonEmptyConfiguredAssets_ElseBranch_opix_target_branch_221_true() public {
            // Arrange: set up AccessManager authority so `restricted` passes
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);

            // Deploy a MockPriceOracle as middleware with valid prices
            MockPriceOracle middleware = new MockPriceOracle();

            // Deploy manager with AccessManager as authority and the mock middleware
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(
                address(accessManager),
                address(middleware)
            );

            // Grant this test contract permission to call updatePriceValidation and validateAllAssetsPrices
            bytes4[] memory selectors = new bytes4[](2);
            selectors[0] = PriceOracleMiddlewareManager.updatePriceValidation.selector;
            selectors[1] = PriceOracleMiddlewareManager.validateAllAssetsPrices.selector;
            uint64 roleId = 0;
            accessManager.setTargetFunctionRole(address(manager), selectors, roleId);
            accessManager.grantRole(roleId, address(this), 0);

            // Configure a valid price on the middleware so _getAssetPrice succeeds
            address asset = address(0xAA);
            middleware.setAssetPriceWithDecimals(asset, 1e18, 18);

            // Configure one asset for price validation so assetsLength > 0 and we enter the else-branch
            address[] memory assets = new address[](1);
            assets[0] = asset;
            uint256[] memory maxDeltas = new uint256[](1);
            maxDeltas[0] = 1e17; // 10%

            manager.updatePriceValidation(assets, maxDeltas);

            // Act: call validateAllAssetsPrices; since configured assets length > 0,
            // the `if (assetsLength == 0)` condition is FALSE and the opix-target-branch-221 else-branch is executed
            manager.validateAllAssetsPrices();
        }

    function test_validateAssetsPrices_NonEmptyArray_hitsElseBranch_opix_target_branch_241_false() public {
            // Arrange: deploy AccessManager authority
            IporFusionAccessManager accessManager = new IporFusionAccessManager(address(this), 0);

            // Deploy middleware and manager with AccessManager as authority
            MockPriceOracle middleware = new MockPriceOracle();
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(address(accessManager), address(middleware));

            // Grant roles for validateAssetsPrices and updatePriceValidation
            bytes4[] memory selectors = new bytes4[](2);
            selectors[0] = PriceOracleMiddlewareManager.validateAssetsPrices.selector;
            selectors[1] = PriceOracleMiddlewareManager.updatePriceValidation.selector;
            accessManager.setTargetFunctionRole(address(manager), selectors, 0);
            accessManager.grantRole(0, address(this), 0);

            // Configure a single asset price so _getAssetPrice succeeds
            address asset = address(0xA1);
            middleware.setAssetPriceWithDecimals(asset, 1e18, 18);

            // Configure price validation for the asset
            address[] memory assets = new address[](1);
            assets[0] = asset;
            uint256[] memory maxDeltas = new uint256[](1);
            maxDeltas[0] = 1e17; // 10%
            manager.updatePriceValidation(assets, maxDeltas);

            // Act: should run without reverting and hit the else branch
            manager.validateAssetsPrices(assets);
        }

    function test_getAssetsPrices_NonEmptyArray_EntersElseBranch_opix_target_branch_277_false() public {
            // Arrange: deploy manager with non-zero authority and valid middleware
            address dummyAuthority = address(0x1);
            MockPriceOracle mockOracle = new MockPriceOracle();
            PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(dummyAuthority, address(mockOracle));
    
            // Configure a single asset price so _getAssetPrice succeeds inside getAssetsPrices
            address asset = address(0xA1);
            // Set a positive price with 18 decimals so no further conversion is needed
            mockOracle.setAssetPriceWithDecimals(asset, 1e18, 18);
    
            // Prepare NON-empty assets array so `assetsLength == 0` is FALSE
            address[] memory assets = new address[](1);
            assets[0] = asset;
    
            // Act: call getAssetsPrices with non-empty array, which should
            // make the `if (assetsLength == 0)` condition false and enter
            // the `else { assert(true); }` branch at opix-target-branch-277.
            (uint256[] memory prices, uint256[] memory decimalsList) = manager.getAssetsPrices(assets);
    
            // Assert: returned arrays have one element and contain the configured price
            assertEq(prices.length, 1, "prices length");
            assertEq(decimalsList.length, 1, "decimals length");
            assertEq(prices[0], 1e18, "asset price");
            assertEq(decimalsList[0], 18, "asset price decimals");
        }
}