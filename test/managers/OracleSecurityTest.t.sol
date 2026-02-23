// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, FeeConfig} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {PriceOracleMiddlewareManagerLib} from "../../contracts/managers/price/PriceOracleMiddlewareManagerLib.sol";
import {SequencerUptimeLib} from "../../contracts/managers/price/SequencerUptimeLib.sol";
import {IporFusionAccessManagerInitializerLibV1, InitializationData, DataForInitialization, PlasmaVaultAddress} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";

import {MockSequencerUptimeFeed} from "./mocks/MockSequencerUptimeFeed.sol";
import {MockPriceFeedWithTimestamp} from "./mocks/MockPriceFeedWithTimestamp.sol";

contract OracleSecurityTest is Test {
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

    address private constant _USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant _PRICE_ORACLE_MIDDLEWARE = 0xC9F32d65a278b012371858fD3cdE315B12d664c6;

    address private _accessManager;
    address private _withdrawManager;
    address private _plasmaVault;
    address private _priceOracleMiddlewareManager;

    MockSequencerUptimeFeed private _mockSequencerFeed;
    MockPriceFeedWithTimestamp private _mockPriceFeed;

    address private constant _TEST_ASSET = address(0xABCD);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22238002);
        _deployMinimalPlasmaVault();
        _setupInitialRoles();

        // Deploy mock sequencer feed: UP, started 2h ago, updated now
        _mockSequencerFeed = new MockSequencerUptimeFeed(
            0, // UP
            block.timestamp - 7200, // started 2h ago
            block.timestamp // updated now
        );

        // Deploy mock price feed: 2000 USD, 8 decimals, updated now
        _mockPriceFeed = new MockPriceFeedWithTimestamp(
            2000e8, // $2000
            8, // 8 decimals
            block.timestamp // updated now
        );

        // Configure asset price source
        address[] memory assets = new address[](1);
        assets[0] = _TEST_ASSET;
        address[] memory sources = new address[](1);
        sources[0] = address(_mockPriceFeed);

        vm.startPrank(_PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceSources(assets, sources);
        vm.stopPrank();
    }

    // ======================== Sequencer Tests ========================

    function testSequencerDown_RevertsOnPriceQuery() public {
        // Configure sequencer check
        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).configureSequencerCheck(
            address(_mockSequencerFeed),
            false // Arbitrum
        );
        vm.stopPrank();

        // Set sequencer DOWN
        _mockSequencerFeed.setAnswer(1);

        // Should revert with SequencerDown
        vm.expectRevert(SequencerUptimeLib.SequencerDown.selector);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
    }

    function testGracePeriodNotElapsed_Reverts() public {
        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).configureSequencerCheck(
            address(_mockSequencerFeed),
            false
        );
        vm.stopPrank();

        // Sequencer UP but just restarted 30 min ago (< 3600s grace)
        _mockSequencerFeed.setAnswer(0);
        _mockSequencerFeed.setStartedAt(block.timestamp - 1800);

        vm.expectRevert(
            abi.encodeWithSelector(SequencerUptimeLib.GracePeriodNotElapsed.selector, 1800, 3600)
        );
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
    }

    function testSequencerUpGraceElapsed_Passes() public {
        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).configureSequencerCheck(
            address(_mockSequencerFeed),
            false
        );
        vm.stopPrank();

        // Sequencer UP, started 2h ago — should pass
        (uint256 price, uint256 decimals) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(
            _TEST_ASSET
        );
        assertEq(price, 2000e18); // Converted from 8 to 18 decimals
        assertEq(decimals, 18);
    }

    function testSequencerCheckDisabled_Passes() public {
        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).configureSequencerCheck(
            address(_mockSequencerFeed),
            false
        );
        // Disable the check
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setSequencerCheckEnabled(false);
        vm.stopPrank();

        // Sequencer DOWN — but check disabled, should pass
        _mockSequencerFeed.setAnswer(1);

        (uint256 price, ) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
        assertEq(price, 2000e18);
    }

    function testZeroAddressFeed_SkipsCheck() public {
        // No sequencer configured — default state, should work fine
        (uint256 price, ) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
        assertEq(price, 2000e18);
    }

    function testArbitrumStaleSequencerFeed_Reverts() public {
        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).configureSequencerCheck(
            address(_mockSequencerFeed),
            false // Arbitrum
        );
        vm.stopPrank();

        // Set updatedAt to >7 days ago
        _mockSequencerFeed.setUpdatedAt(block.timestamp - 8 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                SequencerUptimeLib.SequencerFeedStale.selector,
                block.timestamp - 8 days,
                604800 // 7 days
            )
        );
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
    }

    function testOpStackStaleSequencerFeed_Reverts() public {
        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).configureSequencerCheck(
            address(_mockSequencerFeed),
            true // OP Stack
        );
        vm.stopPrank();

        // Set updatedAt to >48h ago
        _mockSequencerFeed.setUpdatedAt(block.timestamp - 49 hours);

        vm.expectRevert(
            abi.encodeWithSelector(
                SequencerUptimeLib.SequencerFeedStale.selector,
                block.timestamp - 49 hours,
                172800 // 48 hours
            )
        );
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
    }

    function testArbitrumUninitializedFeed_Skips() public {
        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).configureSequencerCheck(
            address(_mockSequencerFeed),
            false // Arbitrum
        );
        vm.stopPrank();

        // Uninitialized: startedAt=0, updatedAt=0
        _mockSequencerFeed.setAnswer(0);
        _mockSequencerFeed.setStartedAt(0);
        _mockSequencerFeed.setUpdatedAt(0);

        // Should skip check (not revert)
        (uint256 price, ) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
        assertEq(price, 2000e18);
    }

    // ======================== Staleness Tests ========================

    function testStalePrice_Reverts() public {
        // Configure staleness: 7200s (2h)
        address[] memory assets = new address[](1);
        assets[0] = _TEST_ASSET;
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 7200;

        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsStalenessThresholds(assets, thresholds);
        vm.stopPrank();

        // Set feed updatedAt to 3h ago (stale)
        _mockPriceFeed.setUpdatedAt(block.timestamp - 10800);

        vm.expectRevert(
            abi.encodeWithSelector(
                PriceOracleMiddlewareManagerLib.StalePrice.selector,
                _TEST_ASSET,
                block.timestamp - 10800,
                7200
            )
        );
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
    }

    function testFreshPrice_Passes() public {
        address[] memory assets = new address[](1);
        assets[0] = _TEST_ASSET;
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 7200;

        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsStalenessThresholds(assets, thresholds);
        vm.stopPrank();

        // Feed updated 1h ago — within 2h threshold
        _mockPriceFeed.setUpdatedAt(block.timestamp - 3600);

        (uint256 price, ) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
        assertEq(price, 2000e18);
    }

    function testNoStalenessConfigured_Passes() public {
        // No staleness configured, old feed should pass
        _mockPriceFeed.setUpdatedAt(block.timestamp - 365 days);

        (uint256 price, ) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
        assertEq(price, 2000e18);
    }

    function testRemoveStaleness_PassesAgain() public {
        address[] memory assets = new address[](1);
        assets[0] = _TEST_ASSET;
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 7200;

        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsStalenessThresholds(assets, thresholds);
        vm.stopPrank();

        _mockPriceFeed.setUpdatedAt(block.timestamp - 10800);

        // Should revert
        vm.expectRevert();
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);

        // Remove staleness
        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).removeAssetsStalenessThresholds(assets);
        vm.stopPrank();

        // Should pass now
        (uint256 price, ) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
        assertEq(price, 2000e18);
    }

    function testDefaultStaleness_Fallback() public {
        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setDefaultStalenessThreshold(7200);
        vm.stopPrank();

        // Feed 3h old — exceeds default 2h
        _mockPriceFeed.setUpdatedAt(block.timestamp - 10800);

        vm.expectRevert();
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
    }

    function testPerAssetOverridesDefault() public {
        address[] memory assets = new address[](1);
        assets[0] = _TEST_ASSET;
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 90000; // 25h

        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setDefaultStalenessThreshold(7200); // 2h default
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsStalenessThresholds(assets, thresholds);
        vm.stopPrank();

        // Feed 3h old — exceeds default 2h but within per-asset 25h
        _mockPriceFeed.setUpdatedAt(block.timestamp - 10800);

        (uint256 price, ) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
        assertEq(price, 2000e18);
    }

    // ======================== Price Bounds Tests ========================

    function testPriceBelowMin_Reverts() public {
        address[] memory assets = new address[](1);
        assets[0] = _TEST_ASSET;
        uint256[] memory minPrices = new uint256[](1);
        minPrices[0] = 500e18;
        uint256[] memory maxPrices = new uint256[](1);
        maxPrices[0] = 50000e18;

        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceBounds(assets, minPrices, maxPrices);
        vm.stopPrank();

        // Price $100 — below $500 min
        _mockPriceFeed.setPrice(100e8);

        vm.expectRevert(
            abi.encodeWithSelector(
                PriceOracleMiddlewareManagerLib.PriceOutOfBounds.selector,
                _TEST_ASSET,
                100e18,
                500e18,
                50000e18
            )
        );
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
    }

    function testPriceAboveMax_Reverts() public {
        address[] memory assets = new address[](1);
        assets[0] = _TEST_ASSET;
        uint256[] memory minPrices = new uint256[](1);
        minPrices[0] = 500e18;
        uint256[] memory maxPrices = new uint256[](1);
        maxPrices[0] = 50000e18;

        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceBounds(assets, minPrices, maxPrices);
        vm.stopPrank();

        // Price $60000 — above $50000 max
        _mockPriceFeed.setPrice(60000e8);

        vm.expectRevert(
            abi.encodeWithSelector(
                PriceOracleMiddlewareManagerLib.PriceOutOfBounds.selector,
                _TEST_ASSET,
                60000e18,
                500e18,
                50000e18
            )
        );
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
    }

    function testPriceWithinBounds_Passes() public {
        address[] memory assets = new address[](1);
        assets[0] = _TEST_ASSET;
        uint256[] memory minPrices = new uint256[](1);
        minPrices[0] = 500e18;
        uint256[] memory maxPrices = new uint256[](1);
        maxPrices[0] = 50000e18;

        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceBounds(assets, minPrices, maxPrices);
        vm.stopPrank();

        (uint256 price, ) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
        assertEq(price, 2000e18);
    }

    function testNoBoundsConfigured_Passes() public {
        // Price $5.8M — would be caught by bounds, but none configured
        _mockPriceFeed.setPrice(5800000e8);

        (uint256 price, ) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
        assertEq(price, 5800000e18);
    }

    function testRemoveBounds_PassesAgain() public {
        address[] memory assets = new address[](1);
        assets[0] = _TEST_ASSET;
        uint256[] memory minPrices = new uint256[](1);
        minPrices[0] = 500e18;
        uint256[] memory maxPrices = new uint256[](1);
        maxPrices[0] = 50000e18;

        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceBounds(assets, minPrices, maxPrices);
        vm.stopPrank();

        _mockPriceFeed.setPrice(100e8); // Below min

        vm.expectRevert();
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);

        // Remove bounds
        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).removeAssetsPriceBounds(assets);
        vm.stopPrank();

        (uint256 price, ) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
        assertEq(price, 100e18);
    }

    function testOnlyMinBound_Configured() public {
        address[] memory assets = new address[](1);
        assets[0] = _TEST_ASSET;
        uint256[] memory minPrices = new uint256[](1);
        minPrices[0] = 500e18;
        uint256[] memory maxPrices = new uint256[](1);
        maxPrices[0] = 0; // No ceiling

        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceBounds(assets, minPrices, maxPrices);
        vm.stopPrank();

        // Very high price should pass (no max)
        _mockPriceFeed.setPrice(1000000e8);
        (uint256 price, ) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
        assertEq(price, 1000000e18);

        // Low price should revert
        _mockPriceFeed.setPrice(100e8);
        vm.expectRevert();
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(_TEST_ASSET);
    }

    // ======================== Configuration Access Control Tests ========================

    function testConfigureSequencerCheck_Unauthorized() public {
        vm.expectRevert();
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).configureSequencerCheck(
            address(_mockSequencerFeed),
            false
        );
    }

    function testConfigureSequencerCheck_Success() public {
        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).configureSequencerCheck(
            address(_mockSequencerFeed),
            false
        );
        vm.stopPrank();

        (address feed, bool isOpStack, bool enabled) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager)
            .getSequencerConfig();
        assertEq(feed, address(_mockSequencerFeed));
        assertFalse(isOpStack);
        assertTrue(enabled);
    }

    function testSetAssetsStalenessThresholds_EmptyArray() public {
        address[] memory assets = new address[](0);
        uint256[] memory thresholds = new uint256[](0);

        vm.startPrank(_ATOMIST);
        vm.expectRevert(PriceOracleMiddlewareManager.EmptyArrayNotSupported.selector);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsStalenessThresholds(assets, thresholds);
        vm.stopPrank();
    }

    function testSetAssetsPriceBounds_ArrayMismatch() public {
        address[] memory assets = new address[](2);
        assets[0] = _TEST_ASSET;
        assets[1] = address(0x1234);
        uint256[] memory minPrices = new uint256[](1);
        minPrices[0] = 500e18;
        uint256[] memory maxPrices = new uint256[](2);
        maxPrices[0] = 50000e18;
        maxPrices[1] = 50000e18;

        vm.startPrank(_ATOMIST);
        vm.expectRevert(PriceOracleMiddlewareManager.ArrayLengthMismatch.selector);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceBounds(
            assets,
            minPrices,
            maxPrices
        );
        vm.stopPrank();
    }

    function testGetAssetStalenessThreshold_ReturnsConfigured() public {
        address[] memory assets = new address[](1);
        assets[0] = _TEST_ASSET;
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 7200;

        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsStalenessThresholds(assets, thresholds);
        vm.stopPrank();

        uint256 threshold = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetStalenessThreshold(
            _TEST_ASSET
        );
        assertEq(threshold, 7200);
    }

    function testGetAssetPriceBounds_ReturnsConfigured() public {
        address[] memory assets = new address[](1);
        assets[0] = _TEST_ASSET;
        uint256[] memory minPrices = new uint256[](1);
        minPrices[0] = 500e18;
        uint256[] memory maxPrices = new uint256[](1);
        maxPrices[0] = 50000e18;

        vm.startPrank(_ATOMIST);
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceBounds(assets, minPrices, maxPrices);
        vm.stopPrank();

        (uint256 minPrice, uint256 maxPrice) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager)
            .getAssetPriceBounds(_TEST_ASSET);
        assertEq(minPrice, 500e18);
        assertEq(maxPrice, 50000e18);
    }

    // ======================== Combined Tests ========================

    function testAllSecurityChecks_Combined() public {
        address[] memory assets = new address[](1);
        assets[0] = _TEST_ASSET;

        vm.startPrank(_ATOMIST);
        // Enable sequencer
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).configureSequencerCheck(
            address(_mockSequencerFeed),
            false
        );

        // Set staleness
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 7200;
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsStalenessThresholds(assets, thresholds);

        // Set bounds
        uint256[] memory minPrices = new uint256[](1);
        minPrices[0] = 500e18;
        uint256[] memory maxPrices = new uint256[](1);
        maxPrices[0] = 50000e18;
        PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).setAssetsPriceBounds(assets, minPrices, maxPrices);
        vm.stopPrank();

        // All checks pass: sequencer up (2h ago), price fresh (now), price $2000 in bounds
        (uint256 price, uint256 decimals) = PriceOracleMiddlewareManager(_priceOracleMiddlewareManager).getAssetPrice(
            _TEST_ASSET
        );
        assertEq(price, 2000e18);
        assertEq(decimals, 18);
    }

    // ======================== Helpers ========================

    function _deployMinimalPlasmaVault() private {
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
            withdrawManager: _withdrawManager,
            plasmaVaultVotesPlugin: address(0)
        });

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(new PlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(initData);
        vm.stopPrank();
    }

    function _setupInitialRoles() private {
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

        address[] memory priceOracleMiddlewareManagers = new address[](1);
        priceOracleMiddlewareManagers[0] = _PRICE_ORACLE_MIDDLEWARE_MANAGER_ADDRESS;

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
}
