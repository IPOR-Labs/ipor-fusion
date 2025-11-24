// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVault, PlasmaVaultInitData, FuseAction, MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLib} from "../../../contracts/factory/lib/FusionFactoryLib.sol";
import {FusionFactoryStorageLib} from "../../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {RewardsManagerFactory} from "../../../contracts/factory/RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "../../../contracts/factory/WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "../../../contracts/factory/ContextManagerFactory.sol";
import {PriceManagerFactory} from "../../../contracts/factory/PriceManagerFactory.sol";
import {PlasmaVaultFactory} from "../../../contracts/factory/PlasmaVaultFactory.sol";
import {AccessManagerFactory} from "../../../contracts/factory/AccessManagerFactory.sol";
import {FeeManagerFactory} from "../../../contracts/managers/fee/FeeManagerFactory.sol";
import {MockERC20} from "../../test_helpers/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {BurnRequestFeeFuse} from "../../../contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IPriceFeed} from "../../../contracts/price_oracle/price_feed/IPriceFeed.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";

import {TacStakingStorageLib} from "../../../contracts/fuses/tac/lib/TacStakingStorageLib.sol";
import {TacStakingDelegatorAddressReader} from "../../../contracts/readers/TacStakingDelegatorAddressReader.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {TacValidatorAddressConverter} from "../../../contracts/fuses/tac/lib/TacValidatorAddressConverter.sol";
import {Description, CommissionRates} from "../../../contracts/fuses/tac/ext/IStaking.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "../../../contracts/libraries/PlasmaVaultLib.sol";

import {BalanceFusesReader} from "../../../contracts/readers/BalanceFusesReader.sol";

// Import Yield Basis fuses
import {YieldBasisLtBalanceFuse} from "../../../contracts/fuses/yield_basis/YieldBasisLtBalanceFuse.sol";
import {YieldBasisLtSupplyFuse, YieldBasisLtSupplyFuseEnterData, YieldBasisLtSupplyFuseExitData} from "../../../contracts/fuses/yield_basis/YieldBasisLtSupplyFuse.sol";
import {IYieldBasisLT} from "../../../contracts/fuses/yield_basis/ext/IYieldBasisLT.sol";

// Import test helpers
import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../../test_helpers/PlasmaVaultHelper.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PriceOracleMiddlewareHelper} from "../../test_helpers/PriceOracleMiddlewareHelper.sol";

