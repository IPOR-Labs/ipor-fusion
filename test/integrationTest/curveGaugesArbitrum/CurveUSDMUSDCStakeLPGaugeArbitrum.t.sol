// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {
    CurveStableswapNGSingleSideSupplyFuse,
    CurveStableswapNGSingleSideSupplyFuseEnterData
} from "../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideSupplyFuse.sol";
import {CurveStableswapNGSingleSideBalanceFuse} from "../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideBalanceFuse.sol";
import {
    CurveChildLiquidityGaugeSupplyFuse,
    CurveChildLiquidityGaugeSupplyFuseEnterData,
    CurveChildLiquidityGaugeSupplyFuseExitData
} from "../../../contracts/fuses/curve_gauge/CurveChildLiquidityGaugeSupplyFuse.sol";
import {CurveChildLiquidityGaugeBalanceFuse} from "../../../contracts/fuses/curve_gauge/CurveChildLiquidityGaugeBalanceFuse.sol";
import {IChildLiquidityGauge} from "../../../contracts/fuses/curve_gauge/ext/IChildLiquidityGauge.sol";
import {ICurveStableswapNG} from "../../../contracts/fuses/curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {
    PlasmaVault,
    FuseAction,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVaultInitData,
    FeeConfig
} from "./../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionAccessManager} from "./../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {IporFusionAccessManager} from "./../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RoleLib, UsersToRoles} from "./../../RoleLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {
    IporFusionAccessManagerInitializerLibV1,
    DataForInitialization,
    PlasmaVaultAddress
} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InitializationData} from "../../../contracts/managers/access/IporFusionAccessManagerInitializationLib.sol";
import {USDMPriceFeedArbitrum} from "../../../contracts/price_oracle/price_feed/chains/arbitrum/USDMPriceFeedArbitrum.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IChronicle, IToll} from "../../../contracts/price_oracle/ext/IChronicle.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";

/// @notice Minimal Curve StableswapNG swap interface, used only by the IL-7950 regression tests
/// below to drive a same-transaction round-trip swap against the pool. Not part of the fuses'
/// production interface (ICurveStableswapNG) and intentionally kept local to this test file.
interface ICurveStableswapNGExchange {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

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
    /// USDC on Arbitrum - the pool's other coin, used by the IL-7950 round-trip swap regression tests
    address public constant USDC_ARB = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    /// Index of USDM / USDC in CURVE_STABLESWAP_NG_POOL.coins(), used by the IL-7950 regression tests
    int128 public constant USDM_COIN_INDEX = 1;
    int128 public constant USDC_COIN_INDEX = 0;

    /// Oracles
    PriceOracleMiddleware private priceOracleMiddlewareProxy;
    address public constant CHRONICLE_ADMIN = 0x39aBD7819E5632Fa06D2ECBba45Dca5c90687EE3;
    address public constant WUSDM_USD_ORACLE_FEED = 0xdC6720c996Fad27256c7fd6E0a271e2A4687eF18;
    IChronicle public constant CHRONICLE = IChronicle(WUSDM_USD_ORACLE_FEED);
    // solhint-disable-next-line
    USDMPriceFeedArbitrum public USDMPriceFeed;

