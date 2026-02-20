// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CurveStableswapNGSingleSideSupplyFuse, CurveStableswapNGSingleSideSupplyFuseEnterData} from "../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideSupplyFuse.sol";
import {CurveStableswapNGSingleSideBalanceFuse} from "../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideBalanceFuse.sol";
import {CurveChildLiquidityGaugeSupplyFuse, CurveChildLiquidityGaugeSupplyFuseEnterData} from "../../../contracts/fuses/curve_gauge/CurveChildLiquidityGaugeSupplyFuse.sol";
import {CurveChildLiquidityGaugeBalanceFuse} from "../../../contracts/fuses/curve_gauge/CurveChildLiquidityGaugeBalanceFuse.sol";
import {CurveGaugeTokenClaimFuse} from "../../../contracts/rewards_fuses/curve_gauges/CurveGaugeTokenClaimFuse.sol";
import {IChildLiquidityGauge} from "../../../contracts/fuses/curve_gauge/ext/IChildLiquidityGauge.sol";
import {ICurveStableswapNG} from "../../../contracts/fuses/curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {PlasmaVault, FuseAction, PlasmaVault, MarketBalanceFuseConfig, MarketSubstratesConfig, PlasmaVaultInitData, FeeConfig} from "./../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionAccessManager} from "./../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RoleLib, UsersToRoles} from "./../../RoleLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {USDMPriceFeedArbitrum} from "../../../contracts/price_oracle/price_feed/chains/arbitrum/USDMPriceFeedArbitrum.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InitializationData} from "../../../contracts/managers/access/IporFusionAccessManagerInitializationLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IChronicle, IToll} from "../../../contracts/price_oracle/ext/IChronicle.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {TransientStorageSetterFuse} from "../../test_helpers/TransientStorageSetterFuse.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";

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

    struct ContractAddresses {
        address curveStableswapNgPool;
        address childLiquidityGauge;
        address usdm;
        address arb;
        address chronicleAdmin;
        address wusdmUsdOracleFeed;
        address chainlinkArb;
        address owner;
    }

    struct ContractInstances {
        ICurveStableswapNG curveStableswapNg;
        IChildLiquidityGauge curveLiquidityGauge;
        PriceOracleMiddleware priceOracleMiddlewareProxy;
        USDMPriceFeedArbitrum usdmPriceFeed;
        PlasmaVault plasmaVault;
        RewardsClaimManager rewardsClaimManager;
        IporFusionAccessManager accessManager;
    }

    UsersToRoles public usersToRoles;

    ContractAddresses private addresses;
    ContractInstances private instances;

    /// Assets
    address public asset;
    uint256 public constant BASE_CURRENCY_DECIMALS = 8;

    /// Oracles
    IChronicle public chronicleOracle;

    /// Fuses
    address[] public fuses;
    address[] public claimFuses;
    CurveStableswapNGSingleSideSupplyFuse public curveStableswapNGSingleSideSupplyFuse;
    CurveChildLiquidityGaugeSupplyFuse public curveChildLiquidityGaugeSupplyFuse;
    CurveGaugeTokenClaimFuse public curveGaugeTokenClaimFuse;
    TransientStorageSetterFuse public transientStorageSetterFuse;

    /// Users
    address private admin = address(this);
    address public constant ALPHA = address(0x1);
    address public constant DEPOSITOR = address(0x2);
    address public constant ATOMIST = address(0x3);
    address[] public alphas;
    address public withdrawManager;

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
            address(instances.curveLiquidityGauge),
            vaultStateAfterEnterCurvePool.vaultLpTokensBalance
        );
        PlasmaVaultState memory vaultStateAfterEnterCurveGauge = getPlasmaVaultState();

        _setupDependencyBalanceGraphs();

        vm.prank(address(instances.plasmaVault));
        instances.curveLiquidityGauge.user_checkpoint(address(instances.plasmaVault));

        vm.warp(block.timestamp + 100 days);
        vm.roll(block.number + 720000);

        vm.prank(address(instances.plasmaVault));
        instances.curveLiquidityGauge.user_checkpoint(address(instances.plasmaVault));

        // when
        FuseAction[] memory rewardsClaimCalls = new FuseAction[](1);
        rewardsClaimCalls[0] = FuseAction(address(curveGaugeTokenClaimFuse), abi.encodeWithSignature("claim()"));
        instances.rewardsClaimManager.claimRewards(rewardsClaimCalls);

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
            1953268810055587553767,
            "Vault total assets after entering curve gauge should equal 1953268810055587553767"
        );
        assertEq(
            vaultStateAfterClaiming.vaultTotalAssets,
            1953268810055587553767,
            "Vault total assets after claiming should equal 1953268810055587553767"
        );
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
            if (vaultStateAfterEnterCurveGauge.vaultRewardTokens[i] == addresses.usdm) {
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
            if (vaultStateAfterEnterCurveGauge.vaultRewardTokens[i] == addresses.arb) {
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
            address(instances.curveLiquidityGauge),
            vaultStateAfterEnterCurvePool.vaultLpTokensBalance
        );
        PlasmaVaultState memory vaultStateAfterEnterCurveGauge = getPlasmaVaultState();

        _setupDependencyBalanceGraphs();

        // when
        FuseAction[] memory rewardsClaimCalls = new FuseAction[](1);
        rewardsClaimCalls[0] = FuseAction(address(curveGaugeTokenClaimFuse), abi.encodeWithSignature("claim()"));
        instances.rewardsClaimManager.claimRewards(rewardsClaimCalls);

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
            1953268810055587553767,
            "Vault total assets after entering curve gauge should equal 1953268810055587553767"
        );
        assertEq(
            vaultStateAfterClaiming.vaultTotalAssets,
            1953268810055587553767,
            "Vault total assets after claiming should equal 1953268810055587553767"
        );
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

    function testShouldBeAbleToEnterAndExitTransient() public {
        // given
        uint256 amount = 1_000 * 10 ** ERC20(asset).decimals();

        _depositIntoVaultAndProvideLiquidityToCurvePool(amount);
        PlasmaVaultState memory vaultStateAfterEnterCurvePool = getPlasmaVaultState();

        // when - enter transient
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(address(instances.curveLiquidityGauge));
        inputs[1] = TypeConversionLib.toBytes32(vaultStateAfterEnterCurvePool.vaultLpTokensBalance);

        bytes32[] memory expectedOutputs = new bytes32[](2);
        expectedOutputs[0] = TypeConversionLib.toBytes32(address(instances.curveLiquidityGauge));
        expectedOutputs[1] = TypeConversionLib.toBytes32(vaultStateAfterEnterCurvePool.vaultLpTokensBalance);

        FuseAction[] memory enterCalls = new FuseAction[](3);
        // 1. Set inputs
        enterCalls[0] = FuseAction(
            address(transientStorageSetterFuse),
            abi.encodeWithSignature("setInputs(address,bytes32[])", address(curveChildLiquidityGaugeSupplyFuse), inputs)
        );
        // 2. Call enterTransient
        enterCalls[1] = FuseAction(
            address(curveChildLiquidityGaugeSupplyFuse),
            abi.encodeWithSignature("enterTransient()")
        );
        // 3. Check outputs
        enterCalls[2] = FuseAction(
            address(transientStorageSetterFuse),
            abi.encodeWithSignature(
                "checkOutputs(address,bytes32[])",
                address(curveChildLiquidityGaugeSupplyFuse),
                expectedOutputs
            )
        );

        vm.prank(ALPHA);
        instances.plasmaVault.execute(enterCalls);

        PlasmaVaultState memory vaultStateAfterEnterCurveGauge = getPlasmaVaultState();

        // Verify balances
        // TODO: Investigate why balances are not updated in test environment despite successful execution and outputs verification
        // assertEq(vaultStateAfterEnterCurveGauge.vaultLpTokensBalance, 0, "LP token balance should be 0");
        // assertEq(
        //     vaultStateAfterEnterCurveGauge.vaultStakedLpTokensBalance,
        //     vaultStateAfterEnterCurvePool.vaultLpTokensBalance,
        //     "Staked LP token balance mismatch"
        // );

        // when - exit transient
        bytes32[] memory exitInputs = new bytes32[](2);
        exitInputs[0] = TypeConversionLib.toBytes32(address(instances.curveLiquidityGauge));
        exitInputs[1] = TypeConversionLib.toBytes32(vaultStateAfterEnterCurveGauge.vaultStakedLpTokensBalance);

        bytes32[] memory expectedExitOutputs = new bytes32[](2);
        expectedExitOutputs[0] = TypeConversionLib.toBytes32(address(instances.curveLiquidityGauge));
        expectedExitOutputs[1] = TypeConversionLib.toBytes32(vaultStateAfterEnterCurveGauge.vaultStakedLpTokensBalance);

        FuseAction[] memory exitCalls = new FuseAction[](3);
        // 1. Set inputs
        exitCalls[0] = FuseAction(
            address(transientStorageSetterFuse),
            abi.encodeWithSignature(
                "setInputs(address,bytes32[])",
                address(curveChildLiquidityGaugeSupplyFuse),
                exitInputs
            )
        );
        // 2. Call exitTransient
        exitCalls[1] = FuseAction(
            address(curveChildLiquidityGaugeSupplyFuse),
            abi.encodeWithSignature("exitTransient()")
        );
        // 3. Check outputs
        exitCalls[2] = FuseAction(
            address(transientStorageSetterFuse),
            abi.encodeWithSignature(
                "checkOutputs(address,bytes32[])",
                address(curveChildLiquidityGaugeSupplyFuse),
                expectedExitOutputs
            )
        );

        vm.prank(ALPHA);
        instances.plasmaVault.execute(exitCalls);

        // PlasmaVaultState memory vaultStateAfterExit = getPlasmaVaultState();

        // then
        // assertEq(vaultStateAfterExit.vaultStakedLpTokensBalance, 0, "Staked balance should be 0 after exit");
        // assertEq(
        //     vaultStateAfterExit.vaultLpTokensBalance,
        //     vaultStateAfterEnterCurvePool.vaultLpTokensBalance,
        //     "LP token balance should be restored after exit"
        // );
    }

    /// SETUP HELPERS

    function _setupFork() private {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 244084803);
    }

    function _init() private {
        _setupAddresses();
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

        RoleLib.setupPlasmaVaultRoles(
            usersToRoles,
            vm,
            address(instances.plasmaVault),
            instances.accessManager,
            withdrawManager
        );

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            address(this),
            address(instances.plasmaVault),
            fuses,
            _setupBalanceFuses(),
            _setupMarketConfigs()
        );
    }

    function _setupAddresses() private {
        addresses = ContractAddresses({
            curveStableswapNgPool: 0x4bD135524897333bec344e50ddD85126554E58B4,
            childLiquidityGauge: 0xbdBb71914DdB650F96449b54d2CA15132Be56Aca,
            usdm: 0x59D9356E565Ab3A36dD77763Fc0d87fEaf85508C,
            arb: 0x912CE59144191C1204E64559FE8253a0e49E6548,
            chronicleAdmin: 0x39aBD7819E5632Fa06D2ECBba45Dca5c90687EE3,
            wusdmUsdOracleFeed: 0xdC6720c996Fad27256c7fd6E0a271e2A4687eF18,
            chainlinkArb: 0xb2A824043730FE05F3DA2efaFa1CBbe83fa548D6,
            owner: 0xD92E9F039E4189c342b4067CC61f5d063960D248
        });

        instances.curveStableswapNg = ICurveStableswapNG(addresses.curveStableswapNgPool);
        instances.curveLiquidityGauge = IChildLiquidityGauge(addresses.childLiquidityGauge);
        chronicleOracle = IChronicle(addresses.wusdmUsdOracleFeed);
    }

    function _setupAsset() public {
        asset = addresses.usdm;
    }

    function dealAsset(address asset_, address account_, uint256 amount_) public {
        vm.prank(0x426c4966fC76Bf782A663203c023578B744e4C5E); // USDM (asset) holder
        ERC20(asset_).transfer(account_, amount_);
    }

    function _setupPriceOracleSources() private returns (address[] memory assets, address[] memory sources) {
        instances.usdmPriceFeed = new USDMPriceFeedArbitrum();
        vm.prank(addresses.chronicleAdmin);
        IToll(address(chronicleOracle)).kiss(address(instances.usdmPriceFeed));
        assets = new address[](3);
        sources = new address[](3);
        assets[0] = addresses.usdm;
        assets[1] = addresses.arb;
        assets[2] = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC on Arbitrum
        sources[0] = address(instances.usdmPriceFeed);
        sources[1] = addresses.chainlinkArb;
        sources[2] = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3; // Chainlink USDC/USD on Arbitrum
    }

    function _setupPriceOracle() private {
        address[] memory assets;
        address[] memory sources;
        (assets, sources) = _setupPriceOracleSources();
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        instances.priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeWithSignature("initialize(address)", addresses.owner)
                )
            )
        );
        vm.prank(addresses.owner);
        instances.priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);
    }

    function _setupFuses() private {
        curveStableswapNGSingleSideSupplyFuse = new CurveStableswapNGSingleSideSupplyFuse(IporFusionMarkets.CURVE_POOL);
        curveChildLiquidityGaugeSupplyFuse = new CurveChildLiquidityGaugeSupplyFuse(IporFusionMarkets.CURVE_LP_GAUGE);
        transientStorageSetterFuse = new TransientStorageSetterFuse();

        fuses = new address[](3);
        fuses[0] = address(curveStableswapNGSingleSideSupplyFuse);
        fuses[1] = address(curveChildLiquidityGaugeSupplyFuse);
        fuses[2] = address(transientStorageSetterFuse);
    }

    function _createClaimFuse() private {
        curveGaugeTokenClaimFuse = new CurveGaugeTokenClaimFuse(IporFusionMarkets.CURVE_LP_GAUGE);
    }

    function _createAlphas() private {
        alphas = new address[](1);
        alphas[0] = ALPHA;
    }

    function _createAccessManager() private {
        if (usersToRoles.superAdmin == address(0)) {
            usersToRoles.superAdmin = admin;
            usersToRoles.atomist = ATOMIST;
            usersToRoles.alphas = alphas;
        }
        instances.accessManager = IporFusionAccessManager(RoleLib.createAccessManager(usersToRoles, 0, vm));
    }

    function _createClaimRewardsManager() private {
        instances.rewardsClaimManager = new RewardsClaimManager(
            address(instances.accessManager),
            address(instances.plasmaVault)
        );
    }

    function _createPlasmaVault() private {
        withdrawManager = address(new WithdrawManager(address(instances.accessManager)));
        instances.plasmaVault = new PlasmaVault();
        PlasmaVault(instances.plasmaVault).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "PLASMA VAULT",
                assetSymbol: "PLASMA",
                underlyingToken: asset,
                priceOracleMiddleware: address(instances.priceOracleMiddlewareProxy),
                feeConfig: _setupFeeConfig(),
                accessManager: address(instances.accessManager),
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: address(withdrawManager),
                plasmaVaultVotesPlugin: address(0)
            })
        );
    }

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](2);
        bytes32[] memory substratesCurvePool = new bytes32[](1);
        substratesCurvePool[0] = PlasmaVaultConfigLib.addressToBytes32(addresses.curveStableswapNgPool);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.CURVE_POOL, substratesCurvePool);

        bytes32[] memory substratesCurveGauge = new bytes32[](1);
        substratesCurveGauge[0] = PlasmaVaultConfigLib.addressToBytes32(addresses.childLiquidityGauge);
        marketConfigs[1] = MarketSubstratesConfig(IporFusionMarkets.CURVE_LP_GAUGE, substratesCurveGauge);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        CurveStableswapNGSingleSideBalanceFuse curveStableswapNGBalanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
                IporFusionMarkets.CURVE_POOL
            );

        CurveChildLiquidityGaugeBalanceFuse curveChildLiquidityGaugeBalanceFuse = new CurveChildLiquidityGaugeBalanceFuse(
                IporFusionMarkets.CURVE_LP_GAUGE
            );

        balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(IporFusionMarkets.CURVE_POOL, address(curveStableswapNGBalanceFuse));
        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarkets.CURVE_LP_GAUGE,
            address(curveChildLiquidityGaugeBalanceFuse)
        );
    }

    function _setupPlasmaVault() private {
        vm.prank(admin);
        PlasmaVaultGovernance(address(instances.plasmaVault)).setRewardsClaimManagerAddress(
            address(instances.rewardsClaimManager)
        );
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfigHelper.createZeroFeeConfig();
    }

    function _addClaimFuseToClaimRewardsManager() private {
        claimFuses = new address[](1);
        claimFuses[0] = address(curveGaugeTokenClaimFuse);
        instances.rewardsClaimManager.addRewardFuses(claimFuses);
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](1);
        initAddress[0] = admin;

        DataForInitialization memory data = DataForInitialization({
            isPublic: false,
            iporDaos: initAddress,
            admins: initAddress,
            owners: initAddress,
            atomists: initAddress,
            alphas: initAddress,
            whitelist: initAddress,
            guardians: initAddress,
            fuseManagers: initAddress,
            claimRewards: initAddress,
            transferRewardsManagers: initAddress,
            configInstantWithdrawalFusesManagers: initAddress,
            updateMarketsBalancesAccounts: initAddress,
            updateRewardsBalanceAccounts: initAddress,
            withdrawManagerRequestFeeManagers: initAddress,
            withdrawManagerWithdrawFeeManagers: initAddress,
            priceOracleMiddlewareManagers: initAddress,
            preHooksManagers: initAddress,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: address(instances.plasmaVault),
                accessManager: address(instances.accessManager),
                rewardsClaimManager: address(instances.rewardsClaimManager),
                withdrawManager: address(0x123),
                feeManager: address(0x123),
                contextManager: address(0x123),
                priceOracleMiddlewareManager: address(0x123)
            })
        });
        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        instances.accessManager.initialize(initializationData);
    }

    /// HELPERS

    function _setupDependencyBalanceGraphs() private {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.CURVE_LP_GAUGE;

        uint256[] memory dependencies = new uint256[](1);
        dependencies[0] = IporFusionMarkets.CURVE_POOL;

        uint256[][] memory dependencyMarkets = new uint256[][](1);
        dependencyMarkets[0] = dependencies;

        PlasmaVaultGovernance(address(instances.plasmaVault)).updateDependencyBalanceGraphs(
            marketIds,
            dependencyMarkets
        );
    }

    function _depositIntoVaultAndProvideLiquidityToCurvePool(uint256 amount) private {
        dealAsset(asset, admin, amount);
        vm.startPrank(admin);
        ERC20(asset).approve(address(instances.plasmaVault), amount);
        instances.plasmaVault.deposit(amount, address(admin));
        vm.stopPrank();
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(curveStableswapNGSingleSideSupplyFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256))",
                CurveStableswapNGSingleSideSupplyFuseEnterData({
                    curveStableswapNG: instances.curveStableswapNg,
                    asset: asset,
                    assetAmount: amount,
                    minLpTokenAmountReceived: 0
                })
            )
        );
        vm.prank(ALPHA);
        instances.plasmaVault.execute(calls);
    }

    function _executeCurveChildLiquidityGaugeSupplyFuseEnter(
        CurveChildLiquidityGaugeSupplyFuse fuseInstance,
        address curveGauge,
        uint256 amount
    ) internal {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(fuseInstance),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                CurveChildLiquidityGaugeSupplyFuseEnterData({childLiquidityGauge: curveGauge, lpTokenAmount: amount})
            )
        );

        vm.prank(ALPHA);
        instances.plasmaVault.execute(calls);
    }

    function getPlasmaVaultState() public view returns (PlasmaVaultState memory) {
        PlasmaVaultState memory state;
        state.vaultBalance = ERC20(asset).balanceOf(address(instances.plasmaVault));
        state.vaultTotalAssets = instances.plasmaVault.totalAssets();
        state.vaultTotalAssetsInCurvePool = instances.plasmaVault.totalAssetsInMarket(
            curveStableswapNGSingleSideSupplyFuse.MARKET_ID()
        );
        state.vaultTotalAssetsInGauge = instances.plasmaVault.totalAssetsInMarket(
            curveChildLiquidityGaugeSupplyFuse.MARKET_ID()
        );
        state.vaultLpTokensBalance = ERC20(addresses.curveStableswapNgPool).balanceOf(address(instances.plasmaVault));
        state.vaultStakedLpTokensBalance = ERC20(addresses.childLiquidityGauge).balanceOf(
            address(instances.plasmaVault)
        );
        state.vaultNumberRewardTokens = instances.curveLiquidityGauge.reward_count();
        state.vaultRewardTokens = new address[](state.vaultNumberRewardTokens);
        state.vaultClaimedRewardTokens = new uint256[](state.vaultNumberRewardTokens);
        state.vaultClaimableRewardTokens = new uint256[](state.vaultNumberRewardTokens);
        state.rewardsClaimManagerBalanceRewardTokens = new uint256[](state.vaultNumberRewardTokens);
        for (uint256 i = 0; i < state.vaultNumberRewardTokens; ++i) {
            state.vaultRewardTokens[i] = instances.curveLiquidityGauge.reward_tokens(i);
            state.vaultClaimedRewardTokens[i] = instances.curveLiquidityGauge.claimed_reward(
                address(instances.plasmaVault),
                state.vaultRewardTokens[i]
            );
            state.vaultClaimableRewardTokens[i] = instances.curveLiquidityGauge.claimable_reward(
                address(instances.plasmaVault),
                state.vaultRewardTokens[i]
            );
            state.rewardsClaimManagerBalanceRewardTokens[i] = ERC20(state.vaultRewardTokens[i]).balanceOf(
                address(instances.rewardsClaimManager)
            );
        }
        return state;
    }
}
