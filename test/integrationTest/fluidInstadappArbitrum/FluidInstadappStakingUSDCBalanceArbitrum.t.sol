// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FuseAction, PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {ERC4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {IporFusionMarketsArbitrum} from "../../../contracts/libraries/IporFusionMarketsArbitrum.sol";
import {FluidInstadappStakingSupplyFuseExitData, FluidInstadappStakingSupplyFuseEnterData, FluidInstadappStakingSupplyFuse} from "../../../contracts/fuses/fluid_instadapp/FluidInstadappStakingSupplyFuse.sol";
import {FluidInstadappStakingBalanceFuse} from "../../../contracts/fuses/fluid_instadapp/FluidInstadappStakingBalanceFuse.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {AaveV3SupplyFuse} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {IPool} from "../../../contracts/fuses/aave_v3/ext/IPool.sol";

import {TestAccountSetup} from "../supplyFuseTemplate/TestAccountSetup.sol";
import {TestPriceOracleSetup} from "../supplyFuseTemplate/TestPriceOracleSetup.sol";
import {TestVaultSetup} from "../supplyFuseTemplate/TestVaultSetup.sol";

contract FluidInstadappStakingUSDCBalanceArbitrum is TestAccountSetup, TestPriceOracleSetup, TestVaultSetup {
    using SafeERC20 for ERC20;

    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant CHAINLINK_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address public constant PRICE_ORACLE_MIDDLEWARE_USD = 0x85a3Ee1688eE8D320eDF4024fB67734Fa8492cF4;

    address public constant F_TOKEN = 0x1A996cb54bb95462040408C06122D45D6Cdb6096;
    address public constant FLUID_LENDING_STAKING_REWARDS = 0x48f89d731C5e3b5BeE8235162FC2C639Ba62DB7d;

    address public constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public constant AAVE_POOL_DATA_PROVIDER = 0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654;
    address public constant AAVE_PRICE_ORACLE = 0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7;

    FluidInstadappStakingSupplyFuse public fluidInstadappStakingSupplyFuse;
    Erc4626SupplyFuse public erc4626SupplyFuse;
    AaveV3BalanceFuse public aaveFuseBalance;

    uint256 private constant ERROR_DELTA = 100;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 236207803);
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
        marketConfigs = new MarketSubstratesConfig[](3);
        bytes32[] memory assetsFToken = new bytes32[](1);
        assetsFToken[0] = PlasmaVaultConfigLib.addressToBytes32(F_TOKEN);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarketsArbitrum.FLUID_INSTADAPP_POOL, assetsFToken);

        bytes32[] memory assetsStakingUsdc = new bytes32[](1);
        assetsStakingUsdc[0] = PlasmaVaultConfigLib.addressToBytes32(FLUID_LENDING_STAKING_REWARDS);
        marketConfigs[1] = MarketSubstratesConfig(IporFusionMarketsArbitrum.FLUID_INSTADAPP_STAKING, assetsStakingUsdc);

        bytes32[] memory assetsAave = new bytes32[](1);
        assetsAave[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        marketConfigs[2] = MarketSubstratesConfig(IporFusionMarketsArbitrum.AAVE_V3, assetsAave);
    }

    function setupFuses() public override {
        erc4626SupplyFuse = new Erc4626SupplyFuse(IporFusionMarketsArbitrum.FLUID_INSTADAPP_POOL);
        fluidInstadappStakingSupplyFuse = new FluidInstadappStakingSupplyFuse(
            IporFusionMarketsArbitrum.FLUID_INSTADAPP_STAKING
        );
        AaveV3SupplyFuse fuseAave = new AaveV3SupplyFuse(
            IporFusionMarketsArbitrum.AAVE_V3,
            AAVE_POOL,
            AAVE_POOL_DATA_PROVIDER
        );

        fuses = new address[](3);
        fuses[0] = address(erc4626SupplyFuse);
        fuses[1] = address(fluidInstadappStakingSupplyFuse);
        fuses[2] = address(fuseAave);
    }

    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        ERC4626BalanceFuse erc4626BalanceFuse = new ERC4626BalanceFuse(
            IporFusionMarketsArbitrum.FLUID_INSTADAPP_POOL,
            priceOracle
        );

        FluidInstadappStakingBalanceFuse fluidInstadappStakingBalance = new FluidInstadappStakingBalanceFuse(
            IporFusionMarketsArbitrum.FLUID_INSTADAPP_STAKING
        );

        aaveFuseBalance = new AaveV3BalanceFuse(
            IporFusionMarketsArbitrum.AAVE_V3,
            AAVE_PRICE_ORACLE,
            AAVE_POOL_DATA_PROVIDER
        );

        balanceFuses = new MarketBalanceFuseConfig[](3);
        balanceFuses[0] = MarketBalanceFuseConfig(
            IporFusionMarketsArbitrum.FLUID_INSTADAPP_POOL,
            address(erc4626BalanceFuse)
        );

        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarketsArbitrum.FLUID_INSTADAPP_STAKING,
            address(fluidInstadappStakingBalance)
        );

        balanceFuses[2] = MarketBalanceFuseConfig(IporFusionMarketsArbitrum.AAVE_V3, address(aaveFuseBalance));
    }

    function setupInstantWithdrawFusesOrder() internal {
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](2);

        bytes32[] memory instantWithdrawParamsFluidStakingFUsdc = new bytes32[](2);
        instantWithdrawParamsFluidStakingFUsdc[0] = 0;
        instantWithdrawParamsFluidStakingFUsdc[1] = PlasmaVaultConfigLib.addressToBytes32(FLUID_LENDING_STAKING_REWARDS);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: fuses[1],
            params: instantWithdrawParamsFluidStakingFUsdc
        });

        bytes32[] memory instantWithdrawParamsFluidFUsdc = new bytes32[](2);
        instantWithdrawParamsFluidFUsdc[0] = 0;
        instantWithdrawParamsFluidFUsdc[1] = PlasmaVaultConfigLib.addressToBytes32(F_TOKEN);

        instantWithdrawFuses[1] = InstantWithdrawalFusesParamsStruct({
            fuse: fuses[0],
            params: instantWithdrawParamsFluidFUsdc
        });


        vm.prank(getOwner());
        PlasmaVault(plasmaVault).configureInstantWithdrawalFuses(instantWithdrawFuses);
    }

    function getEnterFuseData(
        uint256 amount_,
    //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (bytes[] memory data) {
        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({vault: F_TOKEN, vaultAssetAmount: amount_});
        FluidInstadappStakingSupplyFuseEnterData memory enterDataStaking = FluidInstadappStakingSupplyFuseEnterData({
            stakingPool: FLUID_LENDING_STAKING_REWARDS,
            fluidTokenAmount: amount_
        });
        data = new bytes[](2);
        data[0] = abi.encode(enterData);
        data[1] = abi.encode(enterDataStaking);
    }

    function getExitFuseData(
        uint256 amount_,
    //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (address[] memory fusesSetup, bytes[] memory data) {
        FluidInstadappStakingSupplyFuseExitData memory exitDataStaking = FluidInstadappStakingSupplyFuseExitData({
            stakingPool: FLUID_LENDING_STAKING_REWARDS,
            fluidTokenAmount: amount_
        });
        data = new bytes[](1);
        data[0] = abi.encode(exitDataStaking);

        fusesSetup = new address[](2);
        fusesSetup[0] = address(fluidInstadappStakingSupplyFuse);
    }

    function testShouldCalculateWrongBalanceWhenDependencyBalanceGraphNotSetup() external {
        // given

        address userOne = accounts[1];
        uint256 depositAmount = 1 * 10 ** (ERC20(asset).decimals());
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: F_TOKEN,
            vaultAssetAmount: depositAmount
        });
        FluidInstadappStakingSupplyFuseEnterData memory enterDataStaking = FluidInstadappStakingSupplyFuseEnterData({
            stakingPool: FLUID_LENDING_STAKING_REWARDS,
            fluidTokenAmount: depositAmount
        });
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encode(enterData);
        data[1] = abi.encode(enterDataStaking);
        uint256 len = data.length;
        FuseAction[] memory enterCalls = new FuseAction[](len);
        for (uint256 i = 0; i < len; ++i) {
            enterCalls[i] = FuseAction(fuses[i], abi.encodeWithSignature("enter(bytes)", data[i]));
        }

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(enterCalls);

        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();

        uint256 assetsInDUsdcBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.FLUID_INSTADAPP_POOL
        );
        uint256 assetsInStakedUsdcBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.FLUID_INSTADAPP_STAKING
        );

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(generateExitCallsData(assetsInStakedUsdcBefore, new bytes32[](0)));

        // then

        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInDUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.FLUID_INSTADAPP_POOL
        );
        uint256 assetsInStakedUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.FLUID_INSTADAPP_STAKING
        );

        assertEq(assetsInDUsdcBefore, 0, "assetsInDUsdcBefore should be 0");
        assertGt(assetsInStakedUsdcBefore, 0, "assetsInStakedUsdcBefore should be greater than 0");
        assertGt(totalAssetsBefore, 0, "totalAssetsBefore should be greater than 0");
        assertEq(assetsInDUsdcAfter, 0, "assetsInDUsdcAfter should be 0");
        assertEq(assetsInStakedUsdcAfter, 0, "assetsInStakedUsdcAfter should be 0");
        assertEq(totalAssetsAfter, 0, "totalAssetsAfter should be 0");
    }

    function testShouldCalculateBalanceWhenDependencyBalanceGraphIsSetup() external {
        // given

        address userOne = accounts[1];
        uint256 depositAmount = 1 * 10 ** (ERC20(asset).decimals());
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: F_TOKEN,
            vaultAssetAmount: depositAmount
        });
        FluidInstadappStakingSupplyFuseEnterData memory enterDataStaked = FluidInstadappStakingSupplyFuseEnterData({
            stakingPool: FLUID_LENDING_STAKING_REWARDS,
            fluidTokenAmount: depositAmount
        });
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encode(enterData);
        data[1] = abi.encode(enterDataStaked);
        uint256 len = data.length;
        FuseAction[] memory enterCalls = new FuseAction[](len);
        for (uint256 i = 0; i < len; ++i) {
            enterCalls[i] = FuseAction(fuses[i], abi.encodeWithSignature("enter(bytes)", data[i]));
        }

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarketsArbitrum.FLUID_INSTADAPP_STAKING;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarketsArbitrum.FLUID_INSTADAPP_POOL;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        vm.prank(accounts[0]);
        PlasmaVaultGovernance(plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(enterCalls);

        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();

        uint256 assetsInDUsdcBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.FLUID_INSTADAPP_POOL
        );
        uint256 assetsInStakedUsdcBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.FLUID_INSTADAPP_STAKING
        );

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(generateExitCallsData(assetsInStakedUsdcBefore, new bytes32[](0)));

        // then

        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInDUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.FLUID_INSTADAPP_POOL
        );
        uint256 assetsInStakedUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.FLUID_INSTADAPP_STAKING
        );

        assertEq(assetsInDUsdcBefore, 0, "assetsInDUsdcBefore should be 0");
        assertGt(assetsInStakedUsdcBefore, 0, "assetsInStakedUsdcBefore should be greater than 0");
        assertEq(totalAssetsBefore, totalAssetsAfter, "totalAssetsBefore should be equal to totalAssetsAfter");
        assertGt(assetsInDUsdcAfter, 0, "assetsInDUsdcAfter should be greater than 0");
        assertEq(assetsInStakedUsdcAfter, 0, "assetsInStakedUsdcAfter should be 0");
        assertGt(totalAssetsAfter, 0, "totalAssetsAfter should be greater than 0");
    }

    function testShouldCalculateBalanceWhenDependencyBalanceGraphIsSetupAndHave2dependencies() external {
        // given

        address userOne = accounts[1];
        uint256 depositAmount = 1 * 10 ** (ERC20(asset).decimals());
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: F_TOKEN,
            vaultAssetAmount: depositAmount
        });
        FluidInstadappStakingSupplyFuseEnterData memory enterDataStaking = FluidInstadappStakingSupplyFuseEnterData({
            stakingPool: FLUID_LENDING_STAKING_REWARDS,
            fluidTokenAmount: depositAmount
        });
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encode(enterData);
        data[1] = abi.encode(enterDataStaking);
        uint256 len = data.length;
        FuseAction[] memory enterCalls = new FuseAction[](len);
        for (uint256 i = 0; i < len; ++i) {
            enterCalls[i] = FuseAction(fuses[i], abi.encodeWithSignature("enter(bytes)", data[i]));
        }

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarketsArbitrum.FLUID_INSTADAPP_STAKING;

        uint256[] memory dependencies = new uint256[](2);
        dependencies[0] = IporFusionMarketsArbitrum.FLUID_INSTADAPP_POOL;
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
            IporFusionMarketsArbitrum.FLUID_INSTADAPP_POOL
        );
        uint256 assetsInStakedUsdcBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.FLUID_INSTADAPP_STAKING
        );

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(generateExitCallsData(assetsInStakedUsdcBefore, new bytes32[](0)));

        // then

        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInDUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.FLUID_INSTADAPP_POOL
        );
        uint256 assetsInStakedUsdcAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(
            IporFusionMarketsArbitrum.FLUID_INSTADAPP_STAKING
        );
        uint256 assetInAaveV3After = PlasmaVault(plasmaVault).totalAssetsInMarket(IporFusionMarketsArbitrum.AAVE_V3);

        assertEq(assetsInDUsdcBefore, 0, "assetsInDUsdcBefore should be 0");
        assertGt(assetsInStakedUsdcBefore, 0, "assetsInStakedUsdcBefore should be greater than 0");
        assertEq(
            totalAssetsBefore + amountDepositedToAave,
            totalAssetsAfter,
            "totalAssetsBefore should be equal to totalAssetsAfter"
        );
        assertGt(assetsInDUsdcAfter, 0, "assetsInDUsdcAfter should be greater than 0");
        assertEq(assetsInStakedUsdcAfter, 0, "assetsInStakedUsdcAfter should be 0");
        assertGt(totalAssetsAfter, 0, "totalAssetsAfter should be greater than 0");
        assertEq(assetInAaveV3Before, 0, "assetInAaveV3Before should be 0");
        assertEq(
            assetInAaveV3After,
            amountDepositedToAave,
            "assetInAaveV3After should be equal to amountDepositedToAave"
        );
    }

    function testShouldInstantWithdrawFluid() public {
        // given
        address userOne = address(0x123);

        uint256 depositAmount = 5_000 * 10 ** (ERC20(USDC).decimals());

        vm.prank(0x47c031236e19d024b42f8AE6780E44A573170703);
        ERC20(USDC).transfer(address(userOne), 2 * depositAmount);

        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), depositAmount);

        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        FuseAction[] memory calls = new FuseAction[](2);

        calls[0] = FuseAction(
            address(fuses[0]),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(Erc4626SupplyFuseEnterData({vault: F_TOKEN, vaultAssetAmount: depositAmount}))
            )
        );

        calls[1] = FuseAction(
            address(fuses[1]),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(FluidInstadappStakingSupplyFuseEnterData({
                    stakingPool: FLUID_LENDING_STAKING_REWARDS,
                    fluidTokenAmount: depositAmount
                }))
            )
        );

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        uint256 userOneMaxWithdraw = PlasmaVault(plasmaVault).maxWithdraw(userOne);

        uint256 vaultStakingFTokenBalanceBefore = ERC20(FLUID_LENDING_STAKING_REWARDS).balanceOf(plasmaVault);
        uint256 vaultFTokenBalanceBefore = ERC20(F_TOKEN).balanceOf(plasmaVault);

        setupInstantWithdrawFusesOrder();

        // when
        vm.startPrank(userOne);
        PlasmaVault(plasmaVault).withdraw(userOneMaxWithdraw, userOne, userOne);
        vm.stopPrank();

        // then
        uint256 userBalanceAfter = ERC20(USDC).balanceOf(userOne);
        uint256 vaultStakingFTokenBalanceAfter = ERC20(FLUID_LENDING_STAKING_REWARDS).balanceOf(plasmaVault);
        uint256 vaultFTokenBalanceAfter = ERC20(F_TOKEN).balanceOf(plasmaVault);

        ///@dev user lost maintenance fee
        assertEq(userBalanceAfter, 9999999999);
        assertEq(vaultStakingFTokenBalanceBefore, 4994839265, "vaultStakingFTokenBalanceBefore");
        assertEq(vaultStakingFTokenBalanceAfter, 0, "vaultStakingFTokenBalanceAfter");
        assertEq(vaultFTokenBalanceBefore, 0, "vaultFTokenBalanceBefore");
        assertEq(vaultFTokenBalanceAfter, 0, "vaultFTokenBalanceAfter");

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
}
