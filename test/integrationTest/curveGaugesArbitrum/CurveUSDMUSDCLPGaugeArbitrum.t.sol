// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CurveStableswapNGSingleSideSupplyFuse, CurveStableswapNGSingleSideSupplyFuseEnterData, CurveStableswapNGSingleSideSupplyFuseExitData} from "../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideSupplyFuse.sol";
import {CurveStableswapNGSingleSideBalanceFuse} from "../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideBalanceFuse.sol";
import {CurveChildLiquidityGaugeSupplyFuse, CurveChildLiquidityGaugeSupplyFuseEnterData, CurveChildLiquidityGaugeSupplyFuseExitData} from "../../../contracts/fuses/curve_gauge/CurveChildLiquidityGaugeSupplyFuse.sol";
import {CurveChildLiquidityGaugeBalanceFuse} from "../../../contracts/fuses/curve_gauge/CurveChildLiquidityGaugeBalanceFuse.sol";
import {IChildLiquidityGauge} from "../../../contracts/fuses/curve_gauge/ext/IChildLiquidityGauge.sol";
import {ICurveStableswapNG} from "../../../contracts/fuses/curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {FeeConfig, FuseAction, MarketBalanceFuseConfig, MarketSubstratesConfig, PlasmaVaultInitData} from "./../../../contracts/vaults/PlasmaVault.sol";
import {IporPlasmaVault} from "./../../../contracts/vaults/IporPlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionAccessManager} from "./../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RoleLib, UsersToRoles} from "./../../RoleLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/priceOracle/PriceOracleMiddleware.sol";
import {USDMPriceFeedArbitrum} from "../../../contracts/priceOracle/priceFeed/USDMPriceFeedArbitrum.sol";
import {IporFusionMarketsArbitrum} from "../../../contracts/libraries/IporFusionMarketsArbitrum.sol";
import {IChronicle, IToll} from "../../../contracts/priceOracle/IChronicle.sol";

