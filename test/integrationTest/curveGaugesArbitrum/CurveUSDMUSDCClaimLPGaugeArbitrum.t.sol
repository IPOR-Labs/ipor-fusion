// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CurveStableswapNGSingleSideSupplyFuse, CurveStableswapNGSingleSideSupplyFuseEnterData, CurveStableswapNGSingleSideSupplyFuseExitData} from "../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideSupplyFuse.sol";
import {CurveStableswapNGSingleSideBalanceFuse} from "../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideBalanceFuse.sol";
import {CurveChildLiquidityGaugeSupplyFuse, CurveChildLiquidityGaugeSupplyFuseEnterData, CurveChildLiquidityGaugeSupplyFuseExitData} from "../../../contracts/fuses/curve_gauge/CurveChildLiquidityGaugeSupplyFuse.sol";
import {CurveChildLiquidityGaugeBalanceFuse} from "../../../contracts/fuses/curve_gauge/CurveChildLiquidityGaugeBalanceFuse.sol";
import {CurveGaugeTokenClaimFuse} from "../../../contracts/rewards_fuses/curve_gauges/CurveGaugeTokenClaimFuse.sol";
import {IChildLiquidityGauge} from "../../../contracts/fuses/curve_gauge/ext/IChildLiquidityGauge.sol";
import {ICurveStableswapNG} from "../../../contracts/fuses/curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {FeeConfig, FuseAction, PlasmaVault, MarketBalanceFuseConfig, MarketSubstratesConfig, PlasmaVaultInitData} from "./../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporPlasmaVault} from "./../../../contracts/vaults/IporPlasmaVault.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionAccessManager} from "./../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RoleLib, UsersToRoles} from "./../../RoleLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/priceOracle/PriceOracleMiddleware.sol";
import {USDMPriceFeedArbitrum} from "../../../contracts/priceOracle/priceFeed/USDMPriceFeedArbitrum.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InitializationData} from "../../../contracts/managers/access/IporFusionAccessManagerInitializationLib.sol";
import {IporFusionMarketsArbitrum} from "../../../contracts/libraries/IporFusionMarketsArbitrum.sol";
import {IChronicle, IToll} from "../../../contracts/priceOracle/IChronicle.sol";

