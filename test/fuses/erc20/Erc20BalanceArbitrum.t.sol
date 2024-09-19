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
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

import {TestAccountSetup} from "../../integrationTest/supplyFuseTemplate/TestAccountSetup.sol";
import {TestPriceOracleSetup} from "../../integrationTest/supplyFuseTemplate/TestPriceOracleSetup.sol";
import {TestVaultSetup} from "../../integrationTest/supplyFuseTemplate/TestVaultSetup.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";

import {Vm} from "forge-std/Test.sol";

contract Erc20BalanceArbitrumTest is TestAccountSetup, TestPriceOracleSetup, TestVaultSetup {
    using SafeERC20 for ERC20;

    event MarketBalancesUpdated(uint256[] marketIds, int256 deltaInUnderlying);

    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant CHAINLINK_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address private constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address private constant CHAINLINK_USDT = 0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7;
    address private constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address private constant CHAINLINK_DAI = 0xc5C8E77B397E531B8EC06BFb0048328B30E9eCfB;
    address public constant D_USDC = 0x890A69EF363C9c7BdD5E36eb95Ceb569F63ACbF6;
    address public constant PRICE_ORACLE_MIDDLEWARE_USD = 0x85a3Ee1688eE8D320eDF4024fB67734Fa8492cF4;

    address public constant COMET = 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf;

    Erc4626SupplyFuse public gearboxV3DTokenFuse;

    uint256 private constant ERROR_DELTA = 10;

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
        assets = new address[](3);
        sources = new address[](3);
        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC;
        assets[1] = USDT;
        sources[1] = CHAINLINK_USDT;
        assets[2] = DAI;
        sources[2] = CHAINLINK_DAI;
    }

    function setupMarketConfigs() public override returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](2);
        bytes32[] memory assetsDUsdc = new bytes32[](1);
        assetsDUsdc[0] = PlasmaVaultConfigLib.addressToBytes32(D_USDC);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.GEARBOX_POOL_V3, assetsDUsdc);

        bytes32[] memory assetsErc20 = new bytes32[](3);
        assetsErc20[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        assetsErc20[1] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        assetsErc20[2] = PlasmaVaultConfigLib.addressToBytes32(USDT);

        marketConfigs[1] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, assetsErc20);
    }

    function setupFuses() public override {
        gearboxV3DTokenFuse = new Erc4626SupplyFuse(IporFusionMarkets.GEARBOX_POOL_V3);

        fuses = new address[](1);
        fuses[0] = address(gearboxV3DTokenFuse);
    }

    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        ERC4626BalanceFuse gearboxV3Balances = new ERC4626BalanceFuse(IporFusionMarkets.GEARBOX_POOL_V3);

        ERC20BalanceFuse erc20BalanceArbitrum = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(IporFusionMarkets.GEARBOX_POOL_V3, address(gearboxV3Balances));

        balanceFuses[1] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20BalanceArbitrum));
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
        data = new bytes[](1);
        data[0] = abi.encode(enterData);
    }

    function getExitFuseData(
        //solhint-disable-next-line
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (address[] memory fusesSetup, bytes[] memory data) {
        fusesSetup = new address[](0);
        data = new bytes[](0);
    }

    function testShouldCalculateErc20BalanceEqual0WhenExecute() external {
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

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(fuses[0], abi.encodeWithSignature("enter((address,uint256))", enterData));

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.GEARBOX_POOL_V3;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        vm.prank(accounts[0]);
        PlasmaVaultGovernance(plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);

        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();

        uint256 assetsInDUsdcBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(IporFusionMarkets.GEARBOX_POOL_V3);
        uint256 assetsInErc20Before = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        //when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(enterCalls);

        // then

        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInDUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(IporFusionMarkets.GEARBOX_POOL_V3);
        uint256 assetsInErc20After = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        assertEq(assetsInDUsdcBefore, 0, "assetsInDUsdcBefore should be 0");
        assertEq(assetsInErc20Before, 0, "assetsInErc20Before should be 0");
        assertApproxEqAbs(
            totalAssetsBefore,
            totalAssetsAfter,
            ERROR_DELTA,
            "totalAssetsBefore should be equal to totalAssetsAfter"
        );
        assertGt(assetsInDUsdcAfter, 0, "assetsInDUsdcAfter should be greater than 0");
        assertApproxEqAbs(assetsInErc20After, 0, ERROR_DELTA, "assetsInErc20After should be 0");
        assertGt(totalAssetsAfter, 0, "totalAssetsAfter should be greater than 0");
    }

    function testShouldCalculateErc20BalanceWhenTransferDaiOnVault() external {
        // given

        uint256 daiAmountToTransfer = 100e18;
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

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(fuses[0], abi.encodeWithSignature("enter((address,uint256))", enterData));

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.GEARBOX_POOL_V3;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        vm.prank(accounts[0]);
        PlasmaVaultGovernance(plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);

        deal(address(DAI), userOne, 1000e18);

        vm.prank(userOne);
        ERC20(DAI).transfer(plasmaVault, daiAmountToTransfer);

        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();

        uint256 assetsInDUsdcBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(IporFusionMarkets.GEARBOX_POOL_V3);
        uint256 assetsInErc20Before = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        //when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(enterCalls);

        // then

        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInDUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(IporFusionMarkets.GEARBOX_POOL_V3);
        uint256 assetsInErc20After = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        assertEq(assetsInDUsdcBefore, 0, "assetsInDUsdcBefore should be 0");
        assertEq(assetsInErc20Before, 0, "assetsInErc20Before should be 0");
        assertGt(totalAssetsAfter, totalAssetsBefore, "totalAssetsAfter should be greater than totalAssetsBefore");
        assertGt(assetsInDUsdcAfter, 0, "assetsInDUsdcAfter should be greater than 0");
        assertGt(assetsInErc20After, 0, "assetsInErc20After should be greater than 0");
        assertGt(totalAssetsAfter, 0, "totalAssetsAfter should be greater than 0");
    }

    function testShouldCalculateErc20BalanceWhenTransferDaiAndUsdtOnVault() external {
        // given

        uint256 daiAmountToTransfer = 100e18;
        uint256 usdtAmountToTransfer = 100e6;
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

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(fuses[0], abi.encodeWithSignature("enter((address,uint256))", enterData));

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.GEARBOX_POOL_V3;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        vm.prank(accounts[0]);
        PlasmaVaultGovernance(plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);

        deal(address(DAI), userOne, 1000e18);
        deal(address(USDT), userOne, 1000e6);

        vm.prank(userOne);
        ERC20(DAI).transfer(plasmaVault, daiAmountToTransfer);
        vm.prank(userOne);
        ERC20(USDT).transfer(plasmaVault, usdtAmountToTransfer);

        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();

        uint256 assetsInDUsdcBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(IporFusionMarkets.GEARBOX_POOL_V3);
        uint256 assetsInErc20Before = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        //when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(enterCalls);

        // then

        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInDUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(IporFusionMarkets.GEARBOX_POOL_V3);
        uint256 assetsInErc20After = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        assertEq(assetsInDUsdcBefore, 0, "assetsInDUsdcBefore should be 0");
        assertEq(assetsInErc20Before, 0, "assetsInErc20Before should be 0");
        assertGt(totalAssetsAfter, totalAssetsBefore, "totalAssetsAfter should be greater than totalAssetsBefore");
        assertGt(assetsInDUsdcAfter, 0, "assetsInDUsdcAfter should be greater than 0");
        assertApproxEqAbs(assetsInErc20After, 200e6, 1e5, "assetsInErc20After should be equal to 200e6");
        assertGt(totalAssetsAfter, 0, "totalAssetsAfter should be greater than 0");
    }

    function testShouldCalculateErc20BalanceEqual0WhenTransferUSDCOnVault() external {
        // given

        uint256 usdcAmountToTransfer = 10e6;
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

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(fuses[0], abi.encodeWithSignature("enter((address,uint256))", enterData));

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.GEARBOX_POOL_V3;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        vm.prank(accounts[0]);
        PlasmaVaultGovernance(plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);

        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();

        uint256 assetsInDUsdcBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(IporFusionMarkets.GEARBOX_POOL_V3);
        uint256 assetsInErc20Before = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        //when
        vm.prank(userOne);
        ERC20(USDC).transfer(plasmaVault, usdcAmountToTransfer);

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(enterCalls);

        // then

        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInDUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(IporFusionMarkets.GEARBOX_POOL_V3);
        uint256 assetsInErc20After = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        assertEq(assetsInDUsdcBefore, 0, "assetsInDUsdcBefore should be 0");
        assertEq(assetsInErc20Before, 0, "assetsInErc20Before should be 0");
        assertGt(totalAssetsAfter, totalAssetsBefore, "totalAssetsAfter should be greater than totalAssetsBefore");
        assertGt(assetsInDUsdcAfter, 0, "assetsInDUsdcAfter should be greater than 0");
        assertEq(assetsInErc20After, 0, "assetsInErc20After should be 0");
        assertGt(totalAssetsAfter, depositAmount, "totalAssetsAfter should be greater than depositAmount");
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
