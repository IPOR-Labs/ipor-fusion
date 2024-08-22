// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FuseAction, PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {ERC4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {IporFusionMarketsArbitrum} from "../../../contracts/libraries/IporFusionMarketsArbitrum.sol";
import {GearboxV3FarmdSupplyFuseExitData, GearboxV3FarmdSupplyFuseEnterData, GearboxV3FarmSupplyFuse} from "../../../contracts/fuses/gearbox_v3/GearboxV3FarmSupplyFuse.sol";
import {GearboxV3FarmBalanceFuse} from "../../../contracts/fuses/gearbox_v3/GearboxV3FarmBalanceFuse.sol";
import {AaveV3SupplyFuse} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {CompoundV3BalanceFuse} from "../../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {IPool} from "../../../contracts/fuses/aave_v3/ext/IPool.sol";

import {TestAccountSetup} from "../supplyFuseTemplate/TestAccountSetup.sol";
import {TestPriceOracleSetup} from "../supplyFuseTemplate/TestPriceOracleSetup.sol";
import {TestVaultSetup} from "../supplyFuseTemplate/TestVaultSetup.sol";

import {Vm} from "forge-std/Test.sol";

contract GearboxV3FarmdUSDCArbitrum is TestAccountSetup, TestPriceOracleSetup, TestVaultSetup {
    using SafeERC20 for ERC20;

    event MarketBalancesUpdated(uint256[] marketIds, int256 deltaInUnderlying);

    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant CHAINLINK_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address public constant D_USDC = 0x890A69EF363C9c7BdD5E36eb95Ceb569F63ACbF6;
    address public constant FARM_D_USDC = 0xD0181a36B0566a8645B7eECFf2148adE7Ecf2BE9;
    address public constant PRICE_ORACLE_MIDDLEWARE_USD = 0x85a3Ee1688eE8D320eDF4024fB67734Fa8492cF4;

    address public constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public constant AAVE_POOL_DATA_PROVIDER = 0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654;
    address public constant AAVE_PRICE_ORACLE = 0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7;

    address public constant COMET = 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf;

    GearboxV3FarmSupplyFuse public gearboxV3FarmSupplyFuse;
    Erc4626SupplyFuse public gearboxV3DTokenFuse;
    AaveV3BalanceFuse public aaveFuseBalance;

    uint256 private constant ERROR_DELTA = 100;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 226213814);
        init();
    }

    function init() public {
        initStorage();
        initAccount();
        initPriceOracle();
        setupFuses();
        initPlasmaVault();
        initApprove();
    }

    function setupAsset() public override {
        asset = USDC;
    }

    function dealAssets(address account_, uint256 amount_) public override {
        vm.prank(0x47c031236e19d024b42f8AE6780E44A573170703);
        ERC20(asset).transfer(account_, amount_);
    }

    function setupPriceOracle() public override returns (address[] memory assets, address[] memory sources) {
        assets = new address[](1);
        sources = new address[](1);
        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC;
    }

    function setupMarketConfigs() public override returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](4);
        bytes32[] memory assetsDUsdc = new bytes32[](1);
        assetsDUsdc[0] = PlasmaVaultConfigLib.addressToBytes32(D_USDC);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarketsArbitrum.GEARBOX_POOL_V3, assetsDUsdc);

        bytes32[] memory assetsFarmDUsdc = new bytes32[](1);
        assetsFarmDUsdc[0] = PlasmaVaultConfigLib.addressToBytes32(FARM_D_USDC);
        marketConfigs[1] = MarketSubstratesConfig(IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3, assetsFarmDUsdc);

        bytes32[] memory assetsAave = new bytes32[](1);
        assetsAave[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        marketConfigs[2] = MarketSubstratesConfig(IporFusionMarketsArbitrum.AAVE_V3, assetsAave);

        bytes32[] memory assetsCompound = new bytes32[](1);
        assetsCompound[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        marketConfigs[3] = MarketSubstratesConfig(IporFusionMarketsArbitrum.COMPOUND_V3, assetsCompound);
    }

    function setupFuses() public override {
        gearboxV3DTokenFuse = new Erc4626SupplyFuse(IporFusionMarketsArbitrum.GEARBOX_POOL_V3);
        gearboxV3FarmSupplyFuse = new GearboxV3FarmSupplyFuse(IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3);
        AaveV3SupplyFuse fuseAave = new AaveV3SupplyFuse(
            IporFusionMarketsArbitrum.AAVE_V3,
            AAVE_POOL,
            AAVE_POOL_DATA_PROVIDER
        );

        fuses = new address[](3);
        fuses[0] = address(gearboxV3DTokenFuse);
        fuses[1] = address(gearboxV3FarmSupplyFuse);
        fuses[2] = address(fuseAave);
    }

    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        ERC4626BalanceFuse gearboxV3Balances = new ERC4626BalanceFuse(IporFusionMarketsArbitrum.GEARBOX_POOL_V3);

        GearboxV3FarmBalanceFuse gearboxV3FarmdBalance = new GearboxV3FarmBalanceFuse(
            IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3
        );

        aaveFuseBalance = new AaveV3BalanceFuse(
            IporFusionMarketsArbitrum.AAVE_V3,
            AAVE_PRICE_ORACLE,
            AAVE_POOL_DATA_PROVIDER
        );

        balanceFuses = new MarketBalanceFuseConfig[](4);
        balanceFuses[0] = MarketBalanceFuseConfig(
            IporFusionMarketsArbitrum.GEARBOX_POOL_V3,
            address(gearboxV3Balances)
        );

        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3,
            address(gearboxV3FarmdBalance)
        );

        balanceFuses[2] = MarketBalanceFuseConfig(IporFusionMarketsArbitrum.AAVE_V3, address(aaveFuseBalance));

        balanceFuses[3] = MarketBalanceFuseConfig(
            IporFusionMarketsArbitrum.COMPOUND_V3,
            address(new CompoundV3BalanceFuse(IporFusionMarketsArbitrum.COMPOUND_V3, COMET))
        );
    }

    function getEnterFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (bytes[] memory data) {
        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: D_USDC,
            vaultAssetAmount: amount_
        });
        GearboxV3FarmdSupplyFuseEnterData memory enterDataFarm = GearboxV3FarmdSupplyFuseEnterData({
            farmdToken: FARM_D_USDC,
            dTokenAmount: amount_
        });
        data = new bytes[](2);
        data[0] = abi.encode(enterData);
        data[1] = abi.encode(enterDataFarm);
    }

    function getExitFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (address[] memory fusesSetup, bytes[] memory data) {
        GearboxV3FarmdSupplyFuseExitData memory exitDataFarm = GearboxV3FarmdSupplyFuseExitData({
            farmdToken: FARM_D_USDC,
            dTokenAmount: amount_
        });
        data = new bytes[](1);
        data[0] = abi.encode(exitDataFarm);

        fusesSetup = new address[](2);
        fusesSetup[0] = address(gearboxV3FarmSupplyFuse);
    }

    function testShouldCalculateWrongBalanceWhenDependencyBalanceGraphNotSetup() external {
        // given

        address userOne = accounts[1];
        uint256 depositAmount = random.randomNumber(
            1 * 10 ** (ERC20(asset).decimals()),
            10_000 * 10 ** (ERC20(asset).decimals())
        );
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: D_USDC,
            vaultAssetAmount: depositAmount
        });
        GearboxV3FarmdSupplyFuseEnterData memory enterDataFarm = GearboxV3FarmdSupplyFuseEnterData({
            farmdToken: FARM_D_USDC,
            dTokenAmount: depositAmount
        });
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encode(enterData);
        data[1] = abi.encode(enterDataFarm);
        uint256 len = data.length;
        FuseAction[] memory enterCalls = new FuseAction[](len);
        for (uint256 i = 0; i < len; ++i) {
            enterCalls[i] = FuseAction(fuses[i], abi.encodeWithSignature("enter(bytes)", data[i]));
        }

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(enterCalls);

        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();

        uint256 assetsInDUsdcBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.GEARBOX_POOL_V3
        );
        uint256 assetsInFarmDUsdcBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3
        );

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;

        // when
        vm.recordLogs();
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(generateExitCallsData(assetsInFarmDUsdcBefore, new bytes32[](0)));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then

        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInDUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.GEARBOX_POOL_V3
        );
        uint256 assetsInFarmDUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3
        );

        assertEq(_extractMarketIdsFromEvent(entries), marketIds, "marketIds should be equal to marketIds[4]");
        assertEq(assetsInDUsdcBefore, 0, "assetsInDUsdcBefore should be 0");
        assertGt(assetsInFarmDUsdcBefore, 0, "assetsInFarmDUsdcBefore should be greater than 0");
        assertGt(totalAssetsBefore, 0, "totalAssetsBefore should be greater than 0");
        assertEq(assetsInDUsdcAfter, 0, "assetsInDUsdcAfter should be 0");
        assertEq(assetsInFarmDUsdcAfter, 0, "assetsInFarmDUsdcAfter should be 0");
        assertEq(totalAssetsAfter, 0, "totalAssetsAfter should be 0");
    }

    function testShouldCalculateBalanceWhenDependencyBalanceGraphIsSetup() external {
        // given

        address userOne = accounts[1];
        uint256 depositAmount = random.randomNumber(
            1 * 10 ** (ERC20(asset).decimals()),
            10_000 * 10 ** (ERC20(asset).decimals())
        );
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: D_USDC,
            vaultAssetAmount: depositAmount
        });
        GearboxV3FarmdSupplyFuseEnterData memory enterDataFarm = GearboxV3FarmdSupplyFuseEnterData({
            farmdToken: FARM_D_USDC,
            dTokenAmount: depositAmount
        });
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encode(enterData);
        data[1] = abi.encode(enterDataFarm);
        uint256 len = data.length;
        FuseAction[] memory enterCalls = new FuseAction[](len);
        for (uint256 i = 0; i < len; ++i) {
            enterCalls[i] = FuseAction(fuses[i], abi.encodeWithSignature("enter(bytes)", data[i]));
        }

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarketsArbitrum.GEARBOX_POOL_V3;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        vm.prank(accounts[0]);
        PlasmaVaultGovernance(plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(enterCalls);

        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();

        uint256 assetsInDUsdcBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.GEARBOX_POOL_V3
        );
        uint256 assetsInFarmDUsdcBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3
        );

        uint256[] memory expectedMarketIds = new uint256[](2);
        expectedMarketIds[0] = IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;
        expectedMarketIds[1] = IporFusionMarketsArbitrum.GEARBOX_POOL_V3;

        // when
        vm.prank(alpha);
        vm.recordLogs();
        PlasmaVault(plasmaVault).execute(generateExitCallsData(assetsInFarmDUsdcBefore, new bytes32[](0)));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then

        uint256[] memory marketIdsFromEvent = _extractMarketIdsFromEvent(entries);
        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInDUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.GEARBOX_POOL_V3
        );
        uint256 assetsInFarmDUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3
        );

        assertEq(marketIdsFromEvent, expectedMarketIds, "marketIds should be equal to marketIds[4,3]");
        assertEq(assetsInDUsdcBefore, 0, "assetsInDUsdcBefore should be 0");
        assertGt(assetsInFarmDUsdcBefore, 0, "assetsInFarmDUsdcBefore should be greater than 0");
        assertEq(totalAssetsBefore, totalAssetsAfter, "totalAssetsBefore should be equal to totalAssetsAfter");
        assertGt(assetsInDUsdcAfter, 0, "assetsInDUsdcAfter should be greater than 0");
        assertEq(assetsInFarmDUsdcAfter, 0, "assetsInFarmDUsdcAfter should be 0");
        assertGt(totalAssetsAfter, 0, "totalAssetsAfter should be greater than 0");
    }

    function testShouldCalculateBalanceWhenDependencyBalanceGraphIsSetupAndHave2dependencies() external {
        // given

        address userOne = accounts[1];
        uint256 depositAmount = random.randomNumber(
            1 * 10 ** (ERC20(asset).decimals()),
            10_000 * 10 ** (ERC20(asset).decimals())
        );
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: D_USDC,
            vaultAssetAmount: depositAmount
        });
        GearboxV3FarmdSupplyFuseEnterData memory enterDataFarm = GearboxV3FarmdSupplyFuseEnterData({
            farmdToken: FARM_D_USDC,
            dTokenAmount: depositAmount
        });
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encode(enterData);
        data[1] = abi.encode(enterDataFarm);
        uint256 len = data.length;
        FuseAction[] memory enterCalls = new FuseAction[](len);
        for (uint256 i = 0; i < len; ++i) {
            enterCalls[i] = FuseAction(fuses[i], abi.encodeWithSignature("enter(bytes)", data[i]));
        }

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;

        uint256[] memory dependencies = new uint256[](2);
        dependencies[0] = IporFusionMarketsArbitrum.GEARBOX_POOL_V3;
        dependencies[1] = IporFusionMarketsArbitrum.AAVE_V3;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependencies;

        vm.prank(accounts[0]);
        PlasmaVaultGovernance(plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(enterCalls);

        vm.startPrank(userOne);
        ERC20(USDC).forceApprove(address(plasmaVault), 100e6);
        PlasmaVault(plasmaVault).deposit(100 * 10 ** ERC20(asset).decimals(), userOne);
        vm.stopPrank();

        uint256 amountDepositedToAave = 50 * 10 ** ERC20(asset).decimals();

        vm.startPrank(plasmaVault);
        ERC20(USDC).forceApprove(address(AAVE_POOL), 100e6);
        IPool(AAVE_POOL).supply(USDC, amountDepositedToAave, address(plasmaVault), 0);
        vm.stopPrank();

        uint256 assetInAaveV3Before = PlasmaVault(plasmaVault).totalAssetsInMarket(IporFusionMarketsArbitrum.AAVE_V3);
        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInDUsdcBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.GEARBOX_POOL_V3
        );
        uint256 assetsInFarmDUsdcBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3
        );

        uint256[] memory expectedMarketIds = new uint256[](3);
        expectedMarketIds[0] = IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;
        expectedMarketIds[1] = IporFusionMarketsArbitrum.GEARBOX_POOL_V3;
        expectedMarketIds[2] = IporFusionMarketsArbitrum.AAVE_V3;

        // when
        vm.prank(alpha);
        vm.recordLogs();
        PlasmaVault(plasmaVault).execute(generateExitCallsData(assetsInFarmDUsdcBefore, new bytes32[](0)));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then

        uint256[] memory marketIdsFromEvent = _extractMarketIdsFromEvent(entries);

        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInDUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.GEARBOX_POOL_V3
        );
        uint256 assetsInFarmDUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3
        );
        uint256 assetInAaveV3After = PlasmaVault(plasmaVault).totalAssetsInMarket(IporFusionMarketsArbitrum.AAVE_V3);

        assertEq(marketIdsFromEvent, expectedMarketIds, "marketIds should be equal to marketIds[4,3,1]");
        assertEq(assetsInDUsdcBefore, 0, "assetsInDUsdcBefore should be 0");
        assertGt(assetsInFarmDUsdcBefore, 0, "assetsInFarmDUsdcBefore should be greater than 0");
        assertEq(
            totalAssetsBefore + amountDepositedToAave,
            totalAssetsAfter,
            "totalAssetsBefore should be equal to totalAssetsAfter"
        );
        assertGt(assetsInDUsdcAfter, 0, "assetsInDUsdcAfter should be greater than 0");
        assertEq(assetsInFarmDUsdcAfter, 0, "assetsInFarmDUsdcAfter should be 0");
        assertGt(totalAssetsAfter, 0, "totalAssetsAfter should be greater than 0");
        assertEq(assetInAaveV3Before, 0, "assetInAaveV3Before should be 0");
        assertEq(
            assetInAaveV3After,
            amountDepositedToAave,
            "assetInAaveV3After should be equal to amountDepositedToAave"
        );
    }

    function testShouldCalculateBalanceWhenDependencyBalanceGraphIsSetupAndHaveCyclicDependencies() external {
        // given

        address userOne = accounts[1];
        uint256 depositAmount = random.randomNumber(
            1 * 10 ** (ERC20(asset).decimals()),
            10_000 * 10 ** (ERC20(asset).decimals())
        );
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: D_USDC,
            vaultAssetAmount: depositAmount
        });
        GearboxV3FarmdSupplyFuseEnterData memory enterDataFarm = GearboxV3FarmdSupplyFuseEnterData({
            farmdToken: FARM_D_USDC,
            dTokenAmount: depositAmount
        });
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encode(enterData);
        data[1] = abi.encode(enterDataFarm);
        uint256 len = data.length;
        FuseAction[] memory enterCalls = new FuseAction[](len);
        for (uint256 i = 0; i < len; ++i) {
            enterCalls[i] = FuseAction(fuses[i], abi.encodeWithSignature("enter(bytes)", data[i]));
        }

        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;
        marketIds[1] = IporFusionMarketsArbitrum.AAVE_V3;

        uint256[] memory dependencies = new uint256[](2);
        dependencies[0] = IporFusionMarketsArbitrum.GEARBOX_POOL_V3;
        dependencies[1] = IporFusionMarketsArbitrum.AAVE_V3;

        uint256[] memory dependenciesAave = new uint256[](2);
        dependenciesAave[0] = IporFusionMarketsArbitrum.GEARBOX_POOL_V3;
        dependenciesAave[1] = IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;

        uint256[][] memory dependenceMarkets = new uint256[][](2);
        dependenceMarkets[0] = dependencies;
        dependenceMarkets[1] = dependenciesAave;

        vm.prank(accounts[0]);
        PlasmaVaultGovernance(plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(enterCalls);

        vm.startPrank(userOne);
        ERC20(USDC).forceApprove(address(plasmaVault), 100e6);
        PlasmaVault(plasmaVault).deposit(100 * 10 ** ERC20(asset).decimals(), userOne);
        vm.stopPrank();

        uint256 amountDepositedToAave = 50 * 10 ** ERC20(asset).decimals();

        vm.startPrank(plasmaVault);
        ERC20(USDC).forceApprove(address(AAVE_POOL), 100e6);
        IPool(AAVE_POOL).supply(USDC, amountDepositedToAave, address(plasmaVault), 0);
        vm.stopPrank();

        uint256 assetInAaveV3Before = PlasmaVault(plasmaVault).totalAssetsInMarket(IporFusionMarketsArbitrum.AAVE_V3);
        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInDUsdcBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.GEARBOX_POOL_V3
        );
        uint256 assetsInFarmDUsdcBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3
        );

        uint256[] memory expectedMarketIds = new uint256[](3);
        expectedMarketIds[0] = IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;
        expectedMarketIds[1] = IporFusionMarketsArbitrum.GEARBOX_POOL_V3;
        expectedMarketIds[2] = IporFusionMarketsArbitrum.AAVE_V3;

        // when
        vm.prank(alpha);
        vm.recordLogs();
        PlasmaVault(plasmaVault).execute(generateExitCallsData(assetsInFarmDUsdcBefore, new bytes32[](0)));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then

        uint256[] memory marketIdsFromEvent = _extractMarketIdsFromEvent(entries);

        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInDUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.GEARBOX_POOL_V3
        );
        uint256 assetsInFarmDUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3
        );
        uint256 assetInAaveV3After = PlasmaVault(plasmaVault).totalAssetsInMarket(IporFusionMarketsArbitrum.AAVE_V3);

        assertEq(marketIdsFromEvent, expectedMarketIds, "marketIds should be equal to marketIds[4,3,1]");
        assertEq(assetsInDUsdcBefore, 0, "assetsInDUsdcBefore should be 0");
        assertGt(assetsInFarmDUsdcBefore, 0, "assetsInFarmDUsdcBefore should be greater than 0");
        assertEq(
            totalAssetsBefore + amountDepositedToAave,
            totalAssetsAfter,
            "totalAssetsBefore should be equal to totalAssetsAfter"
        );
        assertGt(assetsInDUsdcAfter, 0, "assetsInDUsdcAfter should be greater than 0");
        assertEq(assetsInFarmDUsdcAfter, 0, "assetsInFarmDUsdcAfter should be 0");
        assertGt(totalAssetsAfter, 0, "totalAssetsAfter should be greater than 0");
        assertEq(assetInAaveV3Before, 0, "assetInAaveV3Before should be 0");
        assertEq(
            assetInAaveV3After,
            amountDepositedToAave,
            "assetInAaveV3After should be equal to amountDepositedToAave"
        );
    }

    function testShouldCalculateBalanceWhenChainDependency() external {
        // given

        address userOne = accounts[1];
        uint256 depositAmount = random.randomNumber(
            1 * 10 ** (ERC20(asset).decimals()),
            10_000 * 10 ** (ERC20(asset).decimals())
        );
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: D_USDC,
            vaultAssetAmount: depositAmount
        });

        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(enterData);
        FuseAction[] memory enterCalls = new FuseAction[](1);

        enterCalls[0] = FuseAction(fuses[0], abi.encodeWithSignature("enter(bytes)", data[0]));

        uint256[] memory marketIds = new uint256[](3);
        marketIds[0] = IporFusionMarketsArbitrum.GEARBOX_POOL_V3;
        marketIds[1] = IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;
        marketIds[2] = IporFusionMarketsArbitrum.AAVE_V3;

        uint256[] memory dependenceGearboxDToken = new uint256[](1);
        dependenceGearboxDToken[0] = IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;

        uint256[] memory dependenceGearboxFarmDToken = new uint256[](1);
        dependenceGearboxFarmDToken[0] = IporFusionMarketsArbitrum.AAVE_V3;

        uint256[] memory dependenceAave = new uint256[](1);
        dependenceAave[0] = IporFusionMarketsArbitrum.COMPOUND_V3;

        uint256[][] memory dependenceMarkets = new uint256[][](3);
        dependenceMarkets[0] = dependenceGearboxDToken;
        dependenceMarkets[1] = dependenceGearboxFarmDToken;
        dependenceMarkets[2] = dependenceAave;

        vm.prank(accounts[0]);
        PlasmaVaultGovernance(plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);

        uint256[] memory expectedMarketIds = new uint256[](4);
        expectedMarketIds[0] = IporFusionMarketsArbitrum.GEARBOX_POOL_V3;
        expectedMarketIds[1] = IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;
        expectedMarketIds[2] = IporFusionMarketsArbitrum.AAVE_V3;
        expectedMarketIds[3] = IporFusionMarketsArbitrum.COMPOUND_V3;

        // when
        vm.prank(alpha);
        vm.recordLogs();
        PlasmaVault(plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then

        uint256[] memory marketIdsFromEvent = _extractMarketIdsFromEvent(entries);

        assertEq(marketIdsFromEvent, expectedMarketIds, "marketIds should be equal to marketIds[3,4,1,2]");
    }

    function testShouldCalculateBalanceWhenDependency1get3and2get1() external {
        // given

        address userOne = accounts[1];
        uint256 depositAmount = random.randomNumber(
            1 * 10 ** (ERC20(asset).decimals()),
            10_000 * 10 ** (ERC20(asset).decimals())
        );
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: D_USDC,
            vaultAssetAmount: depositAmount
        });

        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(enterData);
        FuseAction[] memory enterCalls = new FuseAction[](1);

        enterCalls[0] = FuseAction(fuses[0], abi.encodeWithSignature("enter(bytes)", data[0]));

        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = IporFusionMarketsArbitrum.GEARBOX_POOL_V3;
        marketIds[1] = IporFusionMarketsArbitrum.AAVE_V3;

        uint256[] memory dependenceGearboxDToken = new uint256[](2);
        dependenceGearboxDToken[0] = IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;
        dependenceGearboxDToken[1] = IporFusionMarketsArbitrum.AAVE_V3;

        uint256[] memory dependenceAave = new uint256[](1);
        dependenceAave[0] = IporFusionMarketsArbitrum.COMPOUND_V3;

        uint256[][] memory dependenceMarkets = new uint256[][](2);
        dependenceMarkets[0] = dependenceGearboxDToken;
        dependenceMarkets[1] = dependenceAave;

        vm.prank(accounts[0]);
        PlasmaVaultGovernance(plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);

        uint256[] memory expectedMarketIds = new uint256[](4);
        expectedMarketIds[0] = IporFusionMarketsArbitrum.GEARBOX_POOL_V3;
        expectedMarketIds[1] = IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;
        expectedMarketIds[2] = IporFusionMarketsArbitrum.AAVE_V3;
        expectedMarketIds[3] = IporFusionMarketsArbitrum.COMPOUND_V3;

        // when
        vm.prank(alpha);
        vm.recordLogs();
        PlasmaVault(plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then

        uint256[] memory marketIdsFromEvent = _extractMarketIdsFromEvent(entries);

        assertEq(marketIdsFromEvent, expectedMarketIds, "marketIds should be equal to marketIds[3,4,1,2]");
    }

    function testShouldCalculateBalanceWhenDependency1get3and2get2() external {
        // given

        address userOne = accounts[1];
        uint256 depositAmount = random.randomNumber(
            1 * 10 ** (ERC20(asset).decimals()),
            10_000 * 10 ** (ERC20(asset).decimals())
        );
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: D_USDC,
            vaultAssetAmount: depositAmount
        });

        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(enterData);
        FuseAction[] memory enterCalls = new FuseAction[](1);

        enterCalls[0] = FuseAction(fuses[0], abi.encodeWithSignature("enter(bytes)", data[0]));

        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = IporFusionMarketsArbitrum.GEARBOX_POOL_V3;
        marketIds[1] = IporFusionMarketsArbitrum.AAVE_V3;

        uint256[] memory dependenceGearboxDToken = new uint256[](2);
        dependenceGearboxDToken[0] = IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;
        dependenceGearboxDToken[1] = IporFusionMarketsArbitrum.AAVE_V3;

        uint256[] memory dependenceAave = new uint256[](2);
        dependenceAave[0] = IporFusionMarketsArbitrum.COMPOUND_V3;
        dependenceAave[1] = IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;

        uint256[][] memory dependenceMarkets = new uint256[][](2);
        dependenceMarkets[0] = dependenceGearboxDToken;
        dependenceMarkets[1] = dependenceAave;

        vm.prank(accounts[0]);
        PlasmaVaultGovernance(plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);

        uint256[] memory expectedMarketIds = new uint256[](4);
        expectedMarketIds[0] = IporFusionMarketsArbitrum.GEARBOX_POOL_V3;
        expectedMarketIds[1] = IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;
        expectedMarketIds[2] = IporFusionMarketsArbitrum.AAVE_V3;
        expectedMarketIds[3] = IporFusionMarketsArbitrum.COMPOUND_V3;

        // when
        vm.prank(alpha);
        vm.recordLogs();
        PlasmaVault(plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then

        uint256[] memory marketIdsFromEvent = _extractMarketIdsFromEvent(entries);

        assertEq(marketIdsFromEvent, expectedMarketIds, "marketIds should be equal to marketIds[3,4,1,2]");
    }

    function generateExitCallsData(
        uint256 amount_,
        bytes32[] memory data_
    ) private returns (FuseAction[] memory enterCalls) {
        (address[] memory fusesSetup, bytes[] memory enterData) = getExitFuseData(amount_, data_);
        uint256 len = enterData.length;
        enterCalls = new FuseAction[](len);
        for (uint256 i = 0; i < len; ++i) {
            enterCalls[i] = FuseAction(fusesSetup[i], abi.encodeWithSignature("exit(bytes)", enterData[i]));
        }
        return enterCalls;
    }

    function _extractMarketIdsFromEvent(Vm.Log[] memory entries) private view returns (uint256[] memory) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("MarketBalancesUpdated(uint256[],int256)")) {
                (uint256[] memory marketIds, ) = abi.decode(entries[i].data, (uint256[], int256));
                return marketIds;
            }
        }
        return new uint256[](0);
    }
}
