// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CurveStableswapNGSingleSideSupplyFuse, CurveStableswapNGSingleSideSupplyFuseEnterData} from "../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideSupplyFuse.sol";
import {CurveStableswapNGSingleSideBalanceFuse} from "../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideBalanceFuse.sol";
import {CurveChildLiquidityGaugeSupplyFuse, CurveChildLiquidityGaugeSupplyFuseEnterData, CurveChildLiquidityGaugeSupplyFuseExitData} from "../../../contracts/fuses/curve_gauge/CurveChildLiquidityGaugeSupplyFuse.sol";
import {CurveChildLiquidityGaugeBalanceFuse} from "../../../contracts/fuses/curve_gauge/CurveChildLiquidityGaugeBalanceFuse.sol";
import {IChildLiquidityGauge} from "../../../contracts/fuses/curve_gauge/ext/IChildLiquidityGauge.sol";
import {ICurveStableswapNG} from "../../../contracts/fuses/curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {PlasmaVault, FeeConfig, FuseAction, MarketBalanceFuseConfig, MarketSubstratesConfig, PlasmaVaultInitData} from "./../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionAccessManager} from "./../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {IporFusionAccessManager} from "./../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RoleLib, UsersToRoles} from "./../../RoleLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InitializationData} from "../../../contracts/managers/access/IporFusionAccessManagerInitializationLib.sol";
import {USDMPriceFeedArbitrum} from "../../../contracts/price_oracle/price_feed/chains/arbitrum/USDMPriceFeedArbitrum.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IChronicle, IToll} from "../../../contracts/price_oracle/ext/IChronicle.sol";
import {FeeFactory} from "../../../contracts/managers/fee/FeeFactory.sol";

