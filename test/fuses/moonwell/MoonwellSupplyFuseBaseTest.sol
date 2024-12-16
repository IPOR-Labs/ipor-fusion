// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../../test_helpers/PlasmaVaultHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PriceOracleMiddlewareHelper} from "../../test_helpers/PriceOracleMiddlewareHelper.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {MoonwellHelper, MoonWellAddresses} from "../../test_helpers/MoonwellHelper.sol";
import {MoonwellSupplyFuseEnterData, MoonwellSupplyFuseExitData} from "../../../contracts/fuses/moonwell/MoonwellSupplyFuse.sol";
import {MoonwellHelperLib} from "../../../contracts/fuses/moonwell/MoonwellHelperLib.sol";

contract MoonwellSupplyFuseBaseTest is Test {
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using PlasmaVaultHelper for PlasmaVault;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    address private constant _DAI = TestAddresses.BASE_DAI;
    address private constant _UNDERLYING_TOKEN = TestAddresses.BASE_USDC;
    string private constant _UNDERLYING_TOKEN_NAME = "USDC";
    address private constant _USER = TestAddresses.USER;
    uint256 private constant ERROR_DELTA = 100;

    PlasmaVault private _plasmaVault;
    PriceOracleMiddleware private _priceOracleMiddleware;
    IporFusionAccessManager private _accessManager;

    MoonWellAddresses private _moonwellAddresses;

    function setUp() public {
        // Fork Base network
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 22136992);

        // Deploy price oracle middleware
        vm.startPrank(TestAddresses.ATOMIST);
        _priceOracleMiddleware = PriceOracleMiddlewareHelper.deployPriceOracleMiddleware(
            TestAddresses.ATOMIST,
            address(0)
        );
        vm.stopPrank();
        // Deploy minimal plasma vault
        DeployMinimalPlasmaVaultParams memory params = DeployMinimalPlasmaVaultParams({
            underlyingToken: _UNDERLYING_TOKEN,
            underlyingTokenName: _UNDERLYING_TOKEN_NAME,
            priceOracleMiddleware: _priceOracleMiddleware.addressOf(),
            atomist: TestAddresses.ATOMIST
        });

        vm.startPrank(TestAddresses.ATOMIST);
        (_plasmaVault, ) = PlasmaVaultHelper.deployMinimalPlasmaVault(params);

        _accessManager = _plasmaVault.accessManagerOf();
        _accessManager.setupInitRoles(_plasmaVault, address(0), TestAddresses.BASE_CHAIN_ID);

        address[] memory mTokens = new address[](1);
        mTokens[0] = TestAddresses.BASE_M_USDC;

        _moonwellAddresses = MoonwellHelper.addSupplyToMarket(_plasmaVault, mTokens, vm);

        vm.startPrank(TestAddresses.ATOMIST);
        _priceOracleMiddleware.addSource(TestAddresses.BASE_USDC, TestAddresses.BASE_CHAINLINK_USDC_PRICE);
        vm.stopPrank();

        deal(_UNDERLYING_TOKEN, _USER, 1000e6);

        vm.startPrank(_USER);
        IERC20(_UNDERLYING_TOKEN).approve(address(_plasmaVault), 1000e6);
        _plasmaVault.deposit(1000e6, _USER);
        vm.stopPrank();
    }

    function testSupply500USDC() public {
        // Setup
        uint256 supplyAmount = 500e6; // 500 USDC

        // Prepare supply action
        MoonwellSupplyFuseEnterData memory enterData = MoonwellSupplyFuseEnterData({
            asset: _UNDERLYING_TOKEN,
            amount: supplyAmount
        });

        // Create FuseAction for supply
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _moonwellAddresses.suppluFuse,
            data: abi.encodeWithSignature("enter((address,uint256))", enterData)
        });

        uint256 totalAssetBefore = _plasmaVault.totalAssets();
        uint256 balanceInMarketBefore = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.MOONWELL);

        // Execute supply through PlasmaVault
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(actions);

        // Verify supply
        uint256 mUsdcBalance = IERC20(TestAddresses.BASE_M_USDC).balanceOf(address(_plasmaVault));
        uint256 totalAssetAfter = _plasmaVault.totalAssets();
        uint256 balanceInMarketAfter = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.MOONWELL);

        assertApproxEqAbs(balanceInMarketBefore, 0, ERROR_DELTA, "Balance in market should be 0");
        assertApproxEqAbs(balanceInMarketAfter, supplyAmount, ERROR_DELTA, "Balance in market should be 500 USDC");
        assertApproxEqAbs(totalAssetAfter, totalAssetBefore, ERROR_DELTA, "Total assets should be 1000 USDC");
        assertApproxEqAbs(mUsdcBalance, 2391512054653, ERROR_DELTA, "M_USDC balance should be 2391512054653 mUSDC");
    }

    function testSupplyTwoTimes200And400USDC() public {
        // First supply - 200 USDC
        uint256 firstSupplyAmount = 200e6;

        MoonwellSupplyFuseEnterData memory firstEnterData = MoonwellSupplyFuseEnterData({
            asset: TestAddresses.BASE_USDC,
            amount: firstSupplyAmount
        });

        FuseAction[] memory firstActions = new FuseAction[](1);
        firstActions[0] = FuseAction({
            fuse: _moonwellAddresses.suppluFuse,
            data: abi.encodeWithSignature("enter((address,uint256))", firstEnterData)
        });

        uint256 totalAssetBefore = _plasmaVault.totalAssets();
        uint256 balanceInMarketBefore = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.MOONWELL);

        // Execute first supply
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(firstActions);

        // Verify first supply
        uint256 mUsdcBalanceAfterFirst = IERC20(TestAddresses.BASE_M_USDC).balanceOf(address(_plasmaVault));
        uint256 balanceInMarketAfterFirst = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.MOONWELL);

        assertApproxEqAbs(balanceInMarketBefore, 0, ERROR_DELTA, "Initial balance in market should be 0");

        assertApproxEqAbs(
            balanceInMarketAfterFirst,
            firstSupplyAmount,
            ERROR_DELTA,
            "Balance after first supply should be 200 USDC"
        );

        // Second supply - 400 USDC
        uint256 secondSupplyAmount = 400e6;

        MoonwellSupplyFuseEnterData memory secondEnterData = MoonwellSupplyFuseEnterData({
            asset: TestAddresses.BASE_USDC,
            amount: secondSupplyAmount
        });

        FuseAction[] memory secondActions = new FuseAction[](1);
        secondActions[0] = FuseAction({
            fuse: _moonwellAddresses.suppluFuse,
            data: abi.encodeWithSignature("enter((address,uint256))", secondEnterData)
        });

        // Execute second supply
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(secondActions);

        // Final verifications
        uint256 mUsdcBalanceAfterSecond = IERC20(TestAddresses.BASE_M_USDC).balanceOf(address(_plasmaVault));
        uint256 totalAssetAfter = _plasmaVault.totalAssets();
        uint256 balanceInMarketAfter = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.MOONWELL);
        uint256 totalSupplied = firstSupplyAmount + secondSupplyAmount;

        assertApproxEqAbs(
            balanceInMarketAfter,
            totalSupplied,
            ERROR_DELTA,
            "Final balance in market should be 600 USDC"
        );

        assertApproxEqAbs(totalAssetAfter, totalAssetBefore, ERROR_DELTA, "Total assets should remain 1000 USDC");

        assertApproxEqAbs(
            mUsdcBalanceAfterFirst,
            956604821861,
            ERROR_DELTA,
            "M_USDC balance after first supply should be ~956604821861"
        );

        assertApproxEqAbs(
            mUsdcBalanceAfterSecond,
            2869814465584,
            ERROR_DELTA,
            "M_USDC balance after second supply should be ~2869814465584"
        );
    }

    function testSupply600USDCAndWithdraw300USDC() public {
        // Setup for supply
        uint256 supplyAmount = 600e6; // 600 USDC

        // Prepare supply action
        MoonwellSupplyFuseEnterData memory enterData = MoonwellSupplyFuseEnterData({
            asset: TestAddresses.BASE_USDC,
            amount: supplyAmount
        });

        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction({
            fuse: _moonwellAddresses.suppluFuse,
            data: abi.encodeWithSignature("enter((address,uint256))", enterData)
        });

        uint256 totalAssetBefore = _plasmaVault.totalAssets();
        uint256 balanceInMarketBefore = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.MOONWELL);

        // Execute supply
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(supplyActions);

        // Verify supply
        uint256 mUsdcBalanceAfterSupply = IERC20(TestAddresses.BASE_M_USDC).balanceOf(address(_plasmaVault));
        uint256 balanceInMarketAfterSupply = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.MOONWELL);

        assertApproxEqAbs(balanceInMarketBefore, 0, ERROR_DELTA, "Initial balance in market should be 0");
        assertApproxEqAbs(
            balanceInMarketAfterSupply,
            supplyAmount,
            ERROR_DELTA,
            "Balance after supply should be 600 USDC"
        );

        // Setup for withdrawal
        uint256 withdrawAmount = 300e6; // 300 USDC

        // Prepare withdrawal action
        MoonwellSupplyFuseExitData memory exitData = MoonwellSupplyFuseExitData({
            asset: TestAddresses.BASE_USDC,
            amount: withdrawAmount
        });

        FuseAction[] memory withdrawActions = new FuseAction[](1);
        withdrawActions[0] = FuseAction({
            fuse: _moonwellAddresses.suppluFuse,
            data: abi.encodeWithSignature("exit((address,uint256))", exitData)
        });

        // Execute withdrawal
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(withdrawActions);

        // Final verifications
        uint256 mUsdcBalanceAfterWithdraw = IERC20(TestAddresses.BASE_M_USDC).balanceOf(address(_plasmaVault));
        uint256 totalAssetAfter = _plasmaVault.totalAssets();
        uint256 balanceInMarketAfter = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.MOONWELL);
        uint256 remainingAmount = supplyAmount - withdrawAmount;

        assertApproxEqAbs(
            mUsdcBalanceAfterSupply,
            2869814465584,
            ERROR_DELTA,
            "M_USDC balance after supply should be ~2869814465584"
        );

        assertApproxEqAbs(
            mUsdcBalanceAfterWithdraw,
            1434907232792,
            ERROR_DELTA,
            "M_USDC balance after withdraw should be ~1434907232792"
        );

        assertApproxEqAbs(
            balanceInMarketAfter,
            remainingAmount,
            ERROR_DELTA,
            "Final balance in market should be 300 USDC"
        );

        assertApproxEqAbs(totalAssetAfter, totalAssetBefore, ERROR_DELTA, "Total assets should remain 1000 USDC");
    }

    function testSupply600USDCAndWithdrawTwice200And400USDC() public {
        // Setup for supply
        uint256 supplyAmount = 600e6; // 600 USDC
        uint256 totalAssetBefore = _plasmaVault.totalAssets();
        uint256 balanceInMarketBefore = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.MOONWELL);

        // Supply 600 USDC
        _executeSupply(supplyAmount);

        // Verify supply
        uint256 balanceInMarketAfterSupply = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.MOONWELL);
        uint256 mUsdcBalanceAfterSupply = IERC20(TestAddresses.BASE_M_USDC).balanceOf(address(_plasmaVault));

        assertApproxEqAbs(balanceInMarketBefore, 0, ERROR_DELTA, "Initial balance should be 0");
        assertApproxEqAbs(balanceInMarketAfterSupply, supplyAmount, ERROR_DELTA, "Should be 600 USDC after supply");

        // First withdrawal - 200 USDC
        uint256 firstWithdrawAmount = 200e6;
        _executeWithdraw(firstWithdrawAmount);

        uint256 balanceAfterFirst = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.MOONWELL);
        uint256 mUsdcBalanceAfterFirst = IERC20(TestAddresses.BASE_M_USDC).balanceOf(address(_plasmaVault));

        // Second withdrawal - 400 USDC
        uint256 secondWithdrawAmount = 400e6;
        _executeWithdraw(secondWithdrawAmount);

        // Final checks
        uint256 finalBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.MOONWELL);
        uint256 finalMUsdcBalance = IERC20(TestAddresses.BASE_M_USDC).balanceOf(address(_plasmaVault));
        uint256 totalAssetAfter = _plasmaVault.totalAssets();

        // Assertions
        assertApproxEqAbs(mUsdcBalanceAfterSupply, 2869814465584, ERROR_DELTA, "Wrong M_USDC balance after supply");
        assertApproxEqAbs(balanceAfterFirst, 400e6, ERROR_DELTA, "Should be 400 USDC after first withdrawal");
        assertApproxEqAbs(
            mUsdcBalanceAfterFirst,
            1913209643722,
            ERROR_DELTA,
            "Wrong M_USDC balance after first withdrawal"
        );
        assertApproxEqAbs(finalMUsdcBalance, 4783, ERROR_DELTA, "Should be 4783 after second withdrawal");
        assertApproxEqAbs(finalBalance, 0, ERROR_DELTA, "Should be 0 after all withdrawals");
        assertApproxEqAbs(totalAssetAfter, totalAssetBefore, ERROR_DELTA, "Total assets should not change");
    }

    // Helper functions to reduce stack usage
    function _executeSupply(uint256 amount) internal {
        MoonwellSupplyFuseEnterData memory enterData = MoonwellSupplyFuseEnterData({
            asset: TestAddresses.BASE_USDC,
            amount: amount
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _moonwellAddresses.suppluFuse,
            data: abi.encodeWithSignature("enter((address,uint256))", enterData)
        });

        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(actions);
    }

    function _executeWithdraw(uint256 amount) internal {
        MoonwellSupplyFuseExitData memory exitData = MoonwellSupplyFuseExitData({
            asset: TestAddresses.BASE_USDC,
            amount: amount
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _moonwellAddresses.suppluFuse,
            data: abi.encodeWithSignature("exit((address,uint256))", exitData)
        });

        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(actions);
    }

    function testSupplyUnsupportedAssetDAI() public {
        // Setup
        uint256 supplyAmount = 500e6;

        // Prepare supply action with DAI (unsupported asset)
        MoonwellSupplyFuseEnterData memory enterData = MoonwellSupplyFuseEnterData({asset: _DAI, amount: supplyAmount});

        // Create FuseAction for supply
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _moonwellAddresses.suppluFuse,
            data: abi.encodeWithSignature("enter((address,uint256))", enterData)
        });

        // Execute supply through PlasmaVault - should revert
        vm.prank(TestAddresses.ALPHA);
        vm.expectRevert(abi.encodeWithSelector(MoonwellHelperLib.MoonwellSupplyFuseUnsupportedAsset.selector, _DAI));
        _plasmaVault.execute(actions);
    }
}