contract CurveUSDMUSDCLPGaugeArbitrum is Test {
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
    IporPlasmaVault public plasmaVault;

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
            CURVE_LIQUIDITY_GAUGE,
            CURVE_STABLESWAP_NG_POOL,
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
        // TODO Confirm if intended behavior: After stake LP tokens in gauge, vaultTotalAssetsInCurvePool is the same as vaultTotalAssetsInGauge, and vaultTotalAssets is the sum of both
        // vaultStateAfterEnterCurveGauge vaultTotalAssets 1999788249352498839192
        // vaultStateAfterEnterCurveGauge vaultTotalAssetsInCurvePool 999894124676249419596
        // vaultStateAfterEnterCurveGauge vaultTotalAssetsInGauge 999894124676249419596
        // vaultTotalAssetsInCurvePool is the same as vaultTotalAssetsInGauge
        // after staking the LP tokens vaultTotalAssets is adding up both vaultTotalAssetsInCurvePool and vaultTotalAssetsInGauge
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssets,
            999894124676249419596,
            "Vault total assets should be 999894124676249419596"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssets,
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInCurvePool +
                vaultStateAfterEnterCurveGauge.vaultTotalAssetsInGauge,
            "Vault vaultTotalAssets should be the sum of vaultTotalAssetsInCurvePool and vaultTotalAssetsInGauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssetsInCurvePool,
            999894124676249419596,
            "Vault total assets in curve pool should be 999894124676249419596 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInCurvePool,
            999894124676249419596,
            "Vault total assets in curve pool should be 999894124676249419596 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInGauge,
            999894124676249419596,
            "Vault total assets in curve pool should be 999894124676249419596 after enter curve pool"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssetsInCurvePool,
            vaultStateAfterEnterCurveGauge.vaultTotalAssetsInCurvePool,
            "Vault total assets in curve pool should be the same after enter curve pool and gauge"
        );
        assertEq(
            vaultStateAfterEnterCurvePool.vaultTotalAssetsInGauge,
            0,
            "Vault total assets in gauge should be 0 after enter curve pool and not stake LP tokens in gauge"
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
        assertLt(
            vaultStateAfterEnterCurvePool.vaultStakedLpTokensBalance,
            vaultStateAfterEnterCurveGauge.vaultStakedLpTokensBalance,
            "Vault staked LP tokens balance should be greater after enter gauge"
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
            IChildLiquidityGauge(unsupportedGauge),
            CURVE_STABLESWAP_NG_POOL,
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
            vaultStateAfterEnterCurveGauge.vaultTotalAssets,
            "Vault total assets should be the same after enter Curve pool and enter gauge fails"
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

    function testShouldNotBeAbleToEnterCurveChildLiquidityGaugeSupplyFuseWithZeroLPDepositAmount() public {
        // given
        uint256 amount = 1_000 * 10 ** ERC20(asset).decimals();
        _depositIntoVaultAndProvideLiquidityToCurvePool(amount);
        PlasmaVaultState memory vaultStateAfterEnterCurvePool = getPlasmaVaultState();

        bytes memory error = abi.encodeWithSignature("CurveChildLiquidityGaugeSupplyFuseZeroDepositAmount()");

        // when
        vm.expectRevert(error);
        _executeCurveChildLiquidityGaugeSupplyFuseEnter(
            curveChildLiquidityGaugeSupplyFuse,
            CURVE_LIQUIDITY_GAUGE,
            CURVE_STABLESWAP_NG_POOL,
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
    }
    /// testShouldNotBeAbleToExitCurveChildLiquidityGaugeSupplyFuseWithUnsupportedLPToken
    /// testShouldNotBeAbleToExitCurveChildLiquidityGaugeSupplyFuseWithZeroWithdrawAmount

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
        _setupRoles();
    }

    function getMarketId() public view returns (uint256) {
        return IporFusionMarketsArbitrum.CURVE_USDM_USDC_LP_GAUGE;
    }

    function _setupAsset() public {
        asset = USDM;
    }

    function dealAssets(address asset_, address account_, uint256 amount_) public {
        vm.prank(0x426c4966fC76Bf782A663203c023578B744e4C5E); // holder
        ERC20(asset_).transfer(account_, amount_);
    }

    function getEnterFuseData(
        uint256 amount_, // amount of tokens (USDM) to supply
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual returns (bytes[] memory data) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0; // USDC
        amounts[1] = amount_; // USDM
        CurveStableswapNGSingleSideSupplyFuseEnterData
            memory enterData = CurveStableswapNGSingleSideSupplyFuseEnterData({
                curveStableswapNG: CURVE_STABLESWAP_NG,
                asset: USDM,
                amount: amounts[1],
                minMintAmount: 0
            });
        CurveChildLiquidityGaugeSupplyFuseEnterData
            memory enterDataGauge = CurveChildLiquidityGaugeSupplyFuseEnterData({
                childLiquidityGauge: CURVE_LIQUIDITY_GAUGE,
                lpToken: CURVE_STABLESWAP_NG_POOL,
                amount: CURVE_STABLESWAP_NG.calc_token_amount(amounts, true) // LP tokens to stake
            });
        data = new bytes[](2);
        data[0] = abi.encode(enterData);
        data[1] = abi.encode(enterDataGauge);
    }

    function getExitFuseData(
        uint256 amount_, // amount of LP tokens to burn
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual returns (address[] memory fusesSetup, bytes[] memory data) {
        CurveStableswapNGSingleSideSupplyFuseExitData memory exitData = CurveStableswapNGSingleSideSupplyFuseExitData({
            curveStableswapNG: CURVE_STABLESWAP_NG,
            burnAmount: amount_,
            asset: USDM,
            minReceived: 0
        });
        CurveChildLiquidityGaugeSupplyFuseExitData memory exitDataGauge = CurveChildLiquidityGaugeSupplyFuseExitData({
            childLiquidityGauge: CURVE_LIQUIDITY_GAUGE,
            lpToken: CURVE_STABLESWAP_NG_POOL,
            amount: amount_
        });
        data = new bytes[](2);
        data[1] = abi.encode(exitData);
        data[0] = abi.encode(exitDataGauge);

        fusesSetup = new address[](2);
        fusesSetup[0] = address(curveStableswapNGSingleSideSupplyFuse);
        fusesSetup[1] = address(curveChildLiquidityGaugeSupplyFuse);
    }

    /// SETUP INIT FUNCTIONS

    function _createAccessManager() private {
        if (usersToRoles.superAdmin == address(0)) {
            usersToRoles.superAdmin = atomist;
            usersToRoles.atomist = atomist;
            address[] memory alphas = new address[](1);
            alphas[0] = alpha;
            usersToRoles.alphas = alphas;
        }
        accessManager = IporFusionAccessManager(RoleLib.createAccessManager(usersToRoles, vm));
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
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarketsArbitrum.CURVE_USDM_USDC_LP, substratesCurvePool);

        bytes32[] memory substratesCurveGauge = new bytes32[](1);
        substratesCurveGauge[0] = PlasmaVaultConfigLib.addressToBytes32(CHILD_LIQUIDITY_GAUGE);
        marketConfigs[1] = MarketSubstratesConfig(
            IporFusionMarketsArbitrum.CURVE_USDM_USDC_LP_GAUGE,
            substratesCurveGauge
        );
        return marketConfigs;
    }

    function _setupFuses() private {
        curveStableswapNGSingleSideSupplyFuse = new CurveStableswapNGSingleSideSupplyFuse(
            IporFusionMarketsArbitrum.CURVE_USDM_USDC_LP
        );
        curveChildLiquidityGaugeSupplyFuse = new CurveChildLiquidityGaugeSupplyFuse(
            IporFusionMarketsArbitrum.CURVE_USDM_USDC_LP_GAUGE
        );
        fuses = new address[](2);
        fuses[0] = address(curveStableswapNGSingleSideSupplyFuse);
        fuses[1] = address(curveChildLiquidityGaugeSupplyFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        CurveStableswapNGSingleSideBalanceFuse curveStableswapNGBalanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
                IporFusionMarketsArbitrum.CURVE_USDM_USDC_LP,
                address(priceOracleMiddlewareProxy)
            );

        CurveChildLiquidityGaugeBalanceFuse curveChildLiquidityGaugeBalanceFuse = new CurveChildLiquidityGaugeBalanceFuse(
                IporFusionMarketsArbitrum.CURVE_USDM_USDC_LP_GAUGE,
                address(priceOracleMiddlewareProxy)
            );

        balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(
            IporFusionMarketsArbitrum.CURVE_USDM_USDC_LP,
            address(curveStableswapNGBalanceFuse)
        );
        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarketsArbitrum.CURVE_USDM_USDC_LP_GAUGE,
            address(curveChildLiquidityGaugeBalanceFuse)
        );
    }

    function _setupFeeConfig() private view returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfig({
            performanceFeeManager: address(this),
            performanceFeeInPercentage: 0,
            managementFeeManager: address(this),
            managementFeeInPercentage: 0
        });
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

    function _createPlasmaVault() private {
        plasmaVault = new IporPlasmaVault(
            PlasmaVaultInitData({
                assetName: "PLASMA VAULT",
                assetSymbol: "PLASMA",
                underlyingToken: USDM,
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

    function _setupRoles() private {
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager);
    }

    /// HELPERS
    function _depositIntoVaultAndProvideLiquidityToCurvePool(uint256 amount) private {
        dealAssets(asset, depositor, amount);
        vm.startPrank(depositor);
        ERC20(asset).approve(address(plasmaVault), amount);
        plasmaVault.deposit(amount, address(depositor));
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
        vm.startPrank(alpha);
        plasmaVault.execute(calls);
        vm.stopPrank();
    }

    function _executeCurveChildLiquidityGaugeSupplyFuseEnter(
        CurveChildLiquidityGaugeSupplyFuse fuseInstance,
        IChildLiquidityGauge curveGauge,
        address lpToken,
        uint256 amount,
        bool success
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

        if (success) {
            vm.expectEmit(true, true, true, true);
            emit CurveChildLiquidityGaugeSupplyFuseEnter(address(fuseInstance), lpToken, amount);
        }

        // Perform the operation
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