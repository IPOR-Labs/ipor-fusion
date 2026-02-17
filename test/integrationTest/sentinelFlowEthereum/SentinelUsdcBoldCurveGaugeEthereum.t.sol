// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CurveStableswapNGSingleSideSupplyFuse, CurveStableswapNGSingleSideSupplyFuseEnterData, CurveStableswapNGSingleSideSupplyFuseExitData} from "../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideSupplyFuse.sol";
import {CurveStableswapNGSingleSideBalanceFuse} from "../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideBalanceFuse.sol";
import {CurveLiquidityGaugeV6SupplyFuse, CurveLiquidityGaugeV6SupplyFuseEnterData, CurveLiquidityGaugeV6SupplyFuseExitData} from "../../../contracts/fuses/curve_gauge/CurveLiquidityGaugeV6SupplyFuse.sol";
import {CurveLiquidityGaugeV6BalanceFuse} from "../../../contracts/fuses/curve_gauge/CurveLiquidityGaugeV6BalanceFuse.sol";
import {CurveGaugeTokenClaimFuse} from "../../../contracts/rewards_fuses/curve_gauges/CurveGaugeTokenClaimFuse.sol";
import {ILiquidityGaugeV6} from "../../../contracts/fuses/curve_gauge/ext/ILiquidityGaugeV6.sol";
import {ICurveStableswapNG} from "../../../contracts/fuses/curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {PlasmaVault, FuseAction, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryStorageLib} from "../../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {PlasmaVaultFactory} from "../../../contracts/factory/PlasmaVaultFactory.sol";
import {FeeManagerFactory} from "../../../contracts/managers/fee/FeeManagerFactory.sol";
import {AccessManagerFactory} from "../../../contracts/factory/AccessManagerFactory.sol";
import {PriceManagerFactory} from "../../../contracts/factory/PriceManagerFactory.sol";
import {WithdrawManagerFactory} from "../../../contracts/factory/WithdrawManagerFactory.sol";
import {RewardsManagerFactory} from "../../../contracts/factory/RewardsManagerFactory.sol";
import {ContextManagerFactory} from "../../../contracts/factory/ContextManagerFactory.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";

/// @title Sentinel USDC/BOLD Curve Gauge flow on Ethereum Mainnet
/// @notice Tests the full flow: BOLD -> Curve pool LP -> Gauge staking -> Claim rewards -> Unstake -> Remove liquidity
/// @dev Vault is created via FusionFactory (clone) to match production deployment pattern
contract SentinelUsdcBoldCurveGaugeEthereum is Test {
    struct PlasmaVaultState {
        uint256 vaultUsdcBalance;
        uint256 vaultBoldBalance;
        uint256 vaultTotalAssets;
        uint256 vaultTotalAssetsInCurvePool;
        uint256 vaultTotalAssetsInGauge;
        uint256 vaultLpTokensBalance;
        uint256 vaultStakedLpTokensBalance;
    }

    /// Ethereum Mainnet addresses
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    address public constant CURVE_USDC_BOLD_POOL = 0xEFc6516323FbD28e80B85A497B65A86243a54B3E;
    address public constant CURVE_GAUGE = 0x07a01471fA544D9C6531B631E6A96A79a9AD05E9;

    ICurveStableswapNG public constant CURVE_POOL = ICurveStableswapNG(CURVE_USDC_BOLD_POOL);
    ILiquidityGaugeV6 public constant LIQUIDITY_GAUGE = ILiquidityGaugeV6(CURVE_GAUGE);

    /// Chainlink price feeds on Ethereum Mainnet
    address public constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    /// FusionFactory on Ethereum Mainnet
    address public constant EXISTING_FUSION_FACTORY_PROXY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;

    /// Vaults
    PlasmaVault public plasmaVault;

    /// Fuses
    CurveStableswapNGSingleSideSupplyFuse public curvePoolSupplyFuse;
    CurveLiquidityGaugeV6SupplyFuse public curveGaugeSupplyFuse;
    CurveGaugeTokenClaimFuse public curveGaugeClaimFuse;

    /// Managers
    RewardsClaimManager public rewardsClaimManager;
    IporFusionAccessManager public accessManager;
    PriceOracleMiddlewareManager public priceManager;

    /// Users
    address public owner = makeAddr("OWNER");
    address public atomist = makeAddr("ATOMIST");
    address public fuseManager = makeAddr("FUSE_MANAGER");
    address public alpha = makeAddr("ALPHA");
    address public priceOracleMiddlewareManager = makeAddr("PRICE_ORACLE_MIDDLEWARE_MANAGER");
    address public daoFeeManager = makeAddr("DAO_FEE_MANAGER");
    address public depositor = makeAddr("DEPOSITOR");

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 24475332);

        // Deploy fresh FusionFactory and create vault via clone
        FusionFactory fusionFactory = _deployFreshFusionFactory();

        FusionFactoryLogicLib.FusionInstance memory fusionInstance = fusionFactory.clone(
            "SENTINEL USDC VAULT",
            "sUSDC",
            USDC,
            0, // no redemption delay for testing
            owner,
            0 // fee package index
        );

        plasmaVault = PlasmaVault(fusionInstance.plasmaVault);
        accessManager = IporFusionAccessManager(fusionInstance.accessManager);
        rewardsClaimManager = RewardsClaimManager(fusionInstance.rewardsManager);
        priceManager = PriceOracleMiddlewareManager(fusionInstance.priceManager);

        // Grant roles
        vm.startPrank(owner);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        vm.stopPrank();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, fuseManager, 0);
        accessManager.grantRole(Roles.ALPHA_ROLE, alpha, 0);
        accessManager.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, priceOracleMiddlewareManager, 0);
        accessManager.grantRole(Roles.CLAIM_REWARDS_ROLE, atomist, 0);
        vm.stopPrank();

        // Configure price feeds for USDC and BOLD
        address[] memory assets = new address[](2);
        address[] memory sources = new address[](2);
        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC_USD;
        assets[1] = BOLD;
        sources[1] = CHAINLINK_USDC_USD; // BOLD pegged ~1 USD, use USDC/USD feed as approximation
        vm.prank(priceOracleMiddlewareManager);
        priceManager.setAssetsPriceSources(assets, sources);

        // Deploy and configure fuses
        _setupFuses();

        // Make vault public
        vm.startPrank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).convertToPublicVault();
        PlasmaVaultGovernance(address(plasmaVault)).enableTransferShares();
        vm.stopPrank();
    }

    /// @notice Full Sentinel flow: BOLD -> Curve LP -> Gauge stake -> claim rewards -> unstake -> remove liquidity
    function testShouldExecuteFullSentinelFlow() public {
        // === Step 1: Deposit USDC into the vault ===
        uint256 usdcAmount = 10_000 * 1e6; // 10,000 USDC
        deal(USDC, depositor, usdcAmount);
        vm.startPrank(depositor);
        ERC20(USDC).approve(address(plasmaVault), usdcAmount);
        plasmaVault.deposit(usdcAmount, depositor);
        vm.stopPrank();

        PlasmaVaultState memory stateAfterDeposit = _getPlasmaVaultState();
        assertEq(stateAfterDeposit.vaultUsdcBalance, usdcAmount, "USDC balance after deposit");
        assertGt(stateAfterDeposit.vaultTotalAssets, 0, "Total assets after deposit should be > 0");

        // === Step 2: Simulate having BOLD (skip Ebisu trove creation) ===
        uint256 boldAmount = 5_000 * 1e18; // 5,000 BOLD
        deal(BOLD, address(plasmaVault), boldAmount);

        PlasmaVaultState memory stateAfterBoldDeal = _getPlasmaVaultState();
        assertEq(stateAfterBoldDeal.vaultBoldBalance, boldAmount, "BOLD balance after deal");

        // === Step 3: Add BOLD liquidity to Curve USDC/BOLD pool -> LP tokens ===
        FuseAction[] memory enterPoolCalls = new FuseAction[](1);
        enterPoolCalls[0] = FuseAction(
            address(curvePoolSupplyFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256))",
                CurveStableswapNGSingleSideSupplyFuseEnterData({
                    curveStableswapNG: CURVE_POOL,
                    asset: BOLD,
                    assetAmount: boldAmount,
                    minLpTokenAmountReceived: 0
                })
            )
        );
        vm.prank(alpha);
        plasmaVault.execute(enterPoolCalls);

        PlasmaVaultState memory stateAfterEnterPool = _getPlasmaVaultState();
        assertEq(stateAfterEnterPool.vaultBoldBalance, 0, "BOLD should be 0 after entering pool");
        assertGt(stateAfterEnterPool.vaultLpTokensBalance, 0, "LP tokens should be > 0 after entering pool");
        assertGt(stateAfterEnterPool.vaultTotalAssetsInCurvePool, 0, "Total assets in Curve pool should be > 0");

        // === Step 4: Stake LP tokens into gauge ===
        uint256 lpTokensToStake = stateAfterEnterPool.vaultLpTokensBalance;

        FuseAction[] memory enterGaugeCalls = new FuseAction[](1);
        enterGaugeCalls[0] = FuseAction(
            address(curveGaugeSupplyFuse),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                CurveLiquidityGaugeV6SupplyFuseEnterData({
                    liquidityGauge: CURVE_GAUGE,
                    lpTokenAmount: lpTokensToStake
                })
            )
        );

        vm.prank(alpha);
        plasmaVault.execute(enterGaugeCalls);

        PlasmaVaultState memory stateAfterStake = _getPlasmaVaultState();
        assertEq(stateAfterStake.vaultLpTokensBalance, 0, "LP tokens should be 0 after staking");
        assertEq(
            stateAfterStake.vaultStakedLpTokensBalance,
            lpTokensToStake,
            "Staked LP tokens should match deposited amount"
        );
        assertGt(stateAfterStake.vaultTotalAssetsInGauge, 0, "Total assets in gauge should be > 0");
        assertEq(
            stateAfterStake.vaultTotalAssetsInCurvePool,
            0,
            "Total assets in Curve pool should be 0 (moved to gauge)"
        );

        // === Step 5: Warp time and claim rewards ===
        vm.warp(block.timestamp + 30 days);

        // Claim rewards via RewardsClaimManager
        FuseAction[] memory claimCalls = new FuseAction[](1);
        claimCalls[0] = FuseAction(address(curveGaugeClaimFuse), abi.encodeWithSignature("claim()"));
        vm.prank(atomist);
        rewardsClaimManager.claimRewards(claimCalls);

        // === Step 6: Unstake LP tokens from gauge ===
        uint256 stakedLpTokens = stateAfterStake.vaultStakedLpTokensBalance;

        FuseAction[] memory exitGaugeCalls = new FuseAction[](1);
        exitGaugeCalls[0] = FuseAction(
            address(curveGaugeSupplyFuse),
            abi.encodeWithSignature(
                "exit((address,uint256))",
                CurveLiquidityGaugeV6SupplyFuseExitData({liquidityGauge: CURVE_GAUGE, lpTokenAmount: stakedLpTokens})
            )
        );

        vm.prank(alpha);
        plasmaVault.execute(exitGaugeCalls);

        PlasmaVaultState memory stateAfterUnstake = _getPlasmaVaultState();
        assertEq(stateAfterUnstake.vaultStakedLpTokensBalance, 0, "Staked LP tokens should be 0 after unstaking");
        assertEq(
            stateAfterUnstake.vaultLpTokensBalance,
            stakedLpTokens,
            "LP tokens should be restored after unstaking"
        );
        assertEq(stateAfterUnstake.vaultTotalAssetsInGauge, 0, "Total assets in gauge should be 0 after unstake");
        assertGt(
            stateAfterUnstake.vaultTotalAssetsInCurvePool,
            0,
            "Total assets in Curve pool should be > 0 after unstake"
        );

        // === Step 7: Remove liquidity from Curve pool -> get BOLD back ===
        uint256 lpTokensToRemove = stateAfterUnstake.vaultLpTokensBalance;

        FuseAction[] memory exitPoolCalls = new FuseAction[](1);
        exitPoolCalls[0] = FuseAction(
            address(curvePoolSupplyFuse),
            abi.encodeWithSignature(
                "exit((address,uint256,address,uint256))",
                CurveStableswapNGSingleSideSupplyFuseExitData({
                    curveStableswapNG: CURVE_POOL,
                    lpTokenAmount: lpTokensToRemove,
                    asset: BOLD,
                    minCoinAmountReceived: 0
                })
            )
        );
        vm.prank(alpha);
        plasmaVault.execute(exitPoolCalls);

        PlasmaVaultState memory stateAfterExit = _getPlasmaVaultState();
        assertEq(stateAfterExit.vaultLpTokensBalance, 0, "LP tokens should be 0 after removing liquidity");
        assertGt(stateAfterExit.vaultBoldBalance, 0, "BOLD balance should be > 0 after removing liquidity");
        assertEq(
            stateAfterExit.vaultTotalAssetsInCurvePool,
            0,
            "Total assets in Curve pool should be 0 after removing liquidity"
        );
        assertGt(stateAfterExit.vaultTotalAssets, 0, "Total assets should be > 0 at end of flow");
    }

    // ======================== FACTORY SETUP ========================

    function _deployFreshFusionFactory() internal returns (FusionFactory) {
        FusionFactory existingFactory = FusionFactory(EXISTING_FUSION_FACTORY_PROXY);

        FusionFactory newFactory = _createFactoryProxy(existingFactory);

        _configureFactoryRoles(newFactory);
        _configureFactoryBaseAddresses(newFactory, existingFactory);
        _configureFactorySettings(newFactory, existingFactory);
        _configureFactoryFeePackages(newFactory);

        return newFactory;
    }

    function _createFactoryProxy(FusionFactory existingFactory) private returns (FusionFactory) {
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses;
        factoryAddresses.plasmaVaultFactory = address(new PlasmaVaultFactory());
        factoryAddresses.feeManagerFactory = address(new FeeManagerFactory());
        factoryAddresses.accessManagerFactory = address(new AccessManagerFactory());
        factoryAddresses.priceManagerFactory = address(new PriceManagerFactory());
        factoryAddresses.withdrawManagerFactory = address(new WithdrawManagerFactory());
        factoryAddresses.rewardsManagerFactory = address(new RewardsManagerFactory());
        factoryAddresses.contextManagerFactory = address(new ContextManagerFactory());

        FusionFactory implementation = new FusionFactory();
        bytes memory initData = abi.encodeWithSelector(
            FusionFactory.initialize.selector,
            owner,
            existingFactory.getPlasmaVaultAdminArray(),
            factoryAddresses,
            existingFactory.getPlasmaVaultBaseAddress(),
            existingFactory.getPriceOracleMiddleware(),
            existingFactory.getBurnRequestFeeFuseAddress(),
            existingFactory.getBurnRequestFeeBalanceFuseAddress()
        );
        return FusionFactory(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _configureFactoryRoles(FusionFactory factory) private {
        vm.startPrank(owner);
        factory.grantRole(factory.DAO_FEE_MANAGER_ROLE(), daoFeeManager);
        factory.grantRole(factory.MAINTENANCE_MANAGER_ROLE(), owner);
        vm.stopPrank();
    }

    function _configureFactoryBaseAddresses(FusionFactory factory, FusionFactory existingFactory) private {
        FusionFactoryStorageLib.BaseAddresses memory existingBases = existingFactory.getBaseAddresses();
        existingBases.plasmaVaultCoreBase = address(new PlasmaVault());
        uint256 version = existingFactory.getFusionFactoryVersion();
        address pvBase = existingFactory.getPlasmaVaultBaseAddress();

        vm.prank(owner);
        factory.updateBaseAddresses(
            version,
            existingBases.plasmaVaultCoreBase,
            existingBases.accessManagerBase,
            existingBases.priceManagerBase,
            existingBases.withdrawManagerBase,
            existingBases.rewardsManagerBase,
            existingBases.contextManagerBase
        );

        vm.prank(owner);
        factory.updatePlasmaVaultBase(pvBase);
    }

    function _configureFactorySettings(FusionFactory factory, FusionFactory existingFactory) private {
        uint256 vestingPeriod = existingFactory.getVestingPeriodInSeconds();
        uint256 withdrawWindow = existingFactory.getWithdrawWindowInSeconds();

        vm.prank(owner);
        factory.updateVestingPeriodInSeconds(vestingPeriod);

        vm.prank(owner);
        factory.updateWithdrawWindowInSeconds(withdrawWindow);
    }

    function _configureFactoryFeePackages(FusionFactory factory) private {
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 0,
            performanceFee: 0,
            feeRecipient: makeAddr("feeRecipient")
        });
        vm.prank(daoFeeManager);
        factory.setDaoFeePackages(packages);
    }

    // ======================== FUSE SETUP ========================

    function _setupFuses() private {
        curvePoolSupplyFuse = new CurveStableswapNGSingleSideSupplyFuse(IporFusionMarkets.CURVE_POOL);
        curveGaugeSupplyFuse = new CurveLiquidityGaugeV6SupplyFuse(IporFusionMarkets.CURVE_LP_GAUGE);
        curveGaugeClaimFuse = new CurveGaugeTokenClaimFuse(IporFusionMarkets.CURVE_LP_GAUGE);

        CurveStableswapNGSingleSideBalanceFuse curvePoolBalanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
            IporFusionMarkets.CURVE_POOL
        );
        CurveLiquidityGaugeV6BalanceFuse curveGaugeBalanceFuse = new CurveLiquidityGaugeV6BalanceFuse(
            IporFusionMarkets.CURVE_LP_GAUGE
        );

        // Add fuses
        address[] memory fuses = new address[](2);
        fuses[0] = address(curvePoolSupplyFuse);
        fuses[1] = address(curveGaugeSupplyFuse);
        vm.startPrank(fuseManager);
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);

        // Add balance fuses
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            IporFusionMarkets.CURVE_POOL,
            address(curvePoolBalanceFuse)
        );
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            IporFusionMarkets.CURVE_LP_GAUGE,
            address(curveGaugeBalanceFuse)
        );

        // Configure substrates
        bytes32[] memory substratesCurvePool = new bytes32[](1);
        substratesCurvePool[0] = PlasmaVaultConfigLib.addressToBytes32(CURVE_USDC_BOLD_POOL);
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(
            IporFusionMarkets.CURVE_POOL,
            substratesCurvePool
        );

        bytes32[] memory substratesCurveGauge = new bytes32[](1);
        substratesCurveGauge[0] = PlasmaVaultConfigLib.addressToBytes32(CURVE_GAUGE);
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(
            IporFusionMarkets.CURVE_LP_GAUGE,
            substratesCurveGauge
        );

        // Setup dependency graph: GAUGE depends on POOL
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.CURVE_LP_GAUGE;
        uint256[] memory dependencies = new uint256[](1);
        dependencies[0] = IporFusionMarkets.CURVE_POOL;
        uint256[][] memory dependencyMarkets = new uint256[][](1);
        dependencyMarkets[0] = dependencies;
        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, dependencyMarkets);
        vm.stopPrank();

        // Register claim fuse in RewardsClaimManager
        address[] memory rewardFuses = new address[](1);
        rewardFuses[0] = address(curveGaugeClaimFuse);
        vm.prank(fuseManager);
        rewardsClaimManager.addRewardFuses(rewardFuses);
    }

    // ======================== HELPERS ========================

    function _getPlasmaVaultState() internal view returns (PlasmaVaultState memory) {
        return
            PlasmaVaultState({
                vaultUsdcBalance: ERC20(USDC).balanceOf(address(plasmaVault)),
                vaultBoldBalance: ERC20(BOLD).balanceOf(address(plasmaVault)),
                vaultTotalAssets: plasmaVault.totalAssets(),
                vaultTotalAssetsInCurvePool: plasmaVault.totalAssetsInMarket(IporFusionMarkets.CURVE_POOL),
                vaultTotalAssetsInGauge: plasmaVault.totalAssetsInMarket(IporFusionMarkets.CURVE_LP_GAUGE),
                vaultLpTokensBalance: ERC20(CURVE_USDC_BOLD_POOL).balanceOf(address(plasmaVault)),
                vaultStakedLpTokensBalance: ERC20(CURVE_GAUGE).balanceOf(address(plasmaVault))
            });
    }
}
