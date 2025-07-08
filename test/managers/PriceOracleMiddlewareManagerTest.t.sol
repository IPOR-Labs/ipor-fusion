// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, FeeConfig} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../contracts/vaults/PlasmaVault.sol";
import {IporFusionAccessManagerInitializerLibV1, InitializationData, DataForInitialization, PlasmaVaultAddress} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {FixedValuePriceFeed} from "../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";

import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {PriceOracleMiddlewareManagerLib} from "../../contracts/managers/price/PriceOracleMiddlewareManagerLib.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";

contract PriceOracleMiddlewareManagerTest is Test {
    address private constant _DAO = address(1111111);
    address private constant _OWNER = address(2222222);
    address private constant _ADMIN = address(3333333);
    address private constant _ATOMIST = address(4444444);
    address private constant _ALPHA = address(5555555);
    address private constant _USER = address(6666666);
    address private constant _GUARDIAN = address(7777777);
    address private constant _FUSE_MANAGER = address(8888888);
    address private constant _CLAIM_REWARDS = address(7777777);
    address private constant _TRANSFER_REWARDS_MANAGER = address(8888888);
    address private constant _CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER = address(9999999);
    address private constant _PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS = address(10101010);
    address private constant _PRICE_ORACLE_MIDDLEWARE_MANAGER2_ADDRESS = address(10101012);

    address private constant _USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address private constant _PRICE_ORACLE_MIDDLEWARE = 0xC9F32d65a278b012371858fD3cdE315B12d664c6;

    address private _accessManager;
    address private _withdrawManager;
    address private _plasmaVault;
    address private _priceOracleMiddlewareManager;

    function setUp() public {
        // Fork mainnet
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22238002);
        deployMinimalPlasmaVault();

        setupInitialRoles();
        (bool hasRole, uint32 delay) = IporFusionAccessManager(_accessManager).hasRole(
            Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE,
            _priceOracleMiddlewareManager
        );
    }

    function deployMinimalPlasmaVault() private returns (address) {
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);

        FeeConfig memory feeConfig = FeeConfigHelper.createZeroFeeConfig();

        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
        _withdrawManager = address(new WithdrawManager(_accessManager));

        _priceOracleMiddlewareManager = address(
            new PriceOracleMiddlewareManager(_accessManager, _PRICE_ORACLE_MIDDLEWARE)
        );

        PlasmaVaultInitData memory initData = PlasmaVaultInitData({
            assetName: "USDC Plasma Vault",
            assetSymbol: "USDC-PV",
            underlyingToken: _USDC,
            priceOracleMiddleware: _priceOracleMiddlewareManager,
            feeConfig: feeConfig,
            accessManager: _accessManager,
            plasmaVaultBase: address(new PlasmaVaultBase()),
            withdrawManager: _withdrawManager
        });

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(new PlasmaVault(initData));
        vm.stopPrank();

        return _plasmaVault;
    }

    function setupInitialRoles() public {
        address[] memory daos = new address[](1);
        daos[0] = _DAO;

        address[] memory admins = new address[](1);
        admins[0] = _ADMIN;

        address[] memory owners = new address[](1);
        owners[0] = _OWNER;

        address[] memory atomists = new address[](1);
        atomists[0] = _ATOMIST;

        address[] memory alphas = new address[](1);
        alphas[0] = _ALPHA;

        address[] memory guardians = new address[](1);
        guardians[0] = _GUARDIAN;

        address[] memory fuseManagers = new address[](1);
        fuseManagers[0] = _FUSE_MANAGER;

        address[] memory claimRewards = new address[](1);
        claimRewards[0] = _CLAIM_REWARDS;

        address[] memory transferRewardsManagers = new address[](1);
        transferRewardsManagers[0] = _TRANSFER_REWARDS_MANAGER;

        address[] memory configInstantWithdrawalFusesManagers = new address[](1);
        configInstantWithdrawalFusesManagers[0] = _CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER;

        address[] memory priceOracleMiddlewareManagers = new address[](2);
        priceOracleMiddlewareManagers[0] = _PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS;
        priceOracleMiddlewareManagers[1] = _PRICE_ORACLE_MIDDLEWARE_MANAGER2_ADDRESS;

        DataForInitialization memory data = DataForInitialization({
            isPublic: true,
            iporDaos: daos,
            admins: admins,
            owners: owners,
            atomists: atomists,
            alphas: alphas,
            whitelist: new address[](0),
            guardians: guardians,
            fuseManagers: fuseManagers,
            claimRewards: claimRewards,
            transferRewardsManagers: transferRewardsManagers,
            configInstantWithdrawalFusesManagers: configInstantWithdrawalFusesManagers,
            updateMarketsBalancesAccounts: new address[](0),
            updateRewardsBalanceAccounts: new address[](0),
            withdrawManagerRequestFeeManagers: new address[](0),
            withdrawManagerWithdrawFeeManagers: new address[](0),
            priceOracleMiddlewareManagers: priceOracleMiddlewareManagers,
            preHooksManagers: new address[](0),
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: address(0x123),
                withdrawManager: _withdrawManager,
                feeManager: FeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER(),
                contextManager: address(0x123),
                priceOracleMiddlewareManager: _priceOracleMiddlewareManager
            })
        });

        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);

        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).initialize(initializationData);
        vm.stopPrank();
    }

    function testIfRolesAreSet() public {
        (bool hasRolePriceOracleMiddlewareManager, uint32 delayPriceOracleMiddlewareManager) = IporFusionAccessManager(
            _accessManager
        ).hasRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, _PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS);
        assertTrue(hasRolePriceOracleMiddlewareManager, "PriceOracleMiddlewareManager should have role");

        (
            bool hasRolePriceOracleMiddlewareManager2,
            uint32 delayPriceOracleMiddlewareManager2
        ) = IporFusionAccessManager(_accessManager).hasRole(
                Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE,
                _PRICE_ORACLE_MIDDLEWARE_MANAGER2_ADDRESS
            );
        assertTrue(hasRolePriceOracleMiddlewareManager2, "PriceOracleMiddlewareManager2 should have role");

        (bool hasRoleWithdrawManager, uint32 delayWithdrawManager) = IporFusionAccessManager(_accessManager).hasRole(
            Roles.TECH_WITHDRAW_MANAGER_ROLE,
            _withdrawManager
        );
        assertTrue(hasRoleWithdrawManager, "WithdrawManager should have role");
    }

    function testSetAssetsPriceSources_Success() public {
        // Create test assets and price feeds
        address asset1 = address(0x123);
        address asset2 = address(0x456);

        FixedValuePriceFeed priceFeed1 = new FixedValuePriceFeed(1e18); // Price of 1
        FixedValuePriceFeed priceFeed2 = new FixedValuePriceFeed(2e18); // Price of 2

        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;

        address[] memory sources = new address[](2);
        sources[0] = address(priceFeed1);
        sources[1] = address(priceFeed2);

        // Set price sources
        vm.startPrank(_PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceSources(assets, sources);
        vm.stopPrank();

        // Verify price sources were set correctly
        assertEq(
            PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getSourceOfAssetPrice(asset1),
            address(priceFeed1)
        );
        assertEq(
            PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getSourceOfAssetPrice(asset2),
            address(priceFeed2)
        );

        // Verify prices
        (uint256 price1, uint256 decimals1) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(
            asset1
        );
        (uint256 price2, uint256 decimals2) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(
            asset2
        );

        assertEq(price1, 1e18);
        assertEq(price2, 2e18);
        assertEq(decimals1, 18);
        assertEq(decimals2, 18);
    }

    function testSetAssetsPriceSources_EmptyArray() public {
        address[] memory assets = new address[](0);
        address[] memory sources = new address[](0);

        vm.startPrank(_PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS);
        vm.expectRevert(PriceOracleMiddlewareManager.EmptyArrayNotSupported.selector);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceSources(assets, sources);
        vm.stopPrank();
    }

    function testSetAssetsPriceSources_ArrayLengthMismatch() public {
        address[] memory assets = new address[](2);
        assets[0] = address(0x123);
        assets[1] = address(0x456);

        address[] memory sources = new address[](1);
        sources[0] = address(new FixedValuePriceFeed(1e18));

        vm.startPrank(_PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS);
        vm.expectRevert(PriceOracleMiddlewareManager.ArrayLengthMismatch.selector);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceSources(assets, sources);
        vm.stopPrank();
    }

    function testSetAssetsPriceSources_Unauthorized() public {
        address[] memory assets = new address[](1);
        assets[0] = address(0x123);

        address[] memory sources = new address[](1);
        sources[0] = address(new FixedValuePriceFeed(1e18));

        vm.expectRevert();
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceSources(assets, sources);
    }

    function testSetAssetsPriceSources_UpdateExisting() public {
        address asset = address(0x123);
        FixedValuePriceFeed priceFeed1 = new FixedValuePriceFeed(1e18);
        FixedValuePriceFeed priceFeed2 = new FixedValuePriceFeed(2e18);

        address[] memory assets = new address[](1);
        assets[0] = asset;

        address[] memory sources = new address[](1);
        sources[0] = address(priceFeed1);

        // Set initial price source
        vm.startPrank(_PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceSources(assets, sources);

        // Update price source
        sources[0] = address(priceFeed2);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceSources(assets, sources);
        vm.stopPrank();

        // Verify price source was updated
        assertEq(
            PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getSourceOfAssetPrice(asset),
            address(priceFeed2)
        );

        // Verify new price
        (uint256 price, uint256 decimals) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(
            asset
        );
        assertEq(price, 2e18);
        assertEq(decimals, 18);
    }

    function testRemoveAssetsPriceSources_Success() public {
        // Setup test assets and price feeds
        address asset1 = address(0x123);
        address asset2 = address(0x456);

        FixedValuePriceFeed priceFeed1 = new FixedValuePriceFeed(1e18);
        FixedValuePriceFeed priceFeed2 = new FixedValuePriceFeed(2e18);

        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;

        address[] memory sources = new address[](2);
        sources[0] = address(priceFeed1);
        sources[1] = address(priceFeed2);

        // First set the price sources
        vm.startPrank(_PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceSources(assets, sources);

        // Verify they were set correctly
        assertEq(
            PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getSourceOfAssetPrice(asset1),
            address(priceFeed1)
        );
        assertEq(
            PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getSourceOfAssetPrice(asset2),
            address(priceFeed2)
        );

        // Now remove them
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).removeAssetsPriceSources(assets);
        vm.stopPrank();

        // Verify they were removed
        assertEq(PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getSourceOfAssetPrice(asset1), address(0));
        assertEq(PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getSourceOfAssetPrice(asset2), address(0));
    }

    function testRemoveAssetsPriceSources_EmptyArray() public {
        address[] memory assets = new address[](0);

        vm.startPrank(_PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS);
        vm.expectRevert(PriceOracleMiddlewareManager.EmptyArrayNotSupported.selector);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).removeAssetsPriceSources(assets);
        vm.stopPrank();
    }

    function testRemoveAssetsPriceSources_Unauthorized() public {
        address[] memory assets = new address[](1);
        assets[0] = address(0x123);

        vm.expectRevert();
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).removeAssetsPriceSources(assets);
    }

    function testRemoveAssetsPriceSources_NonExistentAssets() public {
        address[] memory assets = new address[](2);
        assets[0] = address(0x123);
        assets[1] = address(0x456);

        vm.startPrank(_PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS);
        // Should not revert when removing non-existent assets
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).removeAssetsPriceSources(assets);
        vm.stopPrank();

        // Verify assets are still not set
        assertEq(
            PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getSourceOfAssetPrice(assets[0]),
            address(0)
        );
        assertEq(
            PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getSourceOfAssetPrice(assets[1]),
            address(0)
        );
    }

    function testRemoveAssetsPriceSources_PartialRemoval() public {
        // Setup test assets and price feeds
        address asset1 = address(0x123);
        address asset2 = address(0x456);

        FixedValuePriceFeed priceFeed1 = new FixedValuePriceFeed(1e18);
        FixedValuePriceFeed priceFeed2 = new FixedValuePriceFeed(2e18);

        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;

        address[] memory sources = new address[](2);
        sources[0] = address(priceFeed1);
        sources[1] = address(priceFeed2);

        // Set all price sources
        vm.startPrank(_PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceSources(assets, sources);

        // Remove only one asset
        address[] memory assetsToRemove = new address[](1);
        assetsToRemove[0] = asset1;
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).removeAssetsPriceSources(assetsToRemove);
        vm.stopPrank();

        // Verify first asset was removed but second remains
        assertEq(PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getSourceOfAssetPrice(asset1), address(0));
        assertEq(
            PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getSourceOfAssetPrice(asset2),
            address(priceFeed2)
        );
    }

    function testSetPriceOracleMiddleware_Success() public {
        address newMiddleware = address(0x999);

        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setPriceOracleMiddleware(newMiddleware);
        vm.stopPrank();

        assertEq(PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getPriceOracleMiddleware(), newMiddleware);
    }

    function testSetPriceOracleMiddleware_Unauthorized() public {
        address newMiddleware = address(0x999);

        vm.expectRevert();
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setPriceOracleMiddleware(newMiddleware);
    }

    function testSetPriceOracleMiddleware_ZeroAddress() public {
        vm.startPrank(_ATOMIST);
        vm.expectRevert(PriceOracleMiddlewareManagerLib.PriceOracleMiddlewareCanNotBeZero.selector);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setPriceOracleMiddleware(address(0));
        vm.stopPrank();
    }

    function testSetPriceOracleMiddleware_MultipleUpdates() public {
        address middleware1 = address(0x999);
        address middleware2 = address(0x888);

        vm.startPrank(_ATOMIST);

        // First update
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setPriceOracleMiddleware(middleware1);
        assertEq(PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getPriceOracleMiddleware(), middleware1);

        // Second update
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setPriceOracleMiddleware(middleware2);
        assertEq(PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getPriceOracleMiddleware(), middleware2);

        vm.stopPrank();
    }

    function testSetPriceOracleMiddleware_Integration() public {
        // Setup test asset and price feed
        address asset = address(0x123);
        FixedValuePriceFeed priceFeed = new FixedValuePriceFeed(1e18);

        address[] memory assets = new address[](1);
        assets[0] = asset;

        address[] memory sources = new address[](1);
        sources[0] = address(priceFeed);

        vm.startPrank(_PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceSources(assets, sources);
        vm.stopPrank();

        vm.startPrank(_ATOMIST);

        // Change middleware
        address newMiddleware = address(0x999);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setPriceOracleMiddleware(newMiddleware);
        vm.stopPrank();

        // Verify middleware was updated
        assertEq(PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getPriceOracleMiddleware(), newMiddleware);

        // Verify existing price sources are still accessible
        assertEq(
            PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getSourceOfAssetPrice(asset),
            address(priceFeed)
        );
    }

    function testGetPriceOracleMiddleware() public {
        assertEq(
            PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getPriceOracleMiddleware(),
            _PRICE_ORACLE_MIDDLEWARE
        );
    }

    function testGetSourceOfAssetPrice_NotConfigured() public {
        address asset = address(0x123);
        assertEq(PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getSourceOfAssetPrice(asset), address(0));
    }

    function testGetSourceOfAssetPrice_Configured() public {
        address asset = address(0x123);
        FixedValuePriceFeed priceFeed = new FixedValuePriceFeed(1e18);

        address[] memory assets = new address[](1);
        assets[0] = asset;

        address[] memory sources = new address[](1);
        sources[0] = address(priceFeed);

        vm.startPrank(_PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceSources(assets, sources);
        vm.stopPrank();

        assertEq(
            PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getSourceOfAssetPrice(asset),
            address(priceFeed)
        );
    }

    function testGetConfiguredAssets_Empty() public {
        address[] memory configuredAssets = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager)
            .getConfiguredAssets();
        assertEq(configuredAssets.length, 0);
    }

    function testGetConfiguredAssets_WithAssets() public {
        address asset1 = address(0x123);
        address asset2 = address(0x456);

        FixedValuePriceFeed priceFeed1 = new FixedValuePriceFeed(1e18);
        FixedValuePriceFeed priceFeed2 = new FixedValuePriceFeed(2e18);

        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;

        address[] memory sources = new address[](2);
        sources[0] = address(priceFeed1);
        sources[1] = address(priceFeed2);

        vm.startPrank(_PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceSources(assets, sources);
        vm.stopPrank();

        address[] memory configuredAssets = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager)
            .getConfiguredAssets();
        assertEq(configuredAssets.length, 2);
        assertEq(configuredAssets[0], asset1);
        assertEq(configuredAssets[1], asset2);
    }

    function testGetAssetPrice_NotConfigured() public {
        address asset = address(0x123);

        vm.expectRevert(PriceOracleMiddlewareManager.UnsupportedAsset.selector);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(asset);
    }

    function testGetAssetPrice_Configured() public {
        address asset = address(0x123);
        FixedValuePriceFeed priceFeed = new FixedValuePriceFeed(1e18);

        address[] memory assets = new address[](1);
        assets[0] = asset;

        address[] memory sources = new address[](1);
        sources[0] = address(priceFeed);

        vm.startPrank(_PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceSources(assets, sources);
        vm.stopPrank();

        (uint256 price, uint256 decimals) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(
            asset
        );
        assertEq(price, 1e18);
        assertEq(decimals, 18);
    }

    function testGetAssetsPrices_EmptyArray() public {
        address[] memory assets = new address[](0);

        vm.expectRevert(PriceOracleMiddlewareManager.EmptyArrayNotSupported.selector);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetsPrices(assets);
    }

    function testGetAssetsPrices_Success() public {
        address asset1 = address(0x123);
        address asset2 = address(0x456);

        FixedValuePriceFeed priceFeed1 = new FixedValuePriceFeed(1e18);
        FixedValuePriceFeed priceFeed2 = new FixedValuePriceFeed(2e18);

        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;

        address[] memory sources = new address[](2);
        sources[0] = address(priceFeed1);
        sources[1] = address(priceFeed2);

        vm.startPrank(_PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceSources(assets, sources);
        vm.stopPrank();

        (uint256[] memory prices, uint256[] memory decimals) = PriceOracleMiddlewareManager(
            _priceOracleMiddlewareManager
        ).getAssetsPrices(assets);

        assertEq(prices.length, 2);
        assertEq(decimals.length, 2);

        assertEq(prices[0], 1e18);
        assertEq(prices[1], 2e18);
        assertEq(decimals[0], 18);
        assertEq(decimals[1], 18);
    }

    function testGetAssetsPrices_WithUnsupportedAsset() public {
        address asset1 = address(0x123);
        address asset2 = address(0x456);

        FixedValuePriceFeed priceFeed1 = new FixedValuePriceFeed(1e18);

        address[] memory assetsToConfigure = new address[](1);
        assetsToConfigure[0] = asset1;

        address[] memory sources = new address[](1);
        sources[0] = address(priceFeed1);

        vm.startPrank(_PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceSources(assetsToConfigure, sources);
        vm.stopPrank();

        address[] memory assetsToQuery = new address[](2);
        assetsToQuery[0] = asset1;
        assetsToQuery[1] = asset2;

        vm.expectRevert(PriceOracleMiddlewareManager.UnsupportedAsset.selector);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetsPrices(assetsToQuery);
    }
}
