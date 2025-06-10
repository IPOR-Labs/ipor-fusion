// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../../test_helpers/PlasmaVaultHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {PriceOracleMiddlewareHelper} from "../../test_helpers/PriceOracleMiddlewareHelper.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData, Erc4626SupplyFuseExitData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {CurveChildLiquidityGaugeSupplyFuse} from "../../../contracts/fuses/curve_gauge/CurveChildLiquidityGaugeSupplyFuse.sol";
import {CurveChildLiquidityGaugeErc4626BalanceFuse} from "../../../contracts/fuses/curve_gauge/CurveChildLiquidityGaugeErc4626BalanceFuse.sol";
import {CurveChildLiquidityGaugeSupplyFuseEnterData} from "../../../contracts/fuses/curve_gauge/CurveChildLiquidityGaugeSupplyFuse.sol";
import {CurveChildLiquidityGaugeSupplyFuseExitData} from "../../../contracts/fuses/curve_gauge/CurveChildLiquidityGaugeSupplyFuse.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";

contract CurveIntegrationTest is Test {
    using PlasmaVaultHelper for PlasmaVault;
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    PriceOracleMiddleware private _priceOracleMiddleware;
    PlasmaVault private _plasmaVault;
    IporFusionAccessManager private _accessManager;
    address private _withdrawManager;
    Erc4626SupplyFuse private _erc4626SupplyFuse;
    Erc4626BalanceFuse private _erc4626BalanceFuse;
    CurveChildLiquidityGaugeSupplyFuse private _curveChildLiquidityGaugeSupplyFuse;
    CurveChildLiquidityGaugeErc4626BalanceFuse private _curveChildLiquidityGaugeBalanceFuse;

    address private constant _CRVUSD = 0x498Bf2B1e120FeD3ad3D42EA2165E9b73f99C1e5;
    address private constant _CRVUSD_PRICE_FEED = 0x0a32255dd4BB6177C994bAAc73E0606fDD568f66;

    // Curve ERC4626 vaults
    address private constant _CURVE_VAULT_1 = 0x60D38b12d22BF423F28082bf396ff8F28cC506B1;
    address private constant _CURVE_VAULT_2 = 0xeEaF2ccB73A01deb38Eca2947d963D64CfDe6A32;
    address private constant _CURVE_VAULT_3 = 0xC8248953429d707C6A2815653ECa89846Ffaa63b;

    address private constant _CURVE_GAUGE_3 = 0x9f051B4aED6d675E9117cd1A2E6694D59f5d0492;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 298040945);

        _priceOracleMiddleware = PriceOracleMiddlewareHelper.getArbitrumPriceOracleMiddleware();

        // Set price feed for crvUSD
        address[] memory assets = new address[](1);
        assets[0] = _CRVUSD;
        address[] memory sources = new address[](1);
        sources[0] = _CRVUSD_PRICE_FEED;

        address priceOracleOwner = _priceOracleMiddleware.owner();
        vm.startPrank(priceOracleOwner);
        _priceOracleMiddleware.setAssetsPricesSources(assets, sources);
        vm.stopPrank();

        // Deploy minimal plasma vault
        DeployMinimalPlasmaVaultParams memory params = DeployMinimalPlasmaVaultParams({
            underlyingToken: _CRVUSD,
            underlyingTokenName: "crvUSD",
            priceOracleMiddleware: _priceOracleMiddleware.addressOf(),
            atomist: TestAddresses.ATOMIST
        });

        vm.startPrank(TestAddresses.ATOMIST);
        (_plasmaVault, _withdrawManager) = PlasmaVaultHelper.deployMinimalPlasmaVault(params);

        _accessManager = _plasmaVault.accessManagerOf();
        _accessManager.setupInitRoles(_plasmaVault, _withdrawManager);

        // Grant market substrates for ERC4626 vaults
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = bytes32(uint256(uint160(_CURVE_VAULT_1)));
        substrates[1] = bytes32(uint256(uint160(_CURVE_VAULT_2)));
        substrates[2] = bytes32(uint256(uint160(_CURVE_VAULT_3)));
        vm.stopPrank();

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultGovernance(address(_plasmaVault)).grantMarketSubstrates(IporFusionMarkets.ERC4626_0001, substrates);

        // Grant market substrates for Curve LP Gauge
        bytes32[] memory gaugeSubstrates = new bytes32[](1);
        gaugeSubstrates[0] = bytes32(uint256(uint160(_CURVE_GAUGE_3)));
        PlasmaVaultGovernance(address(_plasmaVault)).grantMarketSubstrates(
            IporFusionMarkets.CURVE_GAUGE_ERC4626,
            gaugeSubstrates
        );

        vm.stopPrank();

        // Deploy and configure fuses
        _erc4626SupplyFuse = new Erc4626SupplyFuse(IporFusionMarkets.ERC4626_0001);
        _erc4626BalanceFuse = new Erc4626BalanceFuse(IporFusionMarkets.ERC4626_0001);
        _curveChildLiquidityGaugeSupplyFuse = new CurveChildLiquidityGaugeSupplyFuse(
            IporFusionMarkets.CURVE_GAUGE_ERC4626
        );
        _curveChildLiquidityGaugeBalanceFuse = new CurveChildLiquidityGaugeErc4626BalanceFuse(
            IporFusionMarkets.CURVE_GAUGE_ERC4626
        );

        // Add fuses to vault using addFuses as FUSE_MANAGER
        vm.startPrank(TestAddresses.FUSE_MANAGER);
        address[] memory fuses = new address[](2);
        fuses[0] = address(_erc4626SupplyFuse);
        fuses[1] = address(_curveChildLiquidityGaugeSupplyFuse);
        PlasmaVaultGovernance(address(_plasmaVault)).addFuses(fuses);

        // Add balance fuses
        PlasmaVaultGovernance(address(_plasmaVault)).addBalanceFuse(
            IporFusionMarkets.ERC4626_0001,
            address(_erc4626BalanceFuse)
        );
        PlasmaVaultGovernance(address(_plasmaVault)).addBalanceFuse(
            IporFusionMarkets.CURVE_GAUGE_ERC4626,
            address(_curveChildLiquidityGaugeBalanceFuse)
        );
        vm.stopPrank();

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.CURVE_GAUGE_ERC4626;

        uint256[] memory dependencies = new uint256[](1);
        dependencies[0] = IporFusionMarkets.ERC4626_0001;

        uint256[][] memory dependencyMarkets = new uint256[][](1);
        dependencyMarkets[0] = dependencies;

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultGovernance(address(_plasmaVault)).updateDependencyBalanceGraphs(marketIds, dependencyMarkets);
        vm.stopPrank();

        // Setup USER with crvUSD and perform deposit
        deal(_CRVUSD, TestAddresses.USER, 100_000e6);

        vm.startPrank(TestAddresses.USER);
        IERC20(_CRVUSD).approve(address(_plasmaVault), 100_000e6);
        _plasmaVault.deposit(100_000e6, TestAddresses.USER);
        vm.stopPrank();

        // Configure instant withdrawal fuses
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](2);

        // Configure Curve Gauge fuse instant withdraw
        bytes32[] memory curveGaugeParams = new bytes32[](2);
        curveGaugeParams[0] = bytes32(0); // default params
        curveGaugeParams[1] = PlasmaVaultConfigLib.addressToBytes32(_CURVE_GAUGE_3);
        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(_curveChildLiquidityGaugeSupplyFuse),
            params: curveGaugeParams
        });

        // Configure ERC4626 fuse instant withdraw
        bytes32[] memory erc4626Params = new bytes32[](2);
        erc4626Params[0] = bytes32(0); // default params
        erc4626Params[1] = PlasmaVaultConfigLib.addressToBytes32(_CURVE_VAULT_3);
        instantWithdrawFuses[1] = InstantWithdrawalFusesParamsStruct({
            fuse: address(_erc4626SupplyFuse),
            params: erc4626Params
        });

        vm.startPrank(TestAddresses.CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER);
        PlasmaVaultGovernance(address(_plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);
        vm.stopPrank();
    }

    function testShouldSupplyToCurveVault() public {
        // given
        uint256 supplyAmount = 70_000e6;
        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: _CURVE_VAULT_1,
            vaultAssetAmount: supplyAmount
        });

        FuseAction[] memory fuseActions = new FuseAction[](1);
        fuseActions[0] = FuseAction({
            fuse: address(_erc4626SupplyFuse),
            data: abi.encodeWithSignature("enter((address,uint256))", enterData)
        });

        // check balance before execute
        uint256 totalAssetsInMarketBefore = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertEq(totalAssetsInMarketBefore, 0, "Market balance should be 0 before execute");

        // when
        vm.startPrank(TestAddresses.ALPHA);
        _plasmaVault.execute(fuseActions);
        vm.stopPrank();

        // then
        assertEq(IERC20(_CURVE_VAULT_1).balanceOf(address(_plasmaVault)), 63998783990297);

        uint256 totalAssetsInMarketAfter = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertGt(totalAssetsInMarketAfter, 0, "Market balance should be greater than 0 after execute");
        assertApproxEqAbs(totalAssetsInMarketAfter, 70_000e6, 1_000, "Market balance should equal supplied amount");
    }

    function testShouldSupplyAndWithdrawFromCurveVault() public {
        // given
        uint256 supplyAmount = 70_000e6;

        // check initial market balance
        uint256 totalAssetsInMarketBefore = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertEq(totalAssetsInMarketBefore, 0, "Market balance should be 0 before supply");

        // when - supply to Curve vault
        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: _CURVE_VAULT_1,
            vaultAssetAmount: supplyAmount
        });

        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction({
            fuse: address(_erc4626SupplyFuse),
            data: abi.encodeWithSignature("enter((address,uint256))", enterData)
        });

        vm.startPrank(TestAddresses.ALPHA);
        _plasmaVault.execute(supplyActions);

        // then - verify supply
        uint256 curveBalance = IERC20(_CURVE_VAULT_1).balanceOf(address(_plasmaVault));
        assertEq(curveBalance, 63998783990297);

        uint256 totalAssetsInMarketAfterSupply = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertGt(totalAssetsInMarketAfterSupply, 0, "Market balance should be greater than 0 after supply");
        assertApproxEqAbs(
            totalAssetsInMarketAfterSupply,
            70_000e6,
            1_000,
            "Market balance should equal supplied amount"
        );

        // when - withdraw from Curve vault
        Erc4626SupplyFuseExitData memory exitData = Erc4626SupplyFuseExitData({
            vault: _CURVE_VAULT_1,
            vaultAssetAmount: supplyAmount
        });

        FuseAction[] memory withdrawActions = new FuseAction[](1);
        withdrawActions[0] = FuseAction({
            fuse: address(_erc4626SupplyFuse),
            data: abi.encodeWithSignature("exit((address,uint256))", exitData)
        });

        _plasmaVault.execute(withdrawActions);
        vm.stopPrank();

        // then - verify withdrawal
        assertApproxEqAbs(
            IERC20(_CURVE_VAULT_1).balanceOf(address(_plasmaVault)),
            0,
            1_000,
            "Curve vault balance should be 0"
        );

        uint256 totalAssetsInMarketAfterWithdraw = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertApproxEqAbs(totalAssetsInMarketAfterWithdraw, 0, 1_000, "Market balance should be 0 after withdrawal");
    }

    function testShouldSupplyToCurveVault2() public {
        // given
        uint256 supplyAmount = 70_000e6;
        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: _CURVE_VAULT_2,
            vaultAssetAmount: supplyAmount
        });

        FuseAction[] memory fuseActions = new FuseAction[](1);
        fuseActions[0] = FuseAction({
            fuse: address(_erc4626SupplyFuse),
            data: abi.encodeWithSignature("enter((address,uint256))", enterData)
        });

        // check balance before execute
        uint256 totalAssetsInMarketBefore = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertEq(totalAssetsInMarketBefore, 0, "Market balance should be 0 before execute");

        // when
        vm.startPrank(TestAddresses.ALPHA);
        _plasmaVault.execute(fuseActions);
        vm.stopPrank();

        // then
        uint256 curveBalance = IERC20(_CURVE_VAULT_2).balanceOf(address(_plasmaVault));
        assertGt(curveBalance, 0, "Curve vault balance should be greater than 0");

        uint256 totalAssetsInMarketAfter = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertGt(totalAssetsInMarketAfter, 0, "Market balance should be greater than 0 after execute");
        assertApproxEqAbs(totalAssetsInMarketAfter, 70_000e6, 1_000, "Market balance should equal supplied amount");
    }

    function testShouldSupplyAndWithdrawFromCurveVault2() public {
        // given
        uint256 supplyAmount = 70_000e6;

        // check initial market balance
        uint256 totalAssetsInMarketBefore = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertEq(totalAssetsInMarketBefore, 0, "Market balance should be 0 before supply");

        // when - supply to Curve vault
        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: _CURVE_VAULT_2,
            vaultAssetAmount: supplyAmount
        });

        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction({
            fuse: address(_erc4626SupplyFuse),
            data: abi.encodeWithSignature("enter((address,uint256))", enterData)
        });

        vm.startPrank(TestAddresses.ALPHA);
        _plasmaVault.execute(supplyActions);

        // then - verify supply
        uint256 curveBalance = IERC20(_CURVE_VAULT_2).balanceOf(address(_plasmaVault));
        assertGt(curveBalance, 0, "Curve vault balance should be greater than 0");

        uint256 totalAssetsInMarketAfterSupply = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertGt(totalAssetsInMarketAfterSupply, 0, "Market balance should be greater than 0 after supply");
        assertApproxEqAbs(
            totalAssetsInMarketAfterSupply,
            70_000e6,
            1_000,
            "Market balance should equal supplied amount"
        );

        // when - withdraw from Curve vault
        Erc4626SupplyFuseExitData memory exitData = Erc4626SupplyFuseExitData({
            vault: _CURVE_VAULT_2,
            vaultAssetAmount: supplyAmount
        });

        FuseAction[] memory withdrawActions = new FuseAction[](1);
        withdrawActions[0] = FuseAction({
            fuse: address(_erc4626SupplyFuse),
            data: abi.encodeWithSignature("exit((address,uint256))", exitData)
        });

        _plasmaVault.execute(withdrawActions);
        vm.stopPrank();

        // then - verify withdrawal
        assertApproxEqAbs(
            IERC20(_CURVE_VAULT_2).balanceOf(address(_plasmaVault)),
            0,
            1_000,
            "Curve vault balance should be 0"
        );

        uint256 totalAssetsInMarketAfterWithdraw = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertApproxEqAbs(totalAssetsInMarketAfterWithdraw, 0, 1_000, "Market balance should be 0 after withdrawal");
    }

    function testShouldSupplyToCurveVault3() public {
        // given
        uint256 supplyAmount = 70_000e6;
        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: _CURVE_VAULT_3,
            vaultAssetAmount: supplyAmount
        });

        FuseAction[] memory fuseActions = new FuseAction[](1);
        fuseActions[0] = FuseAction({
            fuse: address(_erc4626SupplyFuse),
            data: abi.encodeWithSignature("enter((address,uint256))", enterData)
        });

        // check balance before execute
        uint256 totalAssetsInMarketBefore = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertEq(totalAssetsInMarketBefore, 0, "Market balance should be 0 before execute");

        // when
        vm.startPrank(TestAddresses.ALPHA);
        _plasmaVault.execute(fuseActions);
        vm.stopPrank();

        // then
        uint256 curveBalance = IERC20(_CURVE_VAULT_3).balanceOf(address(_plasmaVault));
        assertGt(curveBalance, 0, "Curve vault balance should be greater than 0");

        uint256 totalAssetsInMarketAfter = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertGt(totalAssetsInMarketAfter, 0, "Market balance should be greater than 0 after execute");
        assertApproxEqAbs(totalAssetsInMarketAfter, 70_000e6, 1_000, "Market balance should equal supplied amount");
    }

    function testShouldSupplyAndWithdrawFromCurveVault3() public {
        // given
        uint256 supplyAmount = 70_000e6;

        // check initial market balance
        uint256 totalAssetsInMarketBefore = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertEq(totalAssetsInMarketBefore, 0, "Market balance should be 0 before supply");

        // when - supply to Curve vault
        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: _CURVE_VAULT_3,
            vaultAssetAmount: supplyAmount
        });

        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction({
            fuse: address(_erc4626SupplyFuse),
            data: abi.encodeWithSignature("enter((address,uint256))", enterData)
        });

        vm.startPrank(TestAddresses.ALPHA);
        _plasmaVault.execute(supplyActions);

        // then - verify supply
        uint256 curveBalance = IERC20(_CURVE_VAULT_3).balanceOf(address(_plasmaVault));
        assertGt(curveBalance, 0, "Curve vault balance should be greater than 0");

        uint256 totalAssetsInMarketAfterSupply = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertGt(totalAssetsInMarketAfterSupply, 0, "Market balance should be greater than 0 after supply");
        assertApproxEqAbs(
            totalAssetsInMarketAfterSupply,
            70_000e6,
            1_000,
            "Market balance should equal supplied amount"
        );

        // when - withdraw from Curve vault
        Erc4626SupplyFuseExitData memory exitData = Erc4626SupplyFuseExitData({
            vault: _CURVE_VAULT_3,
            vaultAssetAmount: supplyAmount
        });

        FuseAction[] memory withdrawActions = new FuseAction[](1);
        withdrawActions[0] = FuseAction({
            fuse: address(_erc4626SupplyFuse),
            data: abi.encodeWithSignature("exit((address,uint256))", exitData)
        });

        _plasmaVault.execute(withdrawActions);
        vm.stopPrank();

        // then - verify withdrawal
        assertApproxEqAbs(
            IERC20(_CURVE_VAULT_3).balanceOf(address(_plasmaVault)),
            0,
            1_000,
            "Curve vault balance should be 0"
        );

        uint256 totalAssetsInMarketAfterWithdraw = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertApproxEqAbs(totalAssetsInMarketAfterWithdraw, 0, 1_000, "Market balance should be 0 after withdrawal");
    }

    function testShouldSupplyToCurveVault3AndStakeInGauge() public {
        // given
        uint256 supplyAmount = 70_000e6;

        // check initial market balances
        uint256 totalAssetsInErc4626MarketBefore = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertEq(totalAssetsInErc4626MarketBefore, 0, "ERC4626 market balance should be 0 before execute");

        uint256 totalAssetsInGaugeMarketBefore = _plasmaVault.totalAssetsInMarket(
            IporFusionMarkets.CURVE_GAUGE_ERC4626
        );
        assertEq(totalAssetsInGaugeMarketBefore, 0, "Gauge market balance should be 0 before execute");

        // Create supply to vault action
        Erc4626SupplyFuseEnterData memory erc4626EnterData = Erc4626SupplyFuseEnterData({
            vault: _CURVE_VAULT_3,
            vaultAssetAmount: supplyAmount
        });

        // Create stake in gauge action
        CurveChildLiquidityGaugeSupplyFuseEnterData
            memory gaugeEnterData = CurveChildLiquidityGaugeSupplyFuseEnterData({
                childLiquidityGauge: _CURVE_GAUGE_3,
                lpTokenAmount: type(uint256).max // Will use all available LP tokens
            });

        // Combine both actions
        FuseAction[] memory fuseActions = new FuseAction[](2);
        fuseActions[0] = FuseAction({
            fuse: address(_erc4626SupplyFuse),
            data: abi.encodeWithSignature("enter((address,uint256))", erc4626EnterData)
        });
        fuseActions[1] = FuseAction({
            fuse: address(_curveChildLiquidityGaugeSupplyFuse),
            data: abi.encodeWithSignature("enter((address,uint256))", gaugeEnterData)
        });

        // when
        vm.startPrank(TestAddresses.ALPHA);
        _plasmaVault.execute(fuseActions);
        vm.stopPrank();

        // then
        // Verify ERC4626 vault state
        uint256 vaultBalance = IERC20(_CURVE_VAULT_3).balanceOf(address(_plasmaVault));
        assertEq(vaultBalance, 0, "Vault should have 0 LP tokens as all were staked");

        uint256 totalAssetsInErc4626MarketAfter = _plasmaVault.totalAssetsInMarket(
            IporFusionMarkets.CURVE_GAUGE_ERC4626
        );
        assertGt(totalAssetsInErc4626MarketAfter, 0, "ERC4626 market balance should be 0 after execute");
        assertApproxEqAbs(
            totalAssetsInErc4626MarketAfter,
            70_000e6,
            1_000,
            "ERC4626 market balance should equal supplied amount"
        );

        // Verify ERC4626 market state
        uint256 totalAssetsInErc4626 = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertEq(totalAssetsInErc4626, 0, "ERC4626 market balance should be 0 after execute");

        // Verify Gauge state
        uint256 gaugeBalance = IERC20(_CURVE_GAUGE_3).balanceOf(address(_plasmaVault));
        assertGt(gaugeBalance, 0, "Gauge should have staked LP tokens");

        uint256 totalAssetsInGaugeMarketAfter = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.CURVE_GAUGE_ERC4626);
        assertGt(totalAssetsInGaugeMarketAfter, 0, "Gauge market balance should be greater than 0 after execute");
        assertApproxEqAbs(
            totalAssetsInGaugeMarketAfter,
            70_000e6,
            1_000,
            "Gauge market balance should equal supplied amount"
        );
    }

    function testShouldSupplyToCurveVault3StakeInGaugeAndWithdraw() public {
        // given
        uint256 supplyAmount = 70_000e6;

        // check initial market balances
        uint256 totalAssetsInErc4626MarketBefore = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertEq(totalAssetsInErc4626MarketBefore, 0, "ERC4626 market balance should be 0 before execute");

        uint256 totalAssetsInGaugeMarketBefore = _plasmaVault.totalAssetsInMarket(
            IporFusionMarkets.CURVE_GAUGE_ERC4626
        );
        assertEq(totalAssetsInGaugeMarketBefore, 0, "Gauge market balance should be 0 before execute");

        // STEP 1: Supply to vault and stake in gauge
        // Create supply to vault action
        Erc4626SupplyFuseEnterData memory erc4626EnterData = Erc4626SupplyFuseEnterData({
            vault: _CURVE_VAULT_3,
            vaultAssetAmount: supplyAmount
        });

        // Create stake in gauge action
        CurveChildLiquidityGaugeSupplyFuseEnterData
            memory gaugeEnterData = CurveChildLiquidityGaugeSupplyFuseEnterData({
                childLiquidityGauge: _CURVE_GAUGE_3,
                lpTokenAmount: type(uint256).max // Will use all available LP tokens
            });

        // Combine both actions
        FuseAction[] memory fuseActions = new FuseAction[](2);
        fuseActions[0] = FuseAction({
            fuse: address(_erc4626SupplyFuse),
            data: abi.encodeWithSignature("enter((address,uint256))", erc4626EnterData)
        });
        fuseActions[1] = FuseAction({
            fuse: address(_curveChildLiquidityGaugeSupplyFuse),
            data: abi.encodeWithSignature("enter((address,uint256))", gaugeEnterData)
        });

        vm.startPrank(TestAddresses.ALPHA);
        _plasmaVault.execute(fuseActions);

        // Verify state after supply and stake
        uint256 vaultBalanceAfterStake = IERC20(_CURVE_VAULT_3).balanceOf(address(_plasmaVault));
        assertEq(vaultBalanceAfterStake, 0, "Vault should have 0 LP tokens as all were staked");

        uint256 gaugeBalanceAfterStake = IERC20(_CURVE_GAUGE_3).balanceOf(address(_plasmaVault));
        assertGt(gaugeBalanceAfterStake, 0, "Gauge should have staked LP tokens");

        uint256 totalAssetsInGaugeAfterStake = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.CURVE_GAUGE_ERC4626);
        assertGt(totalAssetsInGaugeAfterStake, 0, "Gauge market balance should be greater than 0 after stake");
        assertApproxEqAbs(
            totalAssetsInGaugeAfterStake,
            70_000e6,
            1_000,
            "Gauge market balance should equal supplied amount"
        );

        // STEP 2: Unstake from gauge and withdraw from vault
        // Create unstake from gauge action
        CurveChildLiquidityGaugeSupplyFuseExitData memory gaugeExitData = CurveChildLiquidityGaugeSupplyFuseExitData({
            childLiquidityGauge: _CURVE_GAUGE_3,
            lpTokenAmount: type(uint256).max // Will unstake all LP tokens
        });

        // Create withdraw from vault action
        Erc4626SupplyFuseExitData memory erc4626ExitData = Erc4626SupplyFuseExitData({
            vault: _CURVE_VAULT_3,
            vaultAssetAmount: supplyAmount
        });

        // Combine unstake and withdraw actions
        FuseAction[] memory unstakeAndWithdrawActions = new FuseAction[](2);
        unstakeAndWithdrawActions[0] = FuseAction({
            fuse: address(_curveChildLiquidityGaugeSupplyFuse),
            data: abi.encodeWithSignature("exit((address,uint256))", gaugeExitData)
        });
        unstakeAndWithdrawActions[1] = FuseAction({
            fuse: address(_erc4626SupplyFuse),
            data: abi.encodeWithSignature("exit((address,uint256))", erc4626ExitData)
        });

        _plasmaVault.execute(unstakeAndWithdrawActions);
        vm.stopPrank();

        // Verify final state
        uint256 vaultBalanceAfterWithdraw = IERC20(_CURVE_VAULT_3).balanceOf(address(_plasmaVault));
        assertApproxEqAbs(vaultBalanceAfterWithdraw, 0, 1000, "Vault should have 0 LP tokens after full withdrawal");

        uint256 gaugeBalanceAfterWithdraw = IERC20(_CURVE_GAUGE_3).balanceOf(address(_plasmaVault));
        assertEq(gaugeBalanceAfterWithdraw, 0, "Gauge should have 0 staked LP tokens after unstake");

        uint256 totalAssetsInErc4626MarketAfter = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertEq(totalAssetsInErc4626MarketAfter, 0, "ERC4626 market balance should be 0 after full withdrawal");

        uint256 totalAssetsInGaugeMarketAfter = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.CURVE_GAUGE_ERC4626);
        assertEq(totalAssetsInGaugeMarketAfter, 0, "Gauge market balance should be 0 after full withdrawal");

        // Check total assets in plasma vault after full withdrawal
        uint256 totalAssets = _plasmaVault.totalAssets();
        assertApproxEqAbs(
            totalAssets,
            100_000e6, // Initial deposit amount
            1_000,
            "Total assets should approximately equal initial deposit after full withdrawal"
        );
    }

    function testShouldSupplyToCurveVault3StakeInGaugeAndPartialWithdraw() public {
        // given
        uint256 supplyAmount = 70_000e6;
        uint256 withdrawAmount = 50_000e6;

        // check initial market balances
        uint256 totalAssetsInErc4626MarketBefore = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertEq(totalAssetsInErc4626MarketBefore, 0, "ERC4626 market balance should be 0 before execute");

        uint256 totalAssetsInGaugeMarketBefore = _plasmaVault.totalAssetsInMarket(
            IporFusionMarkets.CURVE_GAUGE_ERC4626
        );
        assertEq(totalAssetsInGaugeMarketBefore, 0, "Gauge market balance should be 0 before execute");

        // STEP 1: Supply to vault and stake in gauge
        // Create supply to vault action
        Erc4626SupplyFuseEnterData memory erc4626EnterData = Erc4626SupplyFuseEnterData({
            vault: _CURVE_VAULT_3,
            vaultAssetAmount: supplyAmount
        });

        // Create stake in gauge action
        CurveChildLiquidityGaugeSupplyFuseEnterData
            memory gaugeEnterData = CurveChildLiquidityGaugeSupplyFuseEnterData({
                childLiquidityGauge: _CURVE_GAUGE_3,
                lpTokenAmount: type(uint256).max // Will use all available LP tokens
            });

        // Combine supply and stake actions
        FuseAction[] memory supplyAndStakeActions = new FuseAction[](2);
        supplyAndStakeActions[0] = FuseAction({
            fuse: address(_erc4626SupplyFuse),
            data: abi.encodeWithSignature("enter((address,uint256))", erc4626EnterData)
        });
        supplyAndStakeActions[1] = FuseAction({
            fuse: address(_curveChildLiquidityGaugeSupplyFuse),
            data: abi.encodeWithSignature("enter((address,uint256))", gaugeEnterData)
        });

        vm.startPrank(TestAddresses.ALPHA);
        _plasmaVault.execute(supplyAndStakeActions);
        vm.stopPrank();

        // Verify state after supply and stake
        uint256 vaultBalanceAfterStake = IERC20(_CURVE_VAULT_3).balanceOf(address(_plasmaVault));
        assertEq(vaultBalanceAfterStake, 0, "Vault should have 0 LP tokens as all were staked");

        uint256 gaugeBalanceAfterStake = IERC20(_CURVE_GAUGE_3).balanceOf(address(_plasmaVault));
        assertGt(gaugeBalanceAfterStake, 0, "Gauge should have staked LP tokens");

        uint256 totalAssetsInGaugeAfterStake = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.CURVE_GAUGE_ERC4626);
        assertGt(totalAssetsInGaugeAfterStake, 0, "Gauge market balance should be greater than 0 after stake");
        assertApproxEqAbs(
            totalAssetsInGaugeAfterStake,
            70_000e6,
            1_000,
            "Gauge market balance should equal supplied amount"
        );

        // STEP 2: User withdraws from PlasmaVault
        uint256 userBalanceBefore = IERC20(_CRVUSD).balanceOf(TestAddresses.USER);
        vm.prank(TestAddresses.USER);
        _plasmaVault.withdraw(withdrawAmount, TestAddresses.USER, TestAddresses.USER);
        uint256 userBalanceAfter = IERC20(_CRVUSD).balanceOf(TestAddresses.USER);

        // Verify user received the withdrawn amount
        assertEq(
            userBalanceAfter - userBalanceBefore,
            withdrawAmount,
            "User should have received the withdrawn amount"
        );

        // Verify final state
        uint256 totalAssetsInGaugeMarketAfter = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.CURVE_GAUGE_ERC4626);
        assertGt(totalAssetsInGaugeMarketAfter, 0, "Gauge market balance should be greater than 0");
        assertApproxEqAbs(
            totalAssetsInGaugeMarketAfter,
            49999999988,
            1_000,
            "Gauge market balance should equal remaining amount"
        );

        // Check total assets in plasma vault after withdrawal
        uint256 totalAssets = _plasmaVault.totalAssets();
        assertApproxEqAbs(
            totalAssets,
            50_000e6, // Initial deposit - withdrawn amount
            1_000,
            "Total assets should equal initial deposit minus withdrawn amount"
        );
    }
}