interface IGaugeController {
    function add_gauge(address gauge) external;
}
contract YieldBasisFuseTest is Test {
    // using SafeERC20 for IERC20;
    // address constant FUSION_FACTORY = 0x134fCAce7a2C7Ef3dF2479B62f03ddabAEa922d5;
    address constant FUSION_PRICE_MANAGER = 0x134fCAce7a2C7Ef3dF2479B62f03ddabAEa922d5;

    address constant YIELD_BASIS_LT_WBTC = 0x6095a220C5567360d459462A25b1AD5aEAD45204;
    address constant YIELD_BASIS_LT_WBTC_ADMIN = 0x370a449FeBb9411c95bf897021377fe0B7D100c0;

    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WBTC_HOLDER = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;

    // Constants from StakeDaoV2FuseTest
    address constant CHAINLINK_PRICE_FEED_USDC = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant CHAINLINK_PRICE_FEED_WBTC = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;

    address constant CHAINLINK_PRICE_FEED_CRV_USD = 0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    ///crvUSD
    address constant CRV_USD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    address constant GAUGE_CONTROLLER = 0x1Be14811A3a06F6aF4fA64310a636e1Df04c1c21;
    address constant GAUGE_CONTROLLER_ADMIN = 0x42F2A41A0D0e65A440813190880c8a65124895Fa;
    address constant GAUGE = 0x37f45E64935e7B8383D2f034048B32770B04E8bd;
    // Custom market ID for Yield Basis
    uint256 constant YIELD_BASIS_MARKET_ID = IporFusionMarkets.YIELD_BASIS_LT;

    address user;
    address atomist;
    address alpha;

    bytes32[] substrates;
    address yieldBasisSupplyFuse;
    address yieldBasisBalanceFuse;

    // Fusion Factory related variables
    FusionFactory fusionFactory;
    PlasmaVault plasmaVault;
    IporFusionAccessManager accessManager;
    address withdrawManager;
    address priceOracle;

    uint256 vaultLtBalanceAfter;
    uint256 vaultBalanceAfter;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23527830);

        user = address(0x333);
        atomist = address(0x777);
        alpha = address(0x555);

        _setupFusionFactory();
    }

    function testShouldCreateVaultWithFusionFactoryAndConfigureYieldBasisFuses() public {
        // Create vault using fusion factory
        _createVaultWithFusionFactory();

        // Verify vault was created successfully
        assertTrue(address(plasmaVault) != address(0), "Plasma vault should be created");
        assertTrue(address(accessManager) != address(0), "Access manager should be created");

        // Grant necessary roles to atomist
        vm.startPrank(atomist);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, atomist, 0);
        vm.stopPrank();

        // Configure yield basis fuses after vault creation
        _addYieldBasisFuses();

        // Verify yield basis fuses are configured
        PlasmaVaultGovernance governanceVault = PlasmaVaultGovernance(address(plasmaVault));

        // Check if balance fuse is supported
        assertTrue(
            governanceVault.isBalanceFuseSupported(YIELD_BASIS_MARKET_ID, yieldBasisBalanceFuse),
            "Yield basis balance fuse should be supported"
        );

        // Check if supply fuse is in the fuses list
        address[] memory fuses = governanceVault.getFuses();
        bool foundSupplyFuse = false;
        for (uint256 i = 0; i < fuses.length; i++) {
            if (fuses[i] == yieldBasisSupplyFuse) {
                foundSupplyFuse = true;
                break;
            }
        }
        assertTrue(foundSupplyFuse, "Yield basis supply fuse should be in fuses list");

        // Verify substrates are granted
        bytes32[] memory grantedSubstrates = governanceVault.getMarketSubstrates(YIELD_BASIS_MARKET_ID);
        assertEq(grantedSubstrates.length, 1, "Should have one substrate granted");
        assertEq(
            PlasmaVaultConfigLib.bytes32ToAddress(grantedSubstrates[0]),
            YIELD_BASIS_LT_WBTC,
            "Substrate should be YIELD_BASIS_LT_WBTC"
        );

        // Test balance calculation by calling the balance fuse directly
        uint256 balance = YieldBasisLtBalanceFuse(yieldBasisBalanceFuse).balanceOf();
        assertTrue(balance >= 0, "Balance should be calculated successfully");

        // Test total assets in market
        uint256 totalAssetsInMarket = plasmaVault.totalAssetsInMarket(YIELD_BASIS_MARKET_ID);
        assertTrue(totalAssetsInMarket >= 0, "Total assets in market should be calculated successfully");
    }

    function testShouldSupplyAndWithdrawFromYieldBasis() public {
        // given
        _createVaultWithFusionFactory();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, atomist, 0);
        accessManager.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, atomist, 0);
        vm.stopPrank();

        _setupPriceOracleMiddleware();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.ALPHA_ROLE, alpha, 0);
        accessManager.grantRole(Roles.WHITELIST_ROLE, user, 0);
        accessManager.grantRole(Roles.WHITELIST_ROLE, WBTC_HOLDER, 0);
        vm.stopPrank();

        _addYieldBasisFuses();

        uint256 supplyLtAssetAmount = 1e5;

        _fundVaultWithWBTC(supplyLtAssetAmount);

        vm.warp(block.timestamp + 1);

        uint256 totalAssetBefore = plasmaVault.totalAssets();
        uint256 wbtcBalanceBefore = IERC20(WBTC).balanceOf(address(plasmaVault));
        uint256 balanceInMarketBeforeSupply = plasmaVault.totalAssetsInMarket(YIELD_BASIS_MARKET_ID);
        uint256 yieldBasisLtBalanceBeforeSupply = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));

        // when
        _executeSupply(supplyLtAssetAmount);

        uint256 yieldBasisLtBalanceAfterSupply = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));
        uint256 balanceInMarketAfterSupply = plasmaVault.totalAssetsInMarket(YIELD_BASIS_MARKET_ID);
        uint256 wbtcBalanceAfter = IERC20(WBTC).balanceOf(address(plasmaVault));
        uint256 totalAssetAfter = plasmaVault.totalAssets();

        assertGt(yieldBasisLtBalanceAfterSupply, 0, "Should have Yield Basis LT tokens after supply");
        assertGt(
            yieldBasisLtBalanceAfterSupply,
            yieldBasisLtBalanceBeforeSupply,
            "Yield Basis LT balance should increase after supply"
        );

        assertGt(balanceInMarketAfterSupply, 0, "Market balance should be greater than 0 after supply");
        assertGt(
            balanceInMarketAfterSupply,
            balanceInMarketBeforeSupply,
            "Market balance should increase after supply"
        );

        assertLt(wbtcBalanceAfter, wbtcBalanceBefore, "WBTC balance should decrease after supply");

        uint256 withdrawLtSharesAmount = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));

        YieldBasisLtSupplyFuseExitData memory exitData = YieldBasisLtSupplyFuseExitData({
            ltAddress: YIELD_BASIS_LT_WBTC,
            ltSharesAmount: withdrawLtSharesAmount,
            minLtAssetAmountToReceive: 0
        });

        FuseAction[] memory withdrawActions = new FuseAction[](1);
        withdrawActions[0] = FuseAction({
            fuse: yieldBasisSupplyFuse,
            data: abi.encodeWithSignature("exit((address,uint256,uint256))", exitData)
        });

        vm.prank(alpha);
        plasmaVault.execute(withdrawActions);

        uint256 yieldBasisLtBalanceAfterWithdraw = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));
        uint256 balanceInMarketAfterWithdraw = plasmaVault.totalAssetsInMarket(YIELD_BASIS_MARKET_ID);
        uint256 wbtcBalanceAfterWithdraw = IERC20(WBTC).balanceOf(address(plasmaVault));
        uint256 totalAssetAfterWithdraw = plasmaVault.totalAssets();

        assertEq(
            yieldBasisLtBalanceAfterWithdraw,
            yieldBasisLtBalanceBeforeSupply,
            "Yield Basis LT balance should be equal to the initial balance after withdrawal"
        );
        assertEq(balanceInMarketAfterWithdraw, 0, "Market balance should be 0 after withdrawal");

        assertEq(
            balanceInMarketAfterWithdraw,
            balanceInMarketBeforeSupply,
            "Market balance should be equal to the initial balance after withdrawal from Yield Basis LT"
        );
        assertGt(
            wbtcBalanceAfterWithdraw,
            wbtcBalanceAfter,
            "WBTC balance should increase on Plasma Vault after withdrawal from Yield Basis LT"
        );
    }

    function testShouldSupplyAndWithdrawHalfFromYieldBasis() public {
        // given
        _createVaultWithFusionFactory();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, atomist, 0);
        accessManager.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, atomist, 0);
        vm.stopPrank();

        _setupPriceOracleMiddleware();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.ALPHA_ROLE, alpha, 0);
        accessManager.grantRole(Roles.WHITELIST_ROLE, user, 0);
        accessManager.grantRole(Roles.WHITELIST_ROLE, WBTC_HOLDER, 0);
        vm.stopPrank();

        _addYieldBasisFuses();

        uint256 supplyLtAssetAmount = 1e5;

        _fundVaultWithWBTC(supplyLtAssetAmount);

        vm.warp(block.timestamp + 1);

        uint256 totalAssetBefore = plasmaVault.totalAssets();
        uint256 wbtcBalanceBefore = IERC20(WBTC).balanceOf(address(plasmaVault));
        uint256 balanceInMarketBeforeSupply = plasmaVault.totalAssetsInMarket(YIELD_BASIS_MARKET_ID);
        uint256 yieldBasisLtBalanceBeforeSupply = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));

        //when
        _executeSupply(supplyLtAssetAmount);

        uint256 yieldBasisLtBalanceAfterSupply = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));
        uint256 balanceInMarketAfterSupply = plasmaVault.totalAssetsInMarket(YIELD_BASIS_MARKET_ID);
        uint256 wbtcBalanceAfter = IERC20(WBTC).balanceOf(address(plasmaVault));
        uint256 totalAssetAfter = plasmaVault.totalAssets();

        assertGt(yieldBasisLtBalanceAfterSupply, 0, "Should have Yield Basis LT tokens after supply");
        assertGt(
            yieldBasisLtBalanceAfterSupply,
            yieldBasisLtBalanceBeforeSupply,
            "Yield Basis LT balance should increase after supply"
        );

        assertGt(balanceInMarketAfterSupply, 0, "Market balance should be greater than 0 after supply");
        assertGt(
            balanceInMarketAfterSupply,
            balanceInMarketBeforeSupply,
            "Market balance should increase after supply"
        );

        assertLt(wbtcBalanceAfter, wbtcBalanceBefore, "WBTC balance should decrease after supply");

        uint256 withdrawLtSharesAmount = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));

        YieldBasisLtSupplyFuseExitData memory exitData = YieldBasisLtSupplyFuseExitData({
            ltAddress: YIELD_BASIS_LT_WBTC,
            ltSharesAmount: withdrawLtSharesAmount / 2, // Withdraw half of the shares
            minLtAssetAmountToReceive: 0
        });

        FuseAction[] memory withdrawActions = new FuseAction[](1);
        withdrawActions[0] = FuseAction({
            fuse: yieldBasisSupplyFuse,
            data: abi.encodeWithSignature("exit((address,uint256,uint256))", exitData)
        });

        vm.prank(alpha);
        plasmaVault.execute(withdrawActions);

        uint256 yieldBasisLtBalanceAfterWithdraw = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));
        uint256 balanceInMarketAfterWithdraw = plasmaVault.totalAssetsInMarket(YIELD_BASIS_MARKET_ID);
        uint256 wbtcBalanceAfterWithdraw = IERC20(WBTC).balanceOf(address(plasmaVault));
        uint256 totalAssetAfterWithdraw = plasmaVault.totalAssets();

        assertGt(
            yieldBasisLtBalanceAfterWithdraw,
            49e13,
            "Yield Basis LT balance should be equal to the initial balance after withdrawal"
        );
        assertEq(balanceInMarketAfterWithdraw, 49971, "Market balance should be 49971 after withdrawal");

        assertEq(
            balanceInMarketAfterWithdraw,
            49971,
            "Market balance should be equal to 49971 after withdrawal from Yield Basis LT"
        );
        assertEq(wbtcBalanceAfterWithdraw, 49979, "WBTC balance should be 49979 after withdrawal from Yield Basis LT");
    }

    function testVerySimpleInteractionWithYieldBasisLT() public {
        uint256 depositAmount = 1e3;

        // Get initial balances
        uint256 userWbtcBalanceBefore = IERC20(WBTC).balanceOf(WBTC_HOLDER);

        uint256 userLtBalanceBefore = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(WBTC_HOLDER);

        uint256 ltTotalSupplyBefore = IYieldBasisLT(YIELD_BASIS_LT_WBTC).totalSupply();

        vm.startPrank(WBTC_HOLDER);
        IERC20(WBTC).approve(YIELD_BASIS_LT_WBTC, depositAmount);
        IYieldBasisLT(YIELD_BASIS_LT_WBTC).deposit(depositAmount, 15e18, 0, WBTC_HOLDER);
        vm.stopPrank();

        uint256 userWbtcBalanceAfterDeposit = IERC20(WBTC).balanceOf(WBTC_HOLDER);
        uint256 userLtBalanceAfterDeposit = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(WBTC_HOLDER);
        uint256 ltTotalSupplyAfterDeposit = IYieldBasisLT(YIELD_BASIS_LT_WBTC).totalSupply();

        vm.warp(block.timestamp + 1);

        uint256 withdrawAmount = userLtBalanceAfterDeposit; // Withdraw all LT tokens
        vm.startPrank(WBTC_HOLDER);
        IYieldBasisLT(YIELD_BASIS_LT_WBTC).withdraw(withdrawAmount, 0, WBTC_HOLDER);
        vm.stopPrank();

        uint256 userWbtcBalanceAfterWithdraw = IERC20(WBTC).balanceOf(WBTC_HOLDER);
        uint256 userLtBalanceAfterWithdraw = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(WBTC_HOLDER);
        uint256 ltTotalSupplyAfterWithdraw = IYieldBasisLT(YIELD_BASIS_LT_WBTC).totalSupply();

        assertEq(
            userLtBalanceAfterWithdraw,
            userLtBalanceBefore,
            "User LT balance should return to initial state after withdrawal"
        );
        assertGt(
            userWbtcBalanceAfterWithdraw,
            userWbtcBalanceAfterDeposit,
            "User WBTC balance should increase after withdrawal"
        );
        assertEq(
            ltTotalSupplyAfterWithdraw,
            ltTotalSupplyBefore,
            "LT total supply should return to initial state after withdrawal"
        );
    }

    function testShouldInstantWithdrawHalfFromYieldBasis() public {
        _createVaultWithFusionFactory();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, atomist, 0);
        accessManager.grantRole(Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, atomist, 0);
        accessManager.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, atomist, 0);
        vm.stopPrank();

        _setupPriceOracleMiddleware();

        _addYieldBasisFuses();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.ALPHA_ROLE, alpha, 0);
        accessManager.grantRole(Roles.WHITELIST_ROLE, user, 0);
        accessManager.grantRole(Roles.WHITELIST_ROLE, WBTC_HOLDER, 0);
        vm.stopPrank();

        uint256 userDepositAmount = 1e3;

        _fundVaultWithWBTC(userDepositAmount);

        _configureInstantWithdrawFuses();

        // Supply to Yield Basis
        _executeSupply(userDepositAmount);

        // Verify supply was successful
        uint256 ltBalanceAfterSupply = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));

        assertGt(ltBalanceAfterSupply, 0, "Should have LT tokens after supply");

        vm.warp(block.timestamp + 1);

        uint256 holderBalanceBefore = IERC20(WBTC).balanceOf(WBTC_HOLDER);

        uint256 wbtcHolderPlasmaVaultShares = plasmaVault.balanceOf(WBTC_HOLDER);
        uint256 wbtcHolderPlasmaVaultAssets = plasmaVault.convertToAssets(wbtcHolderPlasmaVaultShares);

        uint256 wbtcHolderMaxWithdrawHalfAssets = wbtcHolderPlasmaVaultAssets / 2; /// @dev Half of the assets
        uint256 wbtcHolderBalanceBeforeWithdraw = plasmaVault.balanceOf(WBTC_HOLDER);
        //when
        vm.startPrank(WBTC_HOLDER);
        plasmaVault.withdraw(wbtcHolderMaxWithdrawHalfAssets, WBTC_HOLDER, WBTC_HOLDER);
        vm.stopPrank();

        // then
        uint256 holderBalanceAfter = IERC20(WBTC).balanceOf(WBTC_HOLDER);
        uint256 wbtcHolderBalanceAfterWithdraw = plasmaVault.balanceOf(WBTC_HOLDER);

        /// @dev Aprox because of fee
        assertApproxEqAbs(
            holderBalanceBefore,
            holderBalanceAfter,
            1000,
            "WBTC holder balance should not change during withdrawal"
        );
        assertLt(
            wbtcHolderBalanceAfterWithdraw,
            wbtcHolderBalanceBeforeWithdraw,
            "User balance should decrease after withdrawal"
        );
    }

    function testShouldInstantWithdrawAllFromYieldBasis() public {
        _createVaultWithFusionFactory();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, atomist, 0);
        accessManager.grantRole(Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, atomist, 0);
        accessManager.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, atomist, 0);
        vm.stopPrank();

        _setupPriceOracleMiddleware();

        _addYieldBasisFuses();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.ALPHA_ROLE, alpha, 0);
        accessManager.grantRole(Roles.WHITELIST_ROLE, user, 0);
        accessManager.grantRole(Roles.WHITELIST_ROLE, WBTC_HOLDER, 0);
        vm.stopPrank();

        uint256 userDepositAmount = 1e3; /// 1000

        _fundVaultWithWBTC(userDepositAmount);

        _configureInstantWithdrawFuses();

        _executeSupply(userDepositAmount); //received 8397887046024 shares

        uint256 ltBalanceAfterSupply = IYieldBasisLT(YIELD_BASIS_LT_WBTC).balanceOf(address(plasmaVault));

        assertGt(ltBalanceAfterSupply, 0, "Should have LT tokens after supply");

        vm.warp(block.timestamp + 1);

        uint256 holderBalanceBefore = IERC20(WBTC).balanceOf(WBTC_HOLDER);

        uint256 wbtcHolderPlasmaVaultShares = plasmaVault.balanceOf(WBTC_HOLDER);
        uint256 wbtcHolderPlasmaVaultAssets = plasmaVault.convertToAssets(wbtcHolderPlasmaVaultShares);

        uint256 wbtcHolderMaxWithdrawAllAssets = wbtcHolderPlasmaVaultAssets;
        uint256 wbtcHolderBalanceBeforeWithdraw = plasmaVault.balanceOf(WBTC_HOLDER);

        //when
        vm.startPrank(WBTC_HOLDER);
        plasmaVault.withdraw(wbtcHolderMaxWithdrawAllAssets, WBTC_HOLDER, WBTC_HOLDER);
        vm.stopPrank();

        // then
        uint256 holderBalanceAfter = IERC20(WBTC).balanceOf(WBTC_HOLDER);
        uint256 wbtcHolderBalanceAfterWithdraw = plasmaVault.balanceOf(WBTC_HOLDER);

        assertApproxEqAbs(
            holderBalanceBefore,
            holderBalanceAfter,
            1000,
            "WBTC holder balance should not change during withdrawal"
        );
        assertLt(
            wbtcHolderBalanceAfterWithdraw,
            wbtcHolderBalanceBeforeWithdraw,
            "User balance should decrease after withdrawal"
        );
    }

    function testShouldRevertOnUnsupportedAsset() public {
        // Setup vault and fuses
        _createVaultWithFusionFactory();
        _grantRoles();
        _addYieldBasisFuses();

        // Try to supply with unsupported asset
        address unsupportedAsset = address(0x999);
        YieldBasisLtSupplyFuseEnterData memory enterData = YieldBasisLtSupplyFuseEnterData({
            ltAddress: unsupportedAsset,
            ltAssetAmount: 1e5,
            debt: 0,
            minSharesToReceive: 1e8
        });

        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction({
            fuse: yieldBasisSupplyFuse,
            data: abi.encodeWithSignature("enter((address,uint256,uint256,uint256))", enterData)
        });

        // Should revert with unsupported asset
        vm.prank(alpha);
        vm.expectRevert();
        plasmaVault.execute(supplyActions);
    }

    // Helper functions
    function _grantRoles() private {
        vm.startPrank(atomist);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, atomist, 0);
        accessManager.grantRole(Roles.ALPHA_ROLE, alpha, 0);
        vm.stopPrank();
    }

    function _fundVaultWithWBTC(uint256 amount) private {
        vm.startPrank(WBTC_HOLDER);
        IERC20(WBTC).approve(address(plasmaVault), amount);
        plasmaVault.deposit(amount, WBTC_HOLDER);
        vm.stopPrank();
    }

    function _executeSupply(uint256 amount) private {
        YieldBasisLtSupplyFuseEnterData memory enterData = YieldBasisLtSupplyFuseEnterData({
            ltAddress: YIELD_BASIS_LT_WBTC,
            ltAssetAmount: amount,
            debt: 20e18,
            minSharesToReceive: (amount * 95) / 100
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: yieldBasisSupplyFuse,
            data: abi.encodeWithSignature("enter((address,uint256,uint256,uint256))", enterData)
        });

        vm.prank(alpha);
        plasmaVault.execute(actions);
    }

    function _executeDirectDeposit(uint256 amount) private {
        YieldBasisLtSupplyFuseEnterData memory enterData = YieldBasisLtSupplyFuseEnterData({
            ltAddress: YIELD_BASIS_LT_WBTC,
            ltAssetAmount: amount,
            debt: 0, // No debt for direct deposit
            minSharesToReceive: (amount * 95) / 100
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: yieldBasisSupplyFuse,
            data: abi.encodeWithSignature("enter((address,uint256,uint256,uint256))", enterData)
        });

        vm.prank(alpha);
        plasmaVault.execute(actions);
    }

    function _executeDirectWithdraw(uint256 ltSharesAmount) private {
        YieldBasisLtSupplyFuseExitData memory exitData = YieldBasisLtSupplyFuseExitData({
            ltAddress: YIELD_BASIS_LT_WBTC,
            ltSharesAmount: ltSharesAmount,
            minLtAssetAmountToReceive: 0
        });

        FuseAction[] memory withdrawActions = new FuseAction[](1);
        withdrawActions[0] = FuseAction({
            fuse: yieldBasisSupplyFuse,
            data: abi.encodeWithSignature("exit((address,uint256,uint256))", exitData)
        });

        vm.prank(alpha);
        plasmaVault.execute(withdrawActions);
    }

    function _configureInstantWithdrawFuses() private {
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);

        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = bytes32(0); // amount placeholder
        instantWithdrawParams[1] = bytes32(uint256(uint160(YIELD_BASIS_LT_WBTC))); // LT address

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: yieldBasisSupplyFuse,
            params: instantWithdrawParams
        });

        vm.prank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);
    }

    function _setupFusionFactory() private {
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = FusionFactoryStorageLib.FactoryAddresses({
            accessManagerFactory: address(new AccessManagerFactory()),
            plasmaVaultFactory: address(new PlasmaVaultFactory()),
            feeManagerFactory: address(new FeeManagerFactory()),
            withdrawManagerFactory: address(new WithdrawManagerFactory()),
            rewardsManagerFactory: address(new RewardsManagerFactory()),
            contextManagerFactory: address(new ContextManagerFactory()),
            priceManagerFactory: address(new PriceManagerFactory())
        });

        address plasmaVaultBase = address(new PlasmaVaultBase());
        address burnRequestFeeFuse = address(new BurnRequestFeeFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));
        address burnRequestFeeBalanceFuse = address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));

        PriceOracleMiddleware priceOracleMiddlewareImplementation = new PriceOracleMiddleware(address(0));
        address priceOracleMiddleware = address(
            new ERC1967Proxy(
                address(priceOracleMiddlewareImplementation),
                abi.encodeWithSignature("initialize(address)", atomist)
            )
        );

        FusionFactory implementation = new FusionFactory();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address[],(address,address,address,address,address,address,address),address,address,address,address)",
            atomist,
            new address[](0), // No plasma vault admins
            factoryAddresses,
            plasmaVaultBase,
            priceOracleMiddleware,
            burnRequestFeeFuse,
            burnRequestFeeBalanceFuse
        );
        fusionFactory = FusionFactory(address(new ERC1967Proxy(address(implementation), initData)));

        vm.startPrank(atomist);
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), atomist);
        vm.stopPrank();

        vm.startPrank(atomist);
        fusionFactory.updateDaoFee(atomist, 100, 100);
        vm.stopPrank();
    }

    function _setupPriceOracleMiddleware() private {
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = WBTC;
        sources[0] = CHAINLINK_PRICE_FEED_WBTC;

        vm.startPrank(atomist);
        PriceOracleMiddlewareManager(priceOracle).setAssetsPriceSources(assets, sources);
        vm.stopPrank();
    }

    function _createVaultWithFusionFactory() private {
        FusionFactoryLib.FusionInstance memory instance = fusionFactory.create(
            "Yield Basis Vault",
            "yieldBasisVault",
            WBTC,
            1 seconds,
            atomist
        );

        plasmaVault = PlasmaVault(instance.plasmaVault);
        accessManager = IporFusionAccessManager(instance.accessManager);
        withdrawManager = instance.withdrawManager;
        priceOracle = instance.priceManager;
    }

    function _addYieldBasisFuses() private {
        // Deploy yield basis fuses
        yieldBasisSupplyFuse = address(new YieldBasisLtSupplyFuse(YIELD_BASIS_MARKET_ID));
        yieldBasisBalanceFuse = address(new YieldBasisLtBalanceFuse(YIELD_BASIS_MARKET_ID));

        address[] memory fuses = new address[](1);
        fuses[0] = yieldBasisSupplyFuse;

        vm.startPrank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(YIELD_BASIS_MARKET_ID, yieldBasisBalanceFuse);

        // Set up substrates for yield basis (LT addresses as assets)
        substrates = new bytes32[](1);
        substrates[0] = bytes32(uint256(uint160(YIELD_BASIS_LT_WBTC)));

        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(YIELD_BASIS_MARKET_ID, substrates);
        vm.stopPrank();
    }

    function _setupSimpleVault() private {
        // Use PlasmaVaultHelper to create a simple vault with proper role setup

        // Deploy price oracle middleware
        vm.startPrank(atomist);
        PriceOracleMiddleware priceOracleMiddleware = PriceOracleMiddlewareHelper.deployPriceOracleMiddleware(
            atomist,
            address(0)
        );
        vm.stopPrank();

        // Deploy minimal plasma vault
        DeployMinimalPlasmaVaultParams memory params = DeployMinimalPlasmaVaultParams({
            underlyingToken: WBTC,
            underlyingTokenName: "WBTC",
            priceOracleMiddleware: PriceOracleMiddlewareHelper.addressOf(priceOracleMiddleware),
            atomist: atomist
        });

        vm.startPrank(atomist);
        (plasmaVault, withdrawManager) = PlasmaVaultHelper.deployMinimalPlasmaVault(params);

        accessManager = IporFusionAccessManager(plasmaVault.authority());

        // Create custom role addresses for our test
        IporFusionAccessManagerHelper.RoleAddresses memory customRoles = IporFusionAccessManagerHelper.RoleAddresses({
            daos: new address[](1),
            admins: new address[](1),
            owners: new address[](1),
            atomists: new address[](1),
            alphas: new address[](1),
            guardians: new address[](1),
            fuseManagers: new address[](1),
            claimRewards: new address[](1),
            transferRewardsManagers: new address[](1),
            configInstantWithdrawalFusesManagers: new address[](1),
            updateMarketsBalancesAccounts: new address[](1),
            updateRewardsBalanceAccounts: new address[](1),
            withdrawManagerRequestFeeManagers: new address[](1),
            withdrawManagerWithdrawFeeManagers: new address[](1),
            priceOracleMiddlewareManagers: new address[](1),
            whitelist: new address[](0),
            preHooksManagers: new address[](1)
        });

        customRoles.daos[0] = atomist;
        customRoles.admins[0] = atomist;
        customRoles.owners[0] = atomist;
        customRoles.atomists[0] = atomist;
        customRoles.alphas[0] = alpha;
        customRoles.guardians[0] = atomist;
        customRoles.fuseManagers[0] = atomist;
        customRoles.claimRewards[0] = alpha;
        customRoles.transferRewardsManagers[0] = alpha;
        customRoles.configInstantWithdrawalFusesManagers[0] = atomist;
        customRoles.updateMarketsBalancesAccounts[0] = atomist;
        customRoles.updateRewardsBalanceAccounts[0] = alpha;
        customRoles.withdrawManagerRequestFeeManagers[0] = atomist;
        customRoles.withdrawManagerWithdrawFeeManagers[0] = atomist;
        customRoles.priceOracleMiddlewareManagers[0] = atomist;
        customRoles.preHooksManagers[0] = atomist;

        IporFusionAccessManagerHelper.setupInitRoles(
            accessManager,
            plasmaVault,
            customRoles,
            withdrawManager,
            address(new RewardsClaimManager(address(accessManager), address(plasmaVault)))
        );
    }
}
