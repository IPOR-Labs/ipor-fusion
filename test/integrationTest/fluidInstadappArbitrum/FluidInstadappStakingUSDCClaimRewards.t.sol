// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FuseAction, PlasmaVault, FeeConfig, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {ERC4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InitializationData} from "../../../contracts/managers/access/IporFusionAccessManagerInitializationLib.sol";
import {FluidInstadappStakingSupplyFuse, FluidInstadappStakingSupplyFuseEnterData} from "../../../contracts/fuses/fluid_instadapp/FluidInstadappStakingSupplyFuse.sol";
import {IFluidLendingStakingRewards} from "../../../contracts/fuses/fluid_instadapp/ext/IFluidLendingStakingRewards.sol";
import {FluidInstadappStakingBalanceFuse} from "../../../contracts/fuses/fluid_instadapp/FluidInstadappStakingBalanceFuse.sol";
import {FluidInstadappClaimFuse} from "../../../contracts/rewards_fuses/fluid_instadapp/FluidInstadappClaimFuse.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {FeeFactory} from "../../../contracts/managers/fee/FeeFactory.sol";

contract FluidInstadappStakingUSDCClaimRewards is Test {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant CHAINLINK_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address public constant F_TOKEN = 0x1A996cb54bb95462040408C06122D45D6Cdb6096; // deposit / withdraw
    address public constant FLUID_LENDING_STAKING_REWARDS = 0x48f89d731C5e3b5BeE8235162FC2C639Ba62DB7d; // stake / exit
    address public constant PRICE_ORACLE_MIDDLEWARE_USD = 0x85a3Ee1688eE8D320eDF4024fB67734Fa8492cF4;

    Erc4626SupplyFuse public erc4626SupplyFuse;
    FluidInstadappStakingSupplyFuse public fluidInstadappStakingSupplyFuse;

    uint256 private constant ERROR_DELTA = 100;
    address private admin = address(this);

    address private _priceOracleMiddlewareProxy;
    address private _plasmaVault;
    address private _accessManager;
    address private _claimRewardsManager;
    address private _claimFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 245117371);
        _init();
    }

    function _init() private {
        _setupPriceOracle();
        _createAccessManager();
        _createPlasmaVault();
        _createClaimRewardsManager();
        _setupPlasmaVault();
        _createClaimFuse();
        _addClaimFuseToClaimRewardsManager();
        _initAccessManager();
    }

    function _createPlasmaVault() private {
        address[] memory alphas = new address[](1);
        alphas[0] = address(this);
        _plasmaVault = address(
            new PlasmaVault(
                PlasmaVaultInitData({
                    assetName: "TEST PLASMA VAULT",
                    assetSymbol: "TPLASMA",
                    underlyingToken: USDC,
                    priceOracleMiddleware: _priceOracleMiddlewareProxy,
                    marketSubstratesConfigs: _setupMarketConfigs(),
                    fuses: _setupFuses(),
                    balanceFuses: _setupBalanceFuses(),
                    feeConfig: _setupFeeConfig(),
                    accessManager: _accessManager,
                    plasmaVaultBase: address(new PlasmaVaultBase()),
                    totalSupplyCap: type(uint256).max,
                    withdrawManager: address(0)
                })
            )
        );
    }

    function _setupPlasmaVault() private {
        vm.prank(admin);
        PlasmaVaultGovernance(_plasmaVault).setRewardsClaimManagerAddress(_claimRewardsManager);
    }

    function _initAccessManager() private {
        IporFusionAccessManager accessManager = IporFusionAccessManager(_accessManager);
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
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: _claimRewardsManager,
                withdrawManager: address(0),
                feeManager: address(0)
            })
        });

        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        accessManager.initialize(initializationData);
    }

    function _createClaimFuse() private {
        _claimFuse = address(new FluidInstadappClaimFuse(IporFusionMarkets.FLUID_INSTADAPP_STAKING));
    }

    function _addClaimFuseToClaimRewardsManager() private {
        address[] memory fuses = new address[](1);
        fuses[0] = _claimFuse;
        RewardsClaimManager(_claimRewardsManager).addRewardFuses(fuses);
    }

    function _dealAssets(address account_, uint256 amount_) private {
        vm.prank(0x47c031236e19d024b42f8AE6780E44A573170703);
        ERC20(USDC).transfer(account_, amount_);
    }

    function _createAccessManager() private {
        _accessManager = address(new IporFusionAccessManager(admin, 0));
    }

    function _createClaimRewardsManager() private {
        _claimRewardsManager = address(new RewardsClaimManager(_accessManager, _plasmaVault));
    }

    function _setupPriceOracle() private {
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC;

        vm.startPrank(admin);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x0000000000000000000000000000000000000348);

        _priceOracleMiddlewareProxy = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", admin))
        );

        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC;

        PriceOracleMiddleware(_priceOracleMiddlewareProxy).setAssetsPricesSources(assets, sources);
        vm.stopPrank();
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfig(0, 0, 0, 0, address(new FeeFactory()), address(0), address(0));
    }

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](2);
        bytes32[] memory assetsPoolUsdc = new bytes32[](1);
        assetsPoolUsdc[0] = PlasmaVaultConfigLib.addressToBytes32(F_TOKEN);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.FLUID_INSTADAPP_POOL, assetsPoolUsdc);

        bytes32[] memory assetsStakingUsdc = new bytes32[](1);
        assetsStakingUsdc[0] = PlasmaVaultConfigLib.addressToBytes32(FLUID_LENDING_STAKING_REWARDS);
        marketConfigs[1] = MarketSubstratesConfig(IporFusionMarkets.FLUID_INSTADAPP_STAKING, assetsStakingUsdc);
    }

    function _setupFuses() private returns (address[] memory) {
        erc4626SupplyFuse = new Erc4626SupplyFuse(IporFusionMarkets.FLUID_INSTADAPP_POOL);
        fluidInstadappStakingSupplyFuse = new FluidInstadappStakingSupplyFuse(
            IporFusionMarkets.FLUID_INSTADAPP_STAKING
        );

        address[] memory fuses = new address[](2);
        fuses[0] = address(erc4626SupplyFuse);
        fuses[1] = address(fluidInstadappStakingSupplyFuse);
        return fuses;
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        ERC4626BalanceFuse erc4626BalanceFuse = new ERC4626BalanceFuse(IporFusionMarkets.FLUID_INSTADAPP_POOL);

        FluidInstadappStakingBalanceFuse fluidInstadappStakingBalanceFuse = new FluidInstadappStakingBalanceFuse(
            IporFusionMarkets.FLUID_INSTADAPP_STAKING
        );

        balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(IporFusionMarkets.FLUID_INSTADAPP_POOL, address(erc4626BalanceFuse));

        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarkets.FLUID_INSTADAPP_STAKING,
            address(fluidInstadappStakingBalanceFuse)
        );
    }

    function _getEnterFuseData(uint256 amount_) private view returns (bytes[] memory data) {
        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: F_TOKEN,
            vaultAssetAmount: amount_
        });
        FluidInstadappStakingSupplyFuseEnterData memory enterDataStaking = FluidInstadappStakingSupplyFuseEnterData({
            stakingPool: FLUID_LENDING_STAKING_REWARDS,
            fluidTokenAmount: amount_
        });
        data = new bytes[](2);
        data[0] = abi.encode(enterData);
        data[1] = abi.encode(enterDataStaking);
    }

    function testT() external {
        address userOne = address(this);
        uint256 depositAmount = 10_000e6;
        _dealAssets(userOne, depositAmount);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        Erc4626SupplyFuseEnterData memory erc4626SupplyFuseEnterData = Erc4626SupplyFuseEnterData({
            vault: F_TOKEN,
            vaultAssetAmount: depositAmount
        });
        FluidInstadappStakingSupplyFuseEnterData
            memory fluidInstadappStakingSupplyFuseEnterData = FluidInstadappStakingSupplyFuseEnterData({
                stakingPool: FLUID_LENDING_STAKING_REWARDS,
                fluidTokenAmount: depositAmount
            });

        FuseAction[] memory enterCalls = new FuseAction[](2);
        enterCalls[0] = FuseAction(
            address(erc4626SupplyFuse),
            abi.encodeWithSignature("enter((address,uint256))", erc4626SupplyFuseEnterData)
        );
        enterCalls[1] = FuseAction(
            address(fluidInstadappStakingSupplyFuse),
            abi.encodeWithSignature("enter((uint256,address))", fluidInstadappStakingSupplyFuseEnterData)
        );

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.FLUID_INSTADAPP_STAKING;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.FLUID_INSTADAPP_POOL;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        PlasmaVaultGovernance(_plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);

        PlasmaVault(_plasmaVault).execute(enterCalls);

        vm.warp(block.timestamp + 100 days);

        uint256 stakingBalanceBefore = IFluidLendingStakingRewards(FLUID_LENDING_STAKING_REWARDS).earned(_plasmaVault);

        address rewardsToken = IFluidLendingStakingRewards(FLUID_LENDING_STAKING_REWARDS).rewardsToken();
        uint256 rewardsClaimManagerRewardsBalanceBefore = ERC20(rewardsToken).balanceOf(_claimRewardsManager);

        // when
        FuseAction[] memory rewardsClaimCalls = new FuseAction[](1);
        rewardsClaimCalls[0] = FuseAction(_claimFuse, abi.encodeWithSignature("claim()"));

        RewardsClaimManager(_claimRewardsManager).claimRewards(rewardsClaimCalls);

        uint256 stakingBalanceAfter = IFluidLendingStakingRewards(FLUID_LENDING_STAKING_REWARDS).earned(_plasmaVault);
        uint256 rewardsClaimManagerRewardsBalanceAfter = ERC20(rewardsToken).balanceOf(_claimRewardsManager);

        uint256 thisBalanceBeforeTransfer = ERC20(rewardsToken).balanceOf(address(this));

        RewardsClaimManager(_claimRewardsManager).transfer(
            rewardsToken,
            address(this),
            rewardsClaimManagerRewardsBalanceAfter
        );

        uint256 thisBalanceAfterTransfer = ERC20(rewardsToken).balanceOf(address(this));

        // then

        assertApproxEqAbs(stakingBalanceBefore, 77287149242680700470, ERROR_DELTA, "stakingBalanceBefore");
        assertApproxEqAbs(stakingBalanceAfter, 0, ERROR_DELTA, "stakingBalanceAfter");
        assertApproxEqAbs(
            rewardsClaimManagerRewardsBalanceBefore,
            0,
            ERROR_DELTA,
            "rewardsClaimManagerRewardsBalanceBefore"
        );
        assertApproxEqAbs(
            rewardsClaimManagerRewardsBalanceAfter,
            77287149242680700470,
            ERROR_DELTA,
            "rewardsClaimManagerRewardsBalanceAfter"
        );
        assertApproxEqAbs(thisBalanceBeforeTransfer, 0, ERROR_DELTA, "thisBalanceBeforeTransfer");
        assertApproxEqAbs(thisBalanceAfterTransfer, 77287149242680700470, ERROR_DELTA, "thisBalanceAfterTransfer");
    }
}