contract CurveUSDMUSDCStakeLPGaugeArbitrum is Test {
    struct PlasmaVaultState {
        uint256 vaultBalance;
        uint256 vaultTotalAssets;
        uint256 vaultTotalAssetsInCurvePool;
        uint256 vaultTotalAssetsInGauge;
        uint256 vaultLpTokensBalance;
        uint256 vaultStakedLpTokensBalance;
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

    /// Oracles
    PriceOracleMiddleware private priceOracleMiddlewareProxy;
    address public constant CHRONICLE_ADMIN = 0x39aBD7819E5632Fa06D2ECBba45Dca5c90687EE3;
    address public constant WUSDM_USD_ORACLE_FEED = 0xdC6720c996Fad27256c7fd6E0a271e2A4687eF18;
    IChronicle public constant CHRONICLE = IChronicle(WUSDM_USD_ORACLE_FEED);
    // solhint-disable-next-line
    USDMPriceFeedArbitrum public USDMPriceFeed;

    /// Vaults
    PlasmaVault public plasmaVault;

    /// Fuses
    address[] public fuses;
    CurveStableswapNGSingleSideSupplyFuse public curveStableswapNGSingleSideSupplyFuse;
    CurveChildLiquidityGaugeSupplyFuse public curveChildLiquidityGaugeSupplyFuse;

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
    event CurveChildLiquidityGaugeSupplyFuseEnter(address version, address lpToken, uint256 amount);
    event CurveChildLiquidityGaugeSupplyFuseExit(address version, address lpToken, uint256 amount);

    function setUp() public {
        _setupFork();
        _init();
    }

    /// ENTER TESTS
    function testShouldBeAbleToEnterCurveChildLiquidityGaugeSupplyFuse() public {
        // given
        uint256 amount = 1_000 * 10 ** ERC20(asset).decimals();

        _depositIntoVaultAndProvideLiquidityToCurvePool(amount);

        PlasmaVaultState memory vaultStateAfterEnterCurvePool = getPlasmaVaultState();

        // when
        _executeCurveChildLiquidityGaugeSupplyFuseEnter(
            curveChildLiquidityGaugeSupplyFuse,
            address(CURVE_LIQUIDITY_GAUGE),
            vaultStateAfterEnterCurvePool.vaultLpTokensBalance,
            true
        );
        PlasmaVaultState memory vaultStateAfterEnterCurveGauge = getPlasmaVaultState();

        // then
        assertEq(vaultStateAfterEnterCurvePool.vaultBalance, 0, "Vault Balance should be 0 after enter curve pool");
        assertEq(vaultStateAfterEnterCurveGauge.vaultBalance, 0, "Vault Balance should be 0 after enter curve gauge");
        assertEq(
            vaultStateAfterEnterCurvePool.vaultBalance,
            vaultStateAfterEnterCurveGauge.vaultBalance,
            "Vault balance should be the same after enter Curve pool and gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssets,
            999894124676249419596,
            "Vault total assets should be 999894124676249419596"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssets,
            999894124676249419596,
            "Vault total assets should be 999894124676249419596"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssets,
            vaultStateAfterEnterCurveGauge.vaultTotalAssets,
            "Vault total assets should be the same after enter Curve pool and gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssetsInCurvePool,
            999894124676249419596,
            "Vault total assets in curve pool should be 999894124676249419596 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInCurvePool,
            0,
            "Vault total assets in curve pool should be 0 after enter curve gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssetsInGauge,
            0,
            "Vault total assets in curve gauge should be 0 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInGauge,
            999894124676249419596,
            "Vault total assets in curve gauge should be 999894124676249419596 after enter curve gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssetsInCurvePool,
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInGauge,
            "Vault total assets in curve pool should be the same as vault total assets in gauge after staking LP tokens in gauge"
        );
        assertGt(
            vaultStateAfterEnterCurvePool.vaultLpTokensBalance,
            0,
            "Vault LP tokens balance should be greater than 0 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultLpTokensBalance,
            996561228119407211058,
            "Vault LP tokens balance should be 996561228119407211058 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultLpTokensBalance,
            0,
            "Vault LP tokens balance should be 0 after enter curve gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultLpTokensBalance,
            vaultStateAfterEnterCurveGauge.vaultStakedLpTokensBalance,
            "Vault LP tokens balance should be the same as vault staked LP tokens balance after enter curve gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultStakedLpTokensBalance,
            0,
            "Vault staked LP tokens balance should be 0 after enter curve pool"
        );
        assertGt(
            vaultStateAfterEnterCurveGauge.vaultStakedLpTokensBalance,
            0,
            "Vault staked LP tokens balance should be greater than 0 after enter curve gauge"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultStakedLpTokensBalance,
            vaultStateAfterEnterCurvePool.vaultLpTokensBalance,
            "Vault staked LP tokens balance should be the same as vault LP tokens balance after enter curve gauge"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultStakedLpTokensBalance,
            996561228119407211058,
            "Vault staked LP tokens balance should be 996561228119407211058 after enter curve gauge"
        );
    }

    function testShouldNotBeAbleToEnterCurveChildLiquidityGaugeSupplyFuseWithUnsupportedGauge() public {
        // given
        uint256 amount = 1_000 * 10 ** ERC20(asset).decimals();
        _depositIntoVaultAndProvideLiquidityToCurvePool(amount);
        PlasmaVaultState memory vaultStateAfterEnterCurvePool = getPlasmaVaultState();

        address unsupportedGauge = 0xB08FEf57bFcc5f7bF0EF69C0c090849d497C8F8A;

        bytes memory error = abi.encodeWithSignature(
            "CurveChildLiquidityGaugeSupplyFuseUnsupportedGauge(address)",
            unsupportedGauge
        );

        // when
        vm.expectRevert(error);
        _executeCurveChildLiquidityGaugeSupplyFuseEnter(
            curveChildLiquidityGaugeSupplyFuse,
            unsupportedGauge,
            vaultStateAfterEnterCurvePool.vaultLpTokensBalance,
            false
        );
        PlasmaVaultState memory vaultStateAfterEnterCurveGauge = getPlasmaVaultState();

        // then
        assertEq(vaultStateAfterEnterCurvePool.vaultBalance, 0, "Vault Balance should be 0 after enter curve pool");
        assertEq(vaultStateAfterEnterCurveGauge.vaultBalance, 0, "Vault Balance should be 0 after enter curve gauge");
        assertEq(
            vaultStateAfterEnterCurvePool.vaultBalance,
            vaultStateAfterEnterCurveGauge.vaultBalance,
            "Vault balance should be the same after enter Curve pool and gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssets,
            999894124676249419596,
            "Vault total assets should be 999894124676249419596 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssets,
            999894124676249419596,
            "Vault total assets should be 999894124676249419596 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssets,
            vaultStateAfterEnterCurveGauge.vaultTotalAssets,
            "Vault total assets should be the same after enter Curve pool and enter gauge fails"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssetsInCurvePool,
            999894124676249419596,
            "Vault total assets in curve pool should be 999894124676249419596 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInCurvePool,
            999894124676249419596,
            "Vault total assets in curve pool should be 999894124676249419596 after enter curve gauge fails"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssetsInCurvePool,
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInCurvePool,
            "Vault total assets in curve pool should be the same after enter curve pool and enter gauge fails"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssetsInGauge,
            0,
            "Vault total assets in gauge should be 0 after enter curve pool and enter gauge fails"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInGauge,
            0,
            "Vault total assets in gauge should be 0 after enter curve gauge fails"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssetsInGauge,
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInGauge,
            "Vault total assets in gauge should be the same after enter curve pool and enter gauge fails"
        );
        assertGt(
            vaultStateAfterEnterCurvePool.vaultLpTokensBalance,
            0,
            "Vault LP tokens balance should be greater than 0 after enter curve pool"
        );
        assertGt(
            vaultStateAfterEnterCurveGauge.vaultLpTokensBalance,
            0,
            "Vault LP tokens balance should be greater than zero after enter curve gauge fails"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultLpTokensBalance,
            vaultStateAfterEnterCurveGauge.vaultLpTokensBalance,
            "Vault LP tokens balance should be the same after enter curve pool and enter gauge fails"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultStakedLpTokensBalance,
            0,
            "Vault staked LP tokens balance should be 0 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultStakedLpTokensBalance,
            0,
            "Vault staked LP tokens balance should be 0 after enter curve gauge fails"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultStakedLpTokensBalance,
            vaultStateAfterEnterCurveGauge.vaultStakedLpTokensBalance,
            "Vault staked LP tokens balance should be the same after enter curve pool and enter gauge fails"
        );
    }

    function testShouldBeAbleToEnterCurveChildLiquidityGaugeSupplyFuseWithZeroLPDepositAmount() public {
        // given
        uint256 amount = 1_000 * 10 ** ERC20(asset).decimals();
        _depositIntoVaultAndProvideLiquidityToCurvePool(amount);
        PlasmaVaultState memory vaultStateAfterEnterCurvePool = getPlasmaVaultState();

        // when
        _executeCurveChildLiquidityGaugeSupplyFuseEnter(
            curveChildLiquidityGaugeSupplyFuse,
            address(CURVE_LIQUIDITY_GAUGE),
            0,
            false
        );
        PlasmaVaultState memory vaultStateAfterEnterCurveGauge = getPlasmaVaultState();

        // then
        assertEq(vaultStateAfterEnterCurvePool.vaultBalance, 0, "Vault Balance should be 0 after enter curve pool");
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultBalance,
            0,
            "Vault Balance should be 0 after fail to enter curve gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultBalance,
            vaultStateAfterEnterCurveGauge.vaultBalance,
            "Vault balance should be the same after enter Curve pool and fail to enter gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssets,
            999894124676249419596,
            "Vault total assets should be 999894124676249419596 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssets,
            999894124676249419596,
            "Vault total assets should be 999894124676249419596 after fail to enter curve gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssets,
            vaultStateAfterEnterCurveGauge.vaultTotalAssets,
            "Vault total assets should be the same after enter Curve pool and fail to enter gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssetsInCurvePool,
            999894124676249419596,
            "Vault total assets in curve pool should be 999894124676249419596 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInCurvePool,
            999894124676249419596,
            "Vault total assets in curve pool should be 999894124676249419596 after fail to enter curve gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssetsInCurvePool,
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInCurvePool,
            "Vault total assets in curve pool should be the same after enter Curve pool and fail to enter gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssetsInGauge,
            0,
            "Vault total assets in gauge should be 0 after enter curve pool and fail to enter gauge"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInGauge,
            0,
            "Vault total assets in gauge should be 0 after fail to enter curve gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssetsInGauge,
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInGauge,
            "Vault total assets in gauge should be the same after enter Curve pool and fail to enter gauge"
        );
        assertGt(
            vaultStateAfterEnterCurvePool.vaultLpTokensBalance,
            0,
            "Vault LP tokens balance should be greater than 0 after enter curve pool"
        );
        assertGt(
            vaultStateAfterEnterCurveGauge.vaultLpTokensBalance,
            0,
            "Vault LP tokens balance should be greater than 0 after fail to enter curve gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultLpTokensBalance,
            vaultStateAfterEnterCurveGauge.vaultLpTokensBalance,
            "Vault LP tokens balance should be the same after enter curve pool and fail to enter gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultStakedLpTokensBalance,
            0,
            "Vault staked LP tokens balance should be 0 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultStakedLpTokensBalance,
            0,
            "Vault staked LP tokens balance should be 0 after fail to enter curve gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultStakedLpTokensBalance,
            vaultStateAfterEnterCurveGauge.vaultStakedLpTokensBalance,
            "Vault staked LP tokens balance should be the same after enter curve pool and fail to enter gauge"
        );
    }

    /// EXIT TESTS
    function testShouldBeAbleToExitCurveChildLiquidityGaugeSupplyFuse() public {
        // given
        uint256 amount = 1_000 * 10 ** ERC20(asset).decimals();
        _depositIntoVaultAndProvideLiquidityToCurvePool(amount);
        PlasmaVaultState memory vaultStateAfterEnterCurvePool = getPlasmaVaultState();
        _executeCurveChildLiquidityGaugeSupplyFuseEnter(
            curveChildLiquidityGaugeSupplyFuse,
            address(CURVE_LIQUIDITY_GAUGE),
            vaultStateAfterEnterCurvePool.vaultLpTokensBalance,
            true
        );
        PlasmaVaultState memory vaultStateBeforeExitCurveGauge = getPlasmaVaultState();

        // when
        _executeCurveChildLiquidityGaugeSupplyFuseExit(
            curveChildLiquidityGaugeSupplyFuse,
            address(CURVE_LIQUIDITY_GAUGE),
            vaultStateBeforeExitCurveGauge.vaultStakedLpTokensBalance,
            true
        );

        PlasmaVaultState memory vaultStateAfterExitCurveGauge = getPlasmaVaultState();

        // then
        assertEq(vaultStateBeforeExitCurveGauge.vaultBalance, 0, "Vault Balance should be 0 before exit curve gauge");
        assertEq(vaultStateAfterExitCurveGauge.vaultBalance, 0, "Vault Balance should be 0 after exit curve gauge");
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultBalance,
            vaultStateAfterExitCurveGauge.vaultBalance,
            "Vault balance should be the same before and after exit Curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultTotalAssets,
            999894124676249419596,
            "Vault total assets should be 999894124676249419596 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultTotalAssets,
            999894124676249419596,
            "Vault total assets should be 999894124676249419596 after exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultTotalAssets,
            vaultStateAfterExitCurveGauge.vaultTotalAssets,
            "Vault total assets should be the same before and after exit Curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultTotalAssetsInCurvePool,
            0,
            "Vault total assets in curve pool should be 0 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultTotalAssetsInCurvePool,
            999894124676249419596,
            "Vault total assets in curve pool should be 999894124676249419596 after exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultTotalAssetsInGauge,
            999894124676249419596,
            "Vault total assets in gauge should be 999894124676249419596 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultTotalAssetsInGauge,
            0,
            "Vault total assets in gauge should be 0 after exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultLpTokensBalance,
            0,
            "Vault LP tokens balance should be 0 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultLpTokensBalance,
            996561228119407211058,
            "Vault LP tokens balance should be 996561228119407211058 after exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultStakedLpTokensBalance,
            996561228119407211058,
            "Vault staked LP tokens balance should be 996561228119407211058 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultStakedLpTokensBalance,
            0,
            "Vault staked LP tokens balance should be 0 after exit curve gauge"
        );
    }

    function testShouldNotBeAbleToExitCurveChildLiquidityGaugeSupplyFuseWithUnsupportedGauge() public {
        // given
        uint256 amount = 1_000 * 10 ** ERC20(asset).decimals();
        _depositIntoVaultAndProvideLiquidityToCurvePool(amount);
        PlasmaVaultState memory vaultStateAfterEnterCurvePool = getPlasmaVaultState();
        _executeCurveChildLiquidityGaugeSupplyFuseEnter(
            curveChildLiquidityGaugeSupplyFuse,
            address(CURVE_LIQUIDITY_GAUGE),
            vaultStateAfterEnterCurvePool.vaultLpTokensBalance,
            true
        );
        PlasmaVaultState memory vaultStateBeforeExitCurveGauge = getPlasmaVaultState();

        // when
        address unsupportedGauge = 0xB08FEf57bFcc5f7bF0EF69C0c090849d497C8F8A;
        bytes memory error = abi.encodeWithSignature(
            "CurveChildLiquidityGaugeSupplyFuseUnsupportedGauge(address)",
            unsupportedGauge
        );
        vm.expectRevert(error);
        _executeCurveChildLiquidityGaugeSupplyFuseExit(
            curveChildLiquidityGaugeSupplyFuse,
            unsupportedGauge,
            vaultStateBeforeExitCurveGauge.vaultStakedLpTokensBalance,
            false
        );
        PlasmaVaultState memory vaultStateAfterExitCurveGauge = getPlasmaVaultState();

        // then
        assertEq(vaultStateBeforeExitCurveGauge.vaultBalance, 0, "Vault Balance should be 0 before exit curve gauge");
        assertEq(vaultStateAfterExitCurveGauge.vaultBalance, 0, "Vault Balance should be 0 after exit curve gauge");
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultBalance,
            vaultStateAfterExitCurveGauge.vaultBalance,
            "Vault balance should be the same before and after exit Curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultTotalAssets,
            999894124676249419596,
            "Vault total assets should be 999894124676249419596 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultTotalAssets,
            999894124676249419596,
            "Vault total assets should be 999894124676249419596 after fail to exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultTotalAssets,
            vaultStateAfterExitCurveGauge.vaultTotalAssets,
            "Vault total assets should be the same before and after failt to exit Curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultTotalAssetsInCurvePool,
            0,
            "Vault total assets in curve pool should be 0 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultTotalAssetsInCurvePool,
            0,
            "Vault total assets in curve pool should be 0 after fail to exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultTotalAssetsInGauge,
            999894124676249419596,
            "Vault total assets in gauge should be 999894124676249419596 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultTotalAssetsInGauge,
            999894124676249419596,
            "Vault total assets in gauge should be 999894124676249419596 after fail to exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultTotalAssetsInGauge,
            vaultStateAfterExitCurveGauge.vaultTotalAssetsInGauge,
            "Vault total assets in gauge should be the same before and after fail to exit Curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultLpTokensBalance,
            0,
            "Vault LP tokens balance should be 0 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultLpTokensBalance,
            0,
            "Vault LP tokens balance should be 0 after fail to exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultStakedLpTokensBalance,
            996561228119407211058,
            "Vault staked LP tokens balance should be 996561228119407211058 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultStakedLpTokensBalance,
            996561228119407211058,
            "Vault staked LP tokens balance should be 996561228119407211058 after fail to exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultStakedLpTokensBalance,
            vaultStateAfterExitCurveGauge.vaultStakedLpTokensBalance,
            "Vault staked LP tokens balance should be the same before and after fail to exit Curve gauge"
        );
    }

    function testShouldBeAbleToExitCurveChildLiquidityGaugeSupplyFuseWithZeroWithdrawAmount() public {
        // given
        uint256 amount = 1_000 * 10 ** ERC20(asset).decimals();
        _depositIntoVaultAndProvideLiquidityToCurvePool(amount);
        PlasmaVaultState memory vaultStateAfterEnterCurvePool = getPlasmaVaultState();
        _executeCurveChildLiquidityGaugeSupplyFuseEnter(
            curveChildLiquidityGaugeSupplyFuse,
            address(CURVE_LIQUIDITY_GAUGE),
            vaultStateAfterEnterCurvePool.vaultLpTokensBalance,
            true
        );
        PlasmaVaultState memory vaultStateBeforeExitCurveGauge = getPlasmaVaultState();

        // when
        _executeCurveChildLiquidityGaugeSupplyFuseExit(
            curveChildLiquidityGaugeSupplyFuse,
            address(CURVE_LIQUIDITY_GAUGE),
            0,
            false
        );

        PlasmaVaultState memory vaultStateAfterExitCurveGauge = getPlasmaVaultState();

        // then
        assertEq(vaultStateBeforeExitCurveGauge.vaultBalance, 0, "Vault Balance should be 0 before exit curve gauge");
        assertEq(
            vaultStateAfterExitCurveGauge.vaultBalance,
            0,
            "Vault Balance should be 0 after fail to exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultBalance,
            vaultStateAfterExitCurveGauge.vaultBalance,
            "Vault balance should be the same before and after exit Curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultTotalAssets,
            999894124676249419596,
            "Vault total assets should be 999894124676249419596 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultTotalAssets,
            999894124676249419596,
            "Vault total assets should be 999894124676249419596 after fail to exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultTotalAssets,
            vaultStateAfterExitCurveGauge.vaultTotalAssets,
            "Vault total assets should be the same before and after failt to exit Curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultTotalAssetsInCurvePool,
            0,
            "Vault total assets in curve pool should be 0 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultTotalAssetsInCurvePool,
            0,
            "Vault total assets in curve pool should be 0 after fail to exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultTotalAssetsInCurvePool,
            vaultStateAfterExitCurveGauge.vaultTotalAssetsInCurvePool,
            "Vault total assets in curve pool should be the same before and after failt to exit Curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultTotalAssetsInGauge,
            999894124676249419596,
            "Vault total assets in gauge should be 999894124676249419596 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultTotalAssetsInGauge,
            999894124676249419596,
            "Vault total assets in gauge should be 999894124676249419596 after fail to exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultTotalAssetsInGauge,
            vaultStateAfterExitCurveGauge.vaultTotalAssetsInGauge,
            "Vault total assets in gauge should be the same before and after fail to exit Curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultLpTokensBalance,
            0,
            "Vault LP tokens balance should be 0 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultLpTokensBalance,
            0,
            "Vault LP tokens balance should be 0 after fail to exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultLpTokensBalance,
            vaultStateAfterExitCurveGauge.vaultLpTokensBalance,
            "Vault staked LP tokens balance should be the same before and after fail to exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultStakedLpTokensBalance,
            996561228119407211058,
            "Vault staked LP tokens balance should be 996561228119407211058 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultStakedLpTokensBalance,
            996561228119407211058,
            "Vault staked LP tokens balance should be 996561228119407211058 after fail to exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultStakedLpTokensBalance,
            vaultStateAfterExitCurveGauge.vaultStakedLpTokensBalance,
            "Vault staked LP tokens balance should be the same before and after fail to exit Curve gauge"
        );
    }

    /// SETUP HELPERS

    function _setupFork() private {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 203649402);
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
        _initAccessManager();
    }

    function getMarketId() public view returns (uint256) {
        return IporFusionMarkets.CURVE_LP_GAUGE;
    }

    function _setupAsset() public {
        asset = USDM;
    }

    function dealAssets(address asset_, address account_, uint256 amount_) public {
        vm.prank(0x426c4966fC76Bf782A663203c023578B744e4C5E); // holder
        ERC20(asset_).transfer(account_, amount_);
    }

    /// SETUP INIT FUNCTIONS

    function _createAccessManager() private {
        if (usersToRoles.superAdmin == address(0)) {
            usersToRoles.superAdmin = admin;
            usersToRoles.atomist = atomist;
            usersToRoles.alphas = alphas;
        }
        accessManager = IporFusionAccessManager(RoleLib.createAccessManager(usersToRoles, 0, vm));
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager);
    }

    function _createClaimRewardsManager() private {
        rewardsClaimManager = new RewardsClaimManager(address(accessManager), address(plasmaVault));
    }

    function _createAlphas() private {
        alphas = new address[](1);
        alphas[0] = alpha;
    }

    function _setupPriceOracleSources() private returns (address[] memory assets, address[] memory sources) {
        USDMPriceFeed = new USDMPriceFeedArbitrum();
        vm.prank(CHRONICLE_ADMIN);
        IToll(address(CHRONICLE)).kiss(address(USDMPriceFeed));
        assets = new address[](1);
        sources = new address[](1);
        assets[0] = USDM;
        sources[0] = address(USDMPriceFeed);
    }

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs) {
        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);
        bytes32[] memory substratesCurvePool = new bytes32[](1);
        substratesCurvePool[0] = PlasmaVaultConfigLib.addressToBytes32(CURVE_STABLESWAP_NG_POOL);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.CURVE_POOL, substratesCurvePool);

        bytes32[] memory substratesCurveGauge = new bytes32[](1);
        substratesCurveGauge[0] = PlasmaVaultConfigLib.addressToBytes32(CHILD_LIQUIDITY_GAUGE);
        marketConfigs[1] = MarketSubstratesConfig(IporFusionMarkets.CURVE_LP_GAUGE, substratesCurveGauge);
        return marketConfigs;
    }

    function _setupFuses() private {
        curveStableswapNGSingleSideSupplyFuse = new CurveStableswapNGSingleSideSupplyFuse(IporFusionMarkets.CURVE_POOL);
        curveChildLiquidityGaugeSupplyFuse = new CurveChildLiquidityGaugeSupplyFuse(IporFusionMarkets.CURVE_LP_GAUGE);
        fuses = new address[](2);
        fuses[0] = address(curveStableswapNGSingleSideSupplyFuse);
        fuses[1] = address(curveChildLiquidityGaugeSupplyFuse);
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

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfig(0, 0, 0, 0, address(address(new FeeFactory())), address(0), address(0));
    }

    function _setupPlasmaVault() private {
        vm.startPrank(admin);
        PlasmaVaultGovernance(address(plasmaVault)).setRewardsClaimManagerAddress(address(rewardsClaimManager));

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.CURVE_LP_GAUGE;

        uint256[] memory dependencies = new uint256[](1);
        dependencies[0] = IporFusionMarkets.CURVE_POOL;

        uint256[][] memory dependencyMarkets = new uint256[][](1);
        dependencyMarkets[0] = dependencies;

        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, dependencyMarkets);

        vm.stopPrank();
    }

    function _setupPriceOracle() private {
        address[] memory assets;
        address[] memory sources;
        (assets, sources) = _setupPriceOracleSources();
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", OWNER)))
        );
        vm.prank(OWNER);
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);
    }

    function _createPlasmaVault() private {
        plasmaVault = new PlasmaVault(
            PlasmaVaultInitData({
                assetName: "PLASMA VAULT",
                assetSymbol: "PLASMA",
                underlyingToken: USDM,
                priceOracleMiddleware: address(priceOracleMiddlewareProxy),
                marketSubstratesConfigs: _setupMarketConfigs(),
                fuses: fuses,
                balanceFuses: _setupBalanceFuses(),
                feeConfig: _setupFeeConfig(),
                accessManager: address(accessManager),
                plasmaVaultBase: address(new PlasmaVaultBase()),
                totalSupplyCap: type(uint256).max,
                withdrawManager: address(0)
            })
        );
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](1);
        initAddress[0] = admin;

        DataForInitialization memory data = DataForInitialization({
            iporDaos: initAddress,
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
                withdrawManager: address(0),
                feeManager: address(0)
            })
        });
        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        accessManager.initialize(initializationData);
    }

    /// HELPERS
    function _depositIntoVaultAndProvideLiquidityToCurvePool(uint256 amount) private {
        dealAssets(asset, admin, amount);
        vm.startPrank(admin);
        ERC20(asset).approve(address(plasmaVault), amount);
        plasmaVault.deposit(amount, address(admin));
        vm.stopPrank();
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(curveStableswapNGSingleSideSupplyFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256))",
                CurveStableswapNGSingleSideSupplyFuseEnterData({
                    curveStableswapNG: CURVE_STABLESWAP_NG,
                    asset: asset,
                    assetAmount: amount,
                    minLpTokenAmountReceived: 0
                })
            )
        );
        vm.startPrank(alpha);
        plasmaVault.execute(calls);
        vm.stopPrank();
    }

    function _executeCurveChildLiquidityGaugeSupplyFuseEnter(
        CurveChildLiquidityGaugeSupplyFuse fuseInstance,
        address curveGauge,
        uint256 amount,
        bool success
    ) internal {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(fuseInstance),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                CurveChildLiquidityGaugeSupplyFuseEnterData({childLiquidityGauge: curveGauge, lpTokenAmount: amount})
            )
        );

        if (success) {
            vm.expectEmit(true, true, true, true);
            emit CurveChildLiquidityGaugeSupplyFuseEnter(address(fuseInstance), curveGauge, amount);
        }

        vm.prank(alpha);
        plasmaVault.execute(calls);
    }

    function _executeCurveChildLiquidityGaugeSupplyFuseExit(
        CurveChildLiquidityGaugeSupplyFuse fuseInstance,
        address curveGauge,
        uint256 amount,
        bool success
    ) internal {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(fuseInstance),
            abi.encodeWithSignature(
                "exit((address,uint256))",
                CurveChildLiquidityGaugeSupplyFuseExitData({childLiquidityGauge: curveGauge, lpTokenAmount: amount})
            )
        );

        if (success) {
            vm.expectEmit(true, true, true, true);
            emit CurveChildLiquidityGaugeSupplyFuseExit(address(fuseInstance), curveGauge, amount);
        }

        vm.prank(alpha);
        plasmaVault.execute(calls);
    }

    function getPlasmaVaultState() public view returns (PlasmaVaultState memory) {
        return
            PlasmaVaultState({
                vaultBalance: ERC20(asset).balanceOf(address(plasmaVault)),
                vaultTotalAssets: plasmaVault.totalAssets(),
                vaultTotalAssetsInCurvePool: plasmaVault.totalAssetsInMarket(
                    curveStableswapNGSingleSideSupplyFuse.MARKET_ID()
                ),
                vaultTotalAssetsInGauge: plasmaVault.totalAssetsInMarket(
                    curveChildLiquidityGaugeSupplyFuse.MARKET_ID()
                ),
                vaultLpTokensBalance: ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(plasmaVault)),
                vaultStakedLpTokensBalance: ERC20(CHILD_LIQUIDITY_GAUGE).balanceOf(address(plasmaVault))
            });
    }
}