    /// Vaults
    PlasmaVault public plasmaVault;
    address public withdrawManager;

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
            948912945660990214177,
            "Vault total assets should be 948912945660990214177"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssets,
            948912945660990214177,
            "Vault total assets should be 948912945660990214177"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssetsInCurvePool,
            948912945660990214177,
            "Vault total assets in curve pool should be 948912945660990214177 after enter curve pool"
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
            948912945660990214177,
            "Vault total assets in curve gauge should be 948912945660990214177 after enter curve gauge"
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
            948912945660990214177,
            "Vault total assets should be 948912945660990214177 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssets,
            948912945660990214177,
            "Vault total assets should be 948912945660990214177 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssets,
            vaultStateAfterEnterCurveGauge.vaultTotalAssets,
            "Vault total assets should be the same after enter Curve pool and enter gauge fails"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssetsInCurvePool,
            948912945660990214177,
            "Vault total assets in curve pool should be 948912945660990214177 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInCurvePool,
            948912945660990214177,
            "Vault total assets in curve pool should be 948912945660990214177 after enter curve gauge fails"
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
            948912945660990214177,
            "Vault total assets should be 948912945660990214177 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssets,
            948912945660990214177,
            "Vault total assets should be 948912945660990214177 after fail to enter curve gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssets,
            vaultStateAfterEnterCurveGauge.vaultTotalAssets,
            "Vault total assets should be the same after enter Curve pool and fail to enter gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssetsInCurvePool,
            948912945660990214177,
            "Vault total assets in curve pool should be 948912945660990214177 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInCurvePool,
            948912945660990214177,
            "Vault total assets in curve pool should be 948912945660990214177 after fail to enter curve gauge"
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
            948912945660990214177,
            "Vault total assets should be 948912945660990214177 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultTotalAssets,
            948912945660990214177,
            "Vault total assets should be 948912945660990214177 after exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultTotalAssetsInCurvePool,
            0,
            "Vault total assets in curve pool should be 0 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultTotalAssetsInCurvePool,
            948912945660990214177,
            "Vault total assets in curve pool should be 948912945660990214177 after exit curve gauge"
        );
        assertEq(
            vaultStateBeforeExitCurveGauge.vaultTotalAssetsInGauge,
            948912945660990214177,
            "Vault total assets in gauge should be 948912945660990214177 before exit curve gauge"
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
            948912945660990214177,
            "Vault total assets should be 948912945660990214177 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultTotalAssets,
            948912945660990214177,
            "Vault total assets should be 948912945660990214177 after fail to exit curve gauge"
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
            948912945660990214177,
            "Vault total assets in gauge should be 948912945660990214177 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultTotalAssetsInGauge,
            948912945660990214177,
            "Vault total assets in gauge should be 948912945660990214177 after fail to exit curve gauge"
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
            948912945660990214177,
            "Vault total assets should be 948912945660990214177 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultTotalAssets,
            948912945660990214177,
            "Vault total assets should be 948912945660990214177 after fail to exit curve gauge"
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
            948912945660990214177,
            "Vault total assets in gauge should be 948912945660990214177 before exit curve gauge"
        );
        assertEq(
            vaultStateAfterExitCurveGauge.vaultTotalAssetsInGauge,
            948912945660990214177,
            "Vault total assets in gauge should be 948912945660990214177 after fail to exit curve gauge"
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

    /// IL-7950 REGRESSION TESTS
    /// CurveChildLiquidityGaugeBalanceFuse.balanceOf() originally valued the entire staked-LP market
    /// with ICurveStableswapNG.calc_withdraw_one_coin() - an instantaneous single-sided withdrawal
    /// quote computed from the pool's spot balances/D and its dynamic imbalance fee. Cycle 1 replaced
    /// that with oracle-priced pro-rata of the pool's coin balances, which closed the deflate
    /// direction but left the inflate direction open: a same-transaction round-trip swap still moved
    /// the reported NAV by +41.7% on this fixture (cycle-1-verification.md, +41.7% / cost 0.4%-9.2%
    /// of the NAV move, because swaps conserve `D` and refund the outbound leg's slippage on the
    /// return leg). Cycle 2 fixes this by valuing the staked LP as the canonical, swap-invariant
    /// StableSwap LP price `stakedLPTokenBalance * get_virtual_price() / 1e18 * min_j(price(coins(j)))`.
    /// These tests keep BOTH deleted/superseded pre-fix formulas as in-test controls and assert
    /// ON-CHAIN that they move by the vulnerable magnitude, before asserting the fixed fuse output
    /// does not.

    function testShouldNotInflateGaugeBalanceWhenPoolPushedLongVaultAssetByRoundTripSwap() public {
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
        PlasmaVaultState memory snapshot = getPlasmaVaultState();
        uint256 stakedLPTokenBalance = snapshot.vaultStakedLpTokensBalance;

        uint256 preFixQuoteBeforeSwap = _preFixSpotWithdrawalValuationInAsset(stakedLPTokenBalance);
        uint256 cycle1QuoteBeforeSwap = _cycle1SpotProRataValuationInAsset(stakedLPTokenBalance);

        // when - an attacker swaps a large amount of the vault asset (USDM) into the pool, pushing
        // the pool long USDM. In production this is a same-transaction round-trip (swap in, swap
        // back after the manipulated value is read); the return leg is irrelevant to balanceOf(),
        // which only reads the manipulated intermediate spot state, so it is omitted here.
        //
        // NOTE on magnitude: this pool's total USDM circulating supply on Arbitrum, at the pinned
        // fork block, is only ~30k USDM (the dealAssets holder alone accounts for the bulk of it),
        // which hard-caps how much capital a "push long USDM" swap can move in this fixture - unlike
        // the drain direction below, which uses USDC (abundant, effectively uncapped). The swap size
        // here is close to that practical ceiling.
        _swapUSDMIntoPoolPushingLong(19_000 * 10 ** ERC20(asset).decimals());

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = getMarketId();
        vm.prank(admin);
        plasmaVault.updateMarketsBalances(marketIds);

        uint256 fuseBalanceAfterSwap = plasmaVault.totalAssetsInMarket(getMarketId());
        uint256 preFixQuoteAfterSwap = _preFixSpotWithdrawalValuationInAsset(stakedLPTokenBalance);
        uint256 cycle1QuoteAfterSwap = _cycle1SpotProRataValuationInAsset(stakedLPTokenBalance);

        // then - CONTROL 1: the deleted original pre-fix single-sided quote is inflated by the
        // round-trip swap (observed ~+64% on this fixture)
        assertGt(
            preFixQuoteAfterSwap,
            (preFixQuoteBeforeSwap * 150) / 100,
            "control 1: original pre-fix single-sided withdrawal quote should be inflated by more than 50% after the round-trip swap"
        );
        // then - CONTROL 2: the cycle-1 spot pro-rata formula (superseded by this cycle's fix) is
        // ALSO inflated by the round-trip swap (measured by cycle-1-verification.md at +41.7% on
        // this exact fixture; bound set at +30%, ~12pp margin, well clear of noise while still
        // failing hard against the cycle-2 fix's <5% bound below)
        assertGt(
            cycle1QuoteAfterSwap,
            (cycle1QuoteBeforeSwap * 130) / 100,
            "control 2: cycle-1 spot pro-rata valuation should still be inflated by more than 30% after the round-trip swap (measured +41.7%)"
        );
        // then - FIX: the new, swap-invariant valuation (stakedLPTokenBalance * get_virtual_price() /
        // 1e18 * min_j(price)) stays within 5% of the pre-swap snapshot. Curve's invariant `D` is
        // conserved by swaps, so get_virtual_price() only moves by the fee the attacker permanently
        // donated (measured +3.73% on this exact fixture for this exact swap in cycle-1-verification.md
        // section 2.4) - the 5% bound is ~11x tighter than the cycle-1 regression it must catch
        // (41.7% / 5% ~= 8.3x, and ~17x tighter than the original pre-fix regression's 64.3%).
        assertApproxEqRel(
            fuseBalanceAfterSwap,
            snapshot.vaultTotalAssetsInGauge,
            0.05e18, // 5%
            "fixed (cycle-2) fuse balance should stay within 5% of the pre-swap snapshot despite the push, unlike both prior formulas"
        );
    }

    function testShouldNotDeflateGaugeBalanceWhenVaultAssetDrainedFromPool() public {
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
        PlasmaVaultState memory snapshot = getPlasmaVaultState();
        uint256 stakedLPTokenBalance = snapshot.vaultStakedLpTokensBalance;

        uint256 preFixQuoteBeforeSwap = _preFixSpotWithdrawalValuationInAsset(stakedLPTokenBalance);
        uint256 cycle1QuoteBeforeSwap = _cycle1SpotProRataValuationInAsset(stakedLPTokenBalance);

        // when - an attacker swaps a large amount of USDC into the pool, draining the vault asset
        // (USDM) out of it. Same same-transaction round-trip rationale as above. Unlike the push/
        // inflate test, USDC is not capital-constrained on this fork (real, abundant token), so this
        // swap size is well within a realistic (flash-loanable) attack budget for a ~$21k pool.
        _swapUSDCIntoPoolDrainingUSDM(10_000 * 10 ** ERC20(USDC_ARB).decimals());

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = getMarketId();
        vm.prank(admin);
        plasmaVault.updateMarketsBalances(marketIds);

        uint256 fuseBalanceAfterSwap = plasmaVault.totalAssetsInMarket(getMarketId());
        uint256 preFixQuoteAfterSwap = _preFixSpotWithdrawalValuationInAsset(stakedLPTokenBalance);
        uint256 cycle1QuoteAfterSwap = _cycle1SpotProRataValuationInAsset(stakedLPTokenBalance);

        // then - CONTROL 1: the deleted original pre-fix single-sided quote collapses after the
        // drain (observed: collapses to ~19% of its pre-swap value, i.e. a ~81% loss)
        assertLt(
            preFixQuoteAfterSwap,
            preFixQuoteBeforeSwap / 2,
            "control 1: original pre-fix single-sided withdrawal quote should collapse to less than 50% after the drain"
        );
        // then - CONTROL 2: cycle-1's spot pro-rata deflate direction was already materially closed
        // (measured -1.71% in cycle-1-verification.md); this is not a regression this cycle needs to
        // re-catch, but pinning it here proves the control helper reproduces cycle-1's own numbers.
        assertApproxEqRel(
            cycle1QuoteAfterSwap,
            cycle1QuoteBeforeSwap,
            0.05e18, // 5%
            "control 2: cycle-1 spot pro-rata valuation was already within ~5% on the deflate side (measured -1.71%)"
        );
        // then - FIX (symmetric bound to the inflate test above): the new, swap-invariant valuation
        // stays within 5% of the pre-swap snapshot on the drain side too. Swaps conserve `D`, so
        // get_virtual_price() cannot decrease below its pre-swap value from a swap alone (it can only
        // rise, by the fee); the round-trip's permanent effect on this formula is bounded by the fee,
        // symmetric to the inflate case - this bound is ~16x tighter than the original pre-fix
        // regression's 80.8% collapse.
        assertApproxEqRel(
            fuseBalanceAfterSwap,
            snapshot.vaultTotalAssetsInGauge,
            0.05e18, // 5%
            "fixed (cycle-2) fuse balance should stay within 5% of the pre-swap snapshot despite the drain"
        );
    }

    function testGaugeBalanceMatchesCanonicalLpPriceAtHealthyPool() public {
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
        PlasmaVaultState memory snapshot = getPlasmaVaultState();

        // when - independently computed canonical StableSwap LP price (get_virtual_price() *
        // min_j(price)), the same formula the fix uses, computed here directly against the pool (not
        // through the fuse)
        uint256 expectedVirtualPriceUSD = _virtualPriceValuationInAsset(snapshot.vaultStakedLpTokensBalance);
        uint256 preFixQuoteUSD = _preFixSpotWithdrawalValuationInAsset(snapshot.vaultStakedLpTokensBalance);
        uint256 cycle1QuoteUSD = _cycle1SpotProRataValuationInAsset(snapshot.vaultStakedLpTokensBalance);

        // then - the fuse balance equals the independently computed virtual-price valuation
        // (rounding only)
        assertApproxEqRel(
            snapshot.vaultTotalAssetsInGauge,
            expectedVirtualPriceUSD,
            0.0001e18, // 0.01%
            "fuse balance should equal independently computed get_virtual_price()-based valuation"
        );
        // sanity: pins that the healthy-pool controls used in tests 1-2 are not vacuous, i.e. neither
        // superseded formula is just always equal to the new one anyway
        assertGt(
            _absDiff(preFixQuoteUSD, expectedVirtualPriceUSD),
            expectedVirtualPriceUSD / 1000, // > 0.1% apart even at a healthy but imbalanced pool
            "original pre-fix single-sided quote should differ materially from the fix even at a healthy pool"
        );
        assertGt(
            _absDiff(cycle1QuoteUSD, expectedVirtualPriceUSD),
            expectedVirtualPriceUSD / 1000, // > 0.1% apart even at a healthy but imbalanced pool
            "cycle-1 spot pro-rata quote should differ materially from the fix even at a healthy pool"
        );
    }

    /// IL-7950 REGRESSION HELPERS

    /// @dev Deleted pre-fix formula, kept here only as an in-test control. Mirrors exactly what
    /// CurveChildLiquidityGaugeBalanceFuse.balanceOf() used to compute before this fix: a single
    /// `calc_withdraw_one_coin` quote for the vault's underlying asset, priced through the oracle.
    /// @dev PlasmaVault.totalAssetsInMarket() / getPlasmaVaultState().vaultTotalAssetsInGauge report
    /// market balances denominated in the vault's UNDERLYING ASSET (USDM), not in USD - see
    /// PlasmaVaultMarketsLib.updateMarketsBalances(), which divides each fuse's USD (WAD) output by
    /// the underlying asset's oracle price. This helper applies the identical conversion so the
    /// control (pre-fix) and independently-computed pro-rata values below are directly comparable to
    /// the vault's own cached market balance.
    function _usdWadToUnderlyingAssetUnits(uint256 wadUsd_) private view returns (uint256) {
        (uint256 assetPriceInUSD, uint256 assetPriceDecimals) = priceOracleMiddlewareProxy.getAssetPrice(asset);
        return IporMath.division(wadUsd_ * (10 ** assetPriceDecimals), assetPriceInUSD);
    }

    /// @dev Deleted pre-fix formula, kept here only as an in-test control. Mirrors exactly what
    /// CurveChildLiquidityGaugeBalanceFuse.balanceOf() used to compute before this fix: a single
    /// `calc_withdraw_one_coin` quote for the vault's underlying asset, priced through the oracle,
    /// then converted to underlying-asset units the same way PlasmaVaultMarketsLib does.
    function _preFixSpotWithdrawalValuationInAsset(uint256 stakedLPTokenBalance_) private view returns (uint256) {
        if (stakedLPTokenBalance_ == 0) {
            return 0;
        }
        uint256 withdrawUnderlyingTokenAmount = CURVE_STABLESWAP_NG.calc_withdraw_one_coin(
            stakedLPTokenBalance_,
            USDM_COIN_INDEX
        );
        (uint256 assetPriceInUSD, uint256 priceDecimals) = priceOracleMiddlewareProxy.getAssetPrice(asset);
        uint256 wadUsd = IporMath.convertToWad(
            withdrawUnderlyingTokenAmount * assetPriceInUSD,
            ERC20(asset).decimals() + priceDecimals
        );
        return _usdWadToUnderlyingAssetUnits(wadUsd);
    }

    /// @dev Superseded cycle-1 formula (oracle-priced pro-rata of the pool's spot coin balances),
    /// kept here only as an in-test control now that cycle 2 replaces it. Computed directly against
    /// the pool rather than through the fuse, then converted to underlying-asset units the same way
    /// PlasmaVaultMarketsLib does. cycle-1-verification.md proved this formula still lets a
    /// same-transaction round-trip swap inflate the reported NAV by +41.7% - closed the deflate
    /// direction (swaps conserve `D`) but not the inflate direction.
    function _cycle1SpotProRataValuationInAsset(uint256 stakedLPTokenBalance_) private view returns (uint256) {
        if (stakedLPTokenBalance_ == 0) {
            return 0;
        }
        uint256 totalSupply = CURVE_STABLESWAP_NG.totalSupply();
        uint256 nCoins = CURVE_STABLESWAP_NG.N_COINS();
        uint256 balanceUSD;
        for (uint256 j; j < nCoins; ++j) {
            address coin = CURVE_STABLESWAP_NG.coins(j);
            uint256 coinAmount = Math.mulDiv(CURVE_STABLESWAP_NG.balances(j), stakedLPTokenBalance_, totalSupply);
            (uint256 coinPrice, uint256 coinPriceDecimals) = priceOracleMiddlewareProxy.getAssetPrice(coin);
            balanceUSD += IporMath.convertToWad(coinAmount * coinPrice, ERC20(coin).decimals() + coinPriceDecimals);
        }
        return _usdWadToUnderlyingAssetUnits(balanceUSD);
    }

    /// @dev Independent re-implementation of the cycle-2 fix formula: the canonical, swap-invariant
    /// StableSwap LP price `stakedLPTokenBalance * get_virtual_price() / 1e18 * min_j(price(coins(j)))`,
    /// computed directly against the pool rather than through the fuse, then converted to
    /// underlying-asset units the same way PlasmaVaultMarketsLib does. Deliberately does NOT call
    /// into the fuse's own code, so this is a real cross-check, not a tautology.
    function _virtualPriceValuationInAsset(uint256 stakedLPTokenBalance_) private view returns (uint256) {
        if (stakedLPTokenBalance_ == 0) {
            return 0;
        }
        uint256 nCoins = CURVE_STABLESWAP_NG.N_COINS();
        uint256 minCoinPriceWad = type(uint256).max;
        for (uint256 j; j < nCoins; ++j) {
            address coin = CURVE_STABLESWAP_NG.coins(j);
            (uint256 coinPrice, uint256 coinPriceDecimals) = priceOracleMiddlewareProxy.getAssetPrice(coin);
            uint256 coinPriceWad = IporMath.convertToWad(coinPrice, coinPriceDecimals);
            if (coinPriceWad < minCoinPriceWad) {
                minCoinPriceWad = coinPriceWad;
            }
        }
        uint256 lpValueInPegUnitsWad = Math.mulDiv(
            stakedLPTokenBalance_,
            CURVE_STABLESWAP_NG.get_virtual_price(),
            1e18
        );
        uint256 balanceUSD = Math.mulDiv(lpValueInPegUnitsWad, minCoinPriceWad, 1e18);
        return _usdWadToUnderlyingAssetUnits(balanceUSD);
    }

    function _absDiff(uint256 a_, uint256 b_) private pure returns (uint256) {
        return a_ > b_ ? a_ - b_ : b_ - a_;
    }

    /// @dev Swaps USDC into the pool, draining the vault asset (USDM) out of it.
    function _swapUSDCIntoPoolDrainingUSDM(uint256 usdcAmount_) private {
        address attacker = address(0x9999);
        deal(USDC_ARB, attacker, usdcAmount_);
        vm.startPrank(attacker);
        ERC20(USDC_ARB).approve(CURVE_STABLESWAP_NG_POOL, usdcAmount_);
        ICurveStableswapNGExchange(CURVE_STABLESWAP_NG_POOL).exchange(USDC_COIN_INDEX, USDM_COIN_INDEX, usdcAmount_, 0);
        vm.stopPrank();
    }

    /// @dev Swaps USDM into the pool, pushing the pool long the vault asset (USDM).
    function _swapUSDMIntoPoolPushingLong(uint256 usdmAmount_) private {
        address attacker = address(0x9998);
        dealAssets(USDM, attacker, usdmAmount_);
        vm.startPrank(attacker);
        ERC20(USDM).approve(CURVE_STABLESWAP_NG_POOL, usdmAmount_);
        ICurveStableswapNGExchange(CURVE_STABLESWAP_NG_POOL).exchange(USDM_COIN_INDEX, USDC_COIN_INDEX, usdmAmount_, 0);
        vm.stopPrank();
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

        _initAccessManager();
        _setupPlasmaVault();
        // RoleLib.setupPlasmaVaultRoles(
        //     usersToRoles,
        //     vm,
        //     address(plasmaVault),
        //     accessManager,
        //     withdrawManager
        // );

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            address(atomist),
            address(plasmaVault),
            fuses,
            _setupBalanceFuses(),
            _setupMarketConfigs()
        );
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
        assets = new address[](2);
        sources = new address[](2);
        assets[0] = USDM;
        sources[0] = address(USDMPriceFeed);
        assets[1] = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC on Arbitrum
        sources[1] = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3; // Chainlink USDC/USD on Arbitrum
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
        feeConfig = FeeConfigHelper.createZeroFeeConfig();
    }

    function _setupPlasmaVault() private {
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, withdrawManager);

        vm.startPrank(address(rewardsClaimManager));
        PlasmaVaultGovernance(address(plasmaVault)).setRewardsClaimManagerAddress(address(rewardsClaimManager));

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.CURVE_LP_GAUGE;

        uint256[] memory dependencies = new uint256[](1);
        dependencies[0] = IporFusionMarkets.CURVE_POOL;

        uint256[][] memory dependencyMarkets = new uint256[][](1);
        dependencyMarkets[0] = dependencies;

        vm.stopPrank();

        vm.startPrank(atomist);
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
        address withdrawManager = address(new WithdrawManager(address(accessManager)));
        plasmaVault = new PlasmaVault();
        PlasmaVault(plasmaVault).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "PLASMA VAULT",
                assetSymbol: "PLASMA",
                underlyingToken: USDM,
                priceOracleMiddleware: address(priceOracleMiddlewareProxy),
                feeConfig: _setupFeeConfig(),
                accessManager: address(accessManager),
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: address(withdrawManager),
                plasmaVaultVotesPlugin: address(0)
            })
        );
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
                plasmaVault: address(plasmaVault),
                accessManager: address(accessManager),
                rewardsClaimManager: address(rewardsClaimManager),
                withdrawManager: address(0x123),
                feeManager: address(0x123),
                contextManager: address(0x123),
                priceOracleMiddlewareManager: address(0x123)
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