contract CurveUSDMUSDCClaimLPGaugeArbitrum is Test {
    struct PlasmaVaultState {
        uint256 vaultBalance;
        uint256 vaultTotalAssets;
        uint256 vaultTotalAssetsInCurvePool;
        uint256 vaultTotalAssetsInGauge;
        uint256 vaultLpTokensBalance;
        uint256 vaultStakedLpTokensBalance;
        uint256 vaultNumberRewardTokens;
        address[] vaultRewardTokens;
        uint256[] vaultClaimedRewardTokens;
        uint256[] vaultClaimableRewardTokens;
        uint256[] rewardsClaimManagerBalanceRewardTokens;
    }

    UsersToRoles public usersToRoles;

    /// USDC/USDM Curve pool LP on Arbitrum
    address public constant CURVE_STABLESWAP_NG_POOL = 0x4bD135524897333bec344e50ddD85126554E58B4;
    /// Curve LP token
    ICurveStableswapNG public constant CURVE_STABLESWAP_NG = ICurveStableswapNG(CURVE_STABLESWAP_NG_POOL);
    /// Gauge for LP token
    address public constant CHILD_LIQUIDITY_GAUGE = 0xbdBb71914DdB650F96449b54d2CA15132Be56Aca;
    IChildLiquidityGauge public constant CURVE_LIQUIDITY_GAUGE = IChildLiquidityGauge(CHILD_LIQUIDITY_GAUGE);

    /// Assets
    address public asset;
    address public constant BASE_CURRENCY = 0x0000000000000000000000000000000000000348;
    uint256 public constant BASE_CURRENCY_DECIMALS = 8;
    address public constant USDM = 0x59D9356E565Ab3A36dD77763Fc0d87fEaf85508C;
    address public constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address public constant ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548;

    /// Oracles
    PriceOracleMiddleware private priceOracleMiddlewareProxy;
    address public constant CHRONICLE_ADMIN = 0x39aBD7819E5632Fa06D2ECBba45Dca5c90687EE3;
    address public constant WUSDM_USD_ORACLE_FEED = 0xdC6720c996Fad27256c7fd6E0a271e2A4687eF18;
    address public constant CHAINLINK_ARB = 0xb2A824043730FE05F3DA2efaFa1CBbe83fa548D6;
    IChronicle public constant CHRONICLE = IChronicle(WUSDM_USD_ORACLE_FEED);
    // solhint-disable-next-line
    USDMPriceFeedArbitrum public USDMPriceFeed;

    /// Vaults
    IporPlasmaVault public plasmaVault;

    /// Fuses
    address[] public fuses;
    address[] public claimFuses;
    CurveStableswapNGSingleSideSupplyFuse public curveStableswapNGSingleSideSupplyFuse;
    CurveChildLiquidityGaugeSupplyFuse public curveChildLiquidityGaugeSupplyFuse;
    CurveGaugeTokenClaimFuse public curveGaugeTokenClaimFuse;

    /// Users
    address private admin = address(this);
    address public alpha = address(0x1);
    address public depositor = address(0x2);
    address public atomist = address(0x3);
    address public constant OWNER = 0xD92E9F039E4189c342b4067CC61f5d063960D248;
    RewardsClaimManager public rewardsClaimManager;
    IporFusionAccessManager public accessManager;
    address[] public alphas;

    /// Events
    event CurveGaugeTokenClaimFuseRewardsClaimed(
        address version,
        address gauge,
        address[] rewardsTokens,
        uint256[] rewardsTokenBalances,
        address rewardsClaimManager
    );

    function setUp() public {
        _setupFork();
        _init();
    }

    /// CLAIM REWARDS TESTS
    function testShouldBeAbleToClaimGaugeRewards() public {
        // given
        uint256 amount = 1_000 * 10 ** ERC20(asset).decimals();

        _depositIntoVaultAndProvideLiquidityToCurvePool(amount);
        PlasmaVaultState memory vaultStateAfterEnterCurvePool = getPlasmaVaultState();

        _executeCurveChildLiquidityGaugeSupplyFuseEnter(
            curveChildLiquidityGaugeSupplyFuse,
            CURVE_LIQUIDITY_GAUGE,
            CURVE_STABLESWAP_NG_POOL,
            vaultStateAfterEnterCurvePool.vaultLpTokensBalance
        );
        PlasmaVaultState memory vaultStateAfterEnterCurveGauge = getPlasmaVaultState();

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarketsArbitrum.CURVE_LP_GAUGE;

        uint256[] memory dependencies = new uint256[](1);
        dependencies[0] = IporFusionMarketsArbitrum.CURVE_POOL;

        uint256[][] memory dependencyMarkets = new uint256[][](1);
        dependencyMarkets[0] = dependencies;

        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, dependencyMarkets);

        vm.prank(address(plasmaVault));
        CURVE_LIQUIDITY_GAUGE.user_checkpoint(address(plasmaVault));

        vm.warp(block.timestamp + 100 days);
        vm.roll(block.number + 720000);

        vm.prank(address(plasmaVault));
        CURVE_LIQUIDITY_GAUGE.user_checkpoint(address(plasmaVault));

        // when
        FuseAction[] memory rewardsClaimCalls = new FuseAction[](1);
        rewardsClaimCalls[0] = FuseAction(address(curveGaugeTokenClaimFuse), abi.encodeWithSignature("claim()"));
        rewardsClaimManager.claimRewards(rewardsClaimCalls);

        PlasmaVaultState memory vaultStateAfterClaiming = getPlasmaVaultState();

        // then
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultBalance,
            vaultStateAfterClaiming.vaultBalance,
            "Vault balance should not change after claiming rewards"
        );
        assertEq(vaultStateAfterEnterCurveGauge.vaultBalance, 0, "Vault balance should be 0 after enter curve gauge");
        assertEq(vaultStateAfterClaiming.vaultBalance, 0, "Vault balance should be 0 after claiming rewards");
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssets,
            vaultStateAfterClaiming.vaultTotalAssets,
            "Vault total assets should not change after claiming rewards"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInCurvePool,
            vaultStateAfterClaiming.vaultTotalAssetsInCurvePool,
            "Vault total assets in curve pool should not change after claiming rewards"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInGauge,
            vaultStateAfterClaiming.vaultTotalAssetsInGauge,
            "Vault total assets in gauge should not change after claiming rewards"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultLpTokensBalance,
            vaultStateAfterClaiming.vaultLpTokensBalance,
            "Vault LP tokens balance should not change after claiming rewards"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultLpTokensBalance,
            0,
            "Vault LP tokens balance should be zero before claiming rewards"
        );
        assertEq(
            vaultStateAfterClaiming.vaultLpTokensBalance,
            0,
            "Vault LP tokens balance should be zero after claiming rewards"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultStakedLpTokensBalance,
            vaultStateAfterClaiming.vaultStakedLpTokensBalance,
            "Vault staked LP tokens balance should not change after claiming rewards"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultNumberRewardTokens,
            vaultStateAfterClaiming.vaultNumberRewardTokens,
            "Vault number reward tokens should not change after claiming rewards"
        );
        assertEq(vaultStateAfterEnterCurveGauge.vaultNumberRewardTokens, 2, "Number of reward tokens should be 2");
        for (uint256 i = 0; i < vaultStateAfterClaiming.vaultNumberRewardTokens; ++i) {
            // if USDM the balance should be 0 both before and after claiming rewards
            if (vaultStateAfterEnterCurveGauge.vaultRewardTokens[i] == USDM) {
                assertEq(
                    vaultStateAfterEnterCurveGauge.vaultClaimedRewardTokens[i],
                    0,
                    "Claimed reward token should be 0 before claiming rewards"
                );
                assertEq(
                    vaultStateAfterClaiming.vaultClaimedRewardTokens[i],
                    0,
                    "Claimed reward token should be 0 after claiming rewards"
                );
                assertEq(
                    vaultStateAfterEnterCurveGauge.vaultClaimableRewardTokens[i],
                    0,
                    "Claimable reward token should be 0 before claiming rewards"
                );
                assertEq(
                    vaultStateAfterClaiming.vaultClaimableRewardTokens[i],
                    0,
                    "Claimable reward token should be 0 after claiming rewards"
                );
                assertEq(
                    vaultStateAfterEnterCurveGauge.rewardsClaimManagerBalanceRewardTokens[i],
                    0,
                    "Rewards claim manager balance reward token should be 0 before claiming rewards"
                );
                assertEq(
                    vaultStateAfterClaiming.rewardsClaimManagerBalanceRewardTokens[i],
                    0,
                    "Rewards claim manager balance reward token should be 0 after claiming rewards"
                );
            }
            // if ARB the balance should be 0 before claiming and greater than 0 after claiming rewards
            if (vaultStateAfterEnterCurveGauge.vaultRewardTokens[i] == ARB) {
                assertEq(
                    vaultStateAfterEnterCurveGauge.vaultClaimedRewardTokens[i],
                    0,
                    "Claimed reward token should be 0 before claiming rewards"
                );
                assertGt(
                    vaultStateAfterClaiming.vaultClaimedRewardTokens[i],
                    0,
                    "Claimed reward token should be greater than 0 after claiming rewards"
                );
                assertEq(
                    vaultStateAfterClaiming.vaultClaimedRewardTokens[i],
                    1811599891227558447,
                    "Claimed reward token should be 1811599891227558447 after claiming rewards"
                );
                assertEq(
                    vaultStateAfterEnterCurveGauge.vaultClaimableRewardTokens[i],
                    0,
                    "Claimable reward token should be 0 before claiming rewards"
                );
                assertEq(
                    vaultStateAfterClaiming.vaultClaimableRewardTokens[i],
                    0,
                    "Claimable reward token should be 0 after claiming rewards"
                );
                assertEq(
                    vaultStateAfterEnterCurveGauge.rewardsClaimManagerBalanceRewardTokens[i],
                    0,
                    "Rewards claim manager balance reward token should be 0 before claiming rewards"
                );
                assertGt(
                    vaultStateAfterClaiming.rewardsClaimManagerBalanceRewardTokens[i],
                    0,
                    "Rewards claim manager balance reward token should be greater than 0 after claiming rewards"
                );
                assertEq(
                    vaultStateAfterClaiming.rewardsClaimManagerBalanceRewardTokens[i],
                    1811599891227558447,
                    "Rewards claim manager balance reward token should be 1811599891227558447 after claiming rewards"
                );
            }
        }
    }

    /// @dev no rewards available (nothing accrued)
    function testShouldNotBeAbleToReceiveTokensWhenNoRewardsAvailable() public {
        // given
        uint256 amount = 1_000 * 10 ** ERC20(asset).decimals();

        _depositIntoVaultAndProvideLiquidityToCurvePool(amount);
        PlasmaVaultState memory vaultStateAfterEnterCurvePool = getPlasmaVaultState();

        _executeCurveChildLiquidityGaugeSupplyFuseEnter(
            curveChildLiquidityGaugeSupplyFuse,
            CURVE_LIQUIDITY_GAUGE,
            CURVE_STABLESWAP_NG_POOL,
            vaultStateAfterEnterCurvePool.vaultLpTokensBalance
        );
        PlasmaVaultState memory vaultStateAfterEnterCurveGauge = getPlasmaVaultState();

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarketsArbitrum.CURVE_LP_GAUGE;

        uint256[] memory dependencies = new uint256[](1);
        dependencies[0] = IporFusionMarketsArbitrum.CURVE_POOL;

        uint256[][] memory dependencyMarkets = new uint256[][](1);
        dependencyMarkets[0] = dependencies;

        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, dependencyMarkets);

        // when
        FuseAction[] memory rewardsClaimCalls = new FuseAction[](1);
        rewardsClaimCalls[0] = FuseAction(address(curveGaugeTokenClaimFuse), abi.encodeWithSignature("claim()"));
        rewardsClaimManager.claimRewards(rewardsClaimCalls);

        PlasmaVaultState memory vaultStateAfterClaiming = getPlasmaVaultState();

        // then
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultBalance,
            vaultStateAfterClaiming.vaultBalance,
            "Vault balance should not change after claiming rewards"
        );
        assertEq(vaultStateAfterEnterCurveGauge.vaultBalance, 0, "Vault balance should be 0 after enter curve gauge");
        assertEq(vaultStateAfterClaiming.vaultBalance, 0, "Vault balance should be 0 after claiming rewards");
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssets,
            vaultStateAfterClaiming.vaultTotalAssets,
            "Vault total assets should not change after claiming rewards"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInCurvePool,
            vaultStateAfterClaiming.vaultTotalAssetsInCurvePool,
            "Vault total assets in curve pool should not change after claiming rewards"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInGauge,
            vaultStateAfterClaiming.vaultTotalAssetsInGauge,
            "Vault total assets in gauge should not change after claiming rewards"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultLpTokensBalance,
            vaultStateAfterClaiming.vaultLpTokensBalance,
            "Vault LP tokens balance should not change after claiming rewards"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultLpTokensBalance,
            0,
            "Vault LP tokens balance should be zero before claiming rewards"
        );
        assertEq(
            vaultStateAfterClaiming.vaultLpTokensBalance,
            0,
            "Vault LP tokens balance should be zero after claiming rewards"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultStakedLpTokensBalance,
            vaultStateAfterClaiming.vaultStakedLpTokensBalance,
            "Vault staked LP tokens balance should not change after claiming rewards"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultNumberRewardTokens,
            vaultStateAfterClaiming.vaultNumberRewardTokens,
            "Vault number reward tokens should not change after claiming rewards"
        );
        assertEq(vaultStateAfterEnterCurveGauge.vaultNumberRewardTokens, 2, "Number of reward tokens should be 2");
        for (uint256 i = 0; i < vaultStateAfterClaiming.vaultNumberRewardTokens; ++i) {
            assertEq(
                vaultStateAfterEnterCurveGauge.vaultRewardTokens[i],
                vaultStateAfterClaiming.vaultRewardTokens[i],
                "Vault reward tokens should not change after claiming rewards"
            );
            assertEq(
                vaultStateAfterEnterCurveGauge.vaultClaimedRewardTokens[i],
                vaultStateAfterClaiming.vaultClaimedRewardTokens[i],
                "Vault claimed reward tokens should not change after claiming rewards"
            );
            assertEq(
                vaultStateAfterEnterCurveGauge.vaultClaimedRewardTokens[i],
                0,
                "Vault claimed reward tokens should be 0 before claiming rewards"
            );
            assertEq(
                vaultStateAfterClaiming.vaultClaimedRewardTokens[i],
                0,
                "Vault claimed reward tokens should be 0 after claiming rewards"
            );
            assertEq(
                vaultStateAfterEnterCurveGauge.vaultClaimableRewardTokens[i],
                vaultStateAfterClaiming.vaultClaimableRewardTokens[i],
                "Vault claimable reward tokens should not change after claiming rewards"
            );
            assertEq(
                vaultStateAfterEnterCurveGauge.vaultClaimableRewardTokens[i],
                0,
                "Vault claimable reward tokens should be 0 before claiming rewards"
            );
            assertEq(
                vaultStateAfterClaiming.vaultClaimableRewardTokens[i],
                0,
                "Vault claimable reward tokens should be 0 after claiming rewards"
            );
            assertEq(
                vaultStateAfterEnterCurveGauge.rewardsClaimManagerBalanceRewardTokens[i],
                vaultStateAfterClaiming.rewardsClaimManagerBalanceRewardTokens[i],
                "Rewards claim manager balance reward tokens should not change after claiming rewards"
            );
            assertEq(
                vaultStateAfterEnterCurveGauge.rewardsClaimManagerBalanceRewardTokens[i],
                0,
                "Rewards claim manager balance reward tokens should be 0 before claiming rewards"
            );
            assertEq(
                vaultStateAfterClaiming.rewardsClaimManagerBalanceRewardTokens[i],
                0,
                "Rewards claim manager balance reward tokens should be 0 after claiming rewards"
            );
        }
    }

    /// SETUP HELPERS

    function _setupFork() private {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 244084803);
    }

    function _init() private {
        _setupAsset();
        _setupPriceOracle();
        _setupFuses();
        _createAlphas();
        _createAccessManager();
        _createPlasmaVault();
        _createClaimRewardsManager();
        _setupPlasmaVault();
        _createClaimFuse();
        _addClaimFuseToClaimRewardsManager();
        _initAccessManager();
    }

    function _setupAsset() public {
        asset = USDM;
    }

    function dealAsset(address asset_, address account_, uint256 amount_) public {
        vm.prank(0x426c4966fC76Bf782A663203c023578B744e4C5E); // USDM (asset) holder
        ERC20(asset_).transfer(account_, amount_);
    }

    function _setupPriceOracleSources() private returns (address[] memory assets, address[] memory sources) {
        USDMPriceFeed = new USDMPriceFeedArbitrum();
        vm.prank(CHRONICLE_ADMIN);
        IToll(address(CHRONICLE)).kiss(address(USDMPriceFeed));
        assets = new address[](2);
        sources = new address[](2);
        assets[0] = USDM;
        assets[1] = ARB;
        sources[0] = address(USDMPriceFeed);
        sources[1] = CHAINLINK_ARB;
    }

    function _setupPriceOracle() private {
        address[] memory assets;
        address[] memory sources;
        (assets, sources) = _setupPriceOracleSources();
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(
            BASE_CURRENCY,
            BASE_CURRENCY_DECIMALS,
            0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf
        );
        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", OWNER)))
        );
        vm.prank(OWNER);
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);
    }

    function _setupFuses() private {
        curveStableswapNGSingleSideSupplyFuse = new CurveStableswapNGSingleSideSupplyFuse(
            IporFusionMarketsArbitrum.CURVE_POOL
        );
        curveChildLiquidityGaugeSupplyFuse = new CurveChildLiquidityGaugeSupplyFuse(
            IporFusionMarketsArbitrum.CURVE_LP_GAUGE
        );

        fuses = new address[](2);
        fuses[0] = address(curveStableswapNGSingleSideSupplyFuse);
        fuses[1] = address(curveChildLiquidityGaugeSupplyFuse);
    }

    function _createClaimFuse() private {
        curveGaugeTokenClaimFuse = new CurveGaugeTokenClaimFuse(IporFusionMarketsArbitrum.CURVE_LP_GAUGE);
    }

    function _createAlphas() private {
        alphas = new address[](1);
        alphas[0] = alpha;
    }

    function _createAccessManager() private {
        if (usersToRoles.superAdmin == address(0)) {
            usersToRoles.superAdmin = admin;
            usersToRoles.atomist = atomist;
            usersToRoles.alphas = alphas;
        }
        accessManager = IporFusionAccessManager(RoleLib.createAccessManager(usersToRoles, vm));
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager);
    }

    function _createClaimRewardsManager() private {
        rewardsClaimManager = new RewardsClaimManager(address(accessManager), address(plasmaVault));
    }

    function _createPlasmaVault() private {
        plasmaVault = new IporPlasmaVault(
            PlasmaVaultInitData({
                assetName: "PLASMA VAULT",
                assetSymbol: "PLASMA",
                underlyingToken: asset,
                priceOracle: address(priceOracleMiddlewareProxy),
                alphas: alphas,
                marketSubstratesConfigs: _setupMarketConfigs(),
                fuses: fuses,
                balanceFuses: _setupBalanceFuses(),
                feeConfig: _setupFeeConfig(),
                accessManager: address(accessManager)
            })
        );
    }

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](2);
        bytes32[] memory substratesCurvePool = new bytes32[](1);
        substratesCurvePool[0] = PlasmaVaultConfigLib.addressToBytes32(CURVE_STABLESWAP_NG_POOL);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarketsArbitrum.CURVE_POOL, substratesCurvePool);

        bytes32[] memory substratesCurveGauge = new bytes32[](1);
        substratesCurveGauge[0] = PlasmaVaultConfigLib.addressToBytes32(CHILD_LIQUIDITY_GAUGE);
        marketConfigs[1] = MarketSubstratesConfig(IporFusionMarketsArbitrum.CURVE_LP_GAUGE, substratesCurveGauge);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        CurveStableswapNGSingleSideBalanceFuse curveStableswapNGBalanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
                IporFusionMarketsArbitrum.CURVE_POOL,
                address(priceOracleMiddlewareProxy)
            );

        CurveChildLiquidityGaugeBalanceFuse curveChildLiquidityGaugeBalanceFuse = new CurveChildLiquidityGaugeBalanceFuse(
                IporFusionMarketsArbitrum.CURVE_LP_GAUGE,
                address(priceOracleMiddlewareProxy)
            );

        balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(
            IporFusionMarketsArbitrum.CURVE_POOL,
            address(curveStableswapNGBalanceFuse)
        );
        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarketsArbitrum.CURVE_LP_GAUGE,
            address(curveChildLiquidityGaugeBalanceFuse)
        );
    }

    function _setupPlasmaVault() private {
        vm.prank(admin);
        PlasmaVaultGovernance(address(plasmaVault)).setRewardsClaimManagerAddress(address(rewardsClaimManager));
    }

    function _setupFeeConfig() private view returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfig({
            performanceFeeManager: address(this),
            performanceFeeInPercentage: 0,
            managementFeeManager: address(this),
            managementFeeInPercentage: 0
        });
    }

    function _addClaimFuseToClaimRewardsManager() private {
        claimFuses = new address[](1);
        claimFuses[0] = address(curveGaugeTokenClaimFuse);
        rewardsClaimManager.addRewardFuses(claimFuses);
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](1);
        initAddress[0] = admin;

        DataForInitialization memory data = DataForInitialization({
            admins: initAddress,
            owners: initAddress,
            atomists: initAddress,
            alphas: initAddress,
            whitelist: initAddress,
            guardians: initAddress,
            fuseManagers: initAddress,
            performanceFeeManagers: initAddress,
            managementFeeManagers: initAddress,
            claimRewards: initAddress,
            transferRewardsManagers: initAddress,
            configInstantWithdrawalFusesManagers: initAddress,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: address(plasmaVault),
                accessManager: address(accessManager),
                rewardsClaimManager: address(rewardsClaimManager),
                feeManager: address(this)
            })
        });
        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        accessManager.initialize(initializationData);
    }

    /// HELPERS
    function _depositIntoVaultAndProvideLiquidityToCurvePool(uint256 amount) private {
        dealAsset(asset, admin, amount);
        vm.startPrank(admin);
        ERC20(asset).approve(address(plasmaVault), amount);
        plasmaVault.deposit(amount, address(admin));
        vm.stopPrank();
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(curveStableswapNGSingleSideSupplyFuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    CurveStableswapNGSingleSideSupplyFuseEnterData({
                        curveStableswapNG: CURVE_STABLESWAP_NG,
                        asset: asset,
                        amount: amount,
                        minMintAmount: 0
                    })
                )
            )
        );
        vm.prank(alpha);
        plasmaVault.execute(calls);
    }

    function _executeCurveChildLiquidityGaugeSupplyFuseEnter(
        CurveChildLiquidityGaugeSupplyFuse fuseInstance,
        IChildLiquidityGauge curveGauge,
        address lpToken,
        uint256 amount
    ) internal {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(fuseInstance),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    CurveChildLiquidityGaugeSupplyFuseEnterData({
                        childLiquidityGauge: curveGauge,
                        lpToken: lpToken,
                        amount: amount
                    })
                )
            )
        );

        vm.prank(alpha);
        plasmaVault.execute(calls);
    }

    function getPlasmaVaultState() public view returns (PlasmaVaultState memory) {
        PlasmaVaultState memory state;
        state.vaultBalance = ERC20(asset).balanceOf(address(plasmaVault));
        state.vaultTotalAssets = plasmaVault.totalAssets();
        state.vaultTotalAssetsInCurvePool = plasmaVault.totalAssetsInMarket(
            curveStableswapNGSingleSideSupplyFuse.MARKET_ID()
        );
        state.vaultTotalAssetsInGauge = plasmaVault.totalAssetsInMarket(curveChildLiquidityGaugeSupplyFuse.MARKET_ID());
        state.vaultLpTokensBalance = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(plasmaVault));
        state.vaultStakedLpTokensBalance = ERC20(CHILD_LIQUIDITY_GAUGE).balanceOf(address(plasmaVault));
        state.vaultNumberRewardTokens = CURVE_LIQUIDITY_GAUGE.reward_count();
        state.vaultRewardTokens = new address[](state.vaultNumberRewardTokens);
        state.vaultClaimedRewardTokens = new uint256[](state.vaultNumberRewardTokens);
        state.vaultClaimableRewardTokens = new uint256[](state.vaultNumberRewardTokens);
        state.rewardsClaimManagerBalanceRewardTokens = new uint256[](state.vaultNumberRewardTokens);
        for (uint256 i = 0; i < state.vaultNumberRewardTokens; ++i) {
            state.vaultRewardTokens[i] = CURVE_LIQUIDITY_GAUGE.reward_tokens(i);
            state.vaultClaimedRewardTokens[i] = CURVE_LIQUIDITY_GAUGE.claimed_reward(
                address(plasmaVault),
                state.vaultRewardTokens[i]
            );
            state.vaultClaimableRewardTokens[i] = CURVE_LIQUIDITY_GAUGE.claimable_reward(
                address(plasmaVault),
                state.vaultRewardTokens[i]
            );
            state.rewardsClaimManagerBalanceRewardTokens[i] = ERC20(state.vaultRewardTokens[i]).balanceOf(
                address(rewardsClaimManager)
            );
        }
        return state;
    }
}
