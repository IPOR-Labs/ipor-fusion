// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FuseAction, PlasmaVault, FeeConfig, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {ERC4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {IporFusionMarketsArbitrum} from "../../../contracts/libraries/IporFusionMarketsArbitrum.sol";
import {GearboxV3FarmdSupplyFuseEnterData, GearboxV3FarmSupplyFuse} from "../../../contracts/fuses/gearbox_v3/GearboxV3FarmSupplyFuse.sol";
import {GearboxV3FarmBalanceFuse} from "../../../contracts/fuses/gearbox_v3/GearboxV3FarmBalanceFuse.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/priceOracle/PriceOracleMiddleware.sol";
import {IporPlasmaVault} from "../../../contracts/vaults/IporPlasmaVault.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InitializationData} from "../../../contracts/managers/access/IporFusionAccessManagerInitializationLib.sol";
import {GearboxV3FarmDTokenClaimFuse} from "../../../contracts/rewards_fuses/gearbox_v3/GearboxV3FarmDTokenClaimFuse.sol";
import {IFarmingPool} from "../../../contracts/fuses/gearbox_v3/ext/IFarmingPool.sol";

contract GearboxV3FarmdUSDCClaimRewards is Test {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant CHAINLINK_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address public constant D_USDC = 0x890A69EF363C9c7BdD5E36eb95Ceb569F63ACbF6;
    address public constant FARM_D_USDC = 0xD0181a36B0566a8645B7eECFf2148adE7Ecf2BE9;
    address public constant PRICE_ORACLE_MIDDLEWARE_USD = 0x85a3Ee1688eE8D320eDF4024fB67734Fa8492cF4;

    GearboxV3FarmSupplyFuse public gearboxV3FarmSupplyFuse;
    Erc4626SupplyFuse public gearboxV3DTokenFuse;

    uint256 private constant ERROR_DELTA = 100;
    address private admin = address(this);

    address private _priceOracleMiddlewareProxy;
    address private _plasmaVault;
    address private _accessManager;
    address private _claimRewardsManager;
    address private _claimFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 236205212);
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
            new IporPlasmaVault(
                PlasmaVaultInitData({
                    assetName: "TEST PLASMA VAULT",
                    assetSymbol: "TPLASMA",
                    underlyingToken: USDC,
                    priceOracle: _priceOracleMiddlewareProxy,
                    alphas: alphas,
                    marketSubstratesConfigs: _setupMarketConfigs(),
                    fuses: _setupFuses(),
                    balanceFuses: _setupBalanceFuses(),
                    feeConfig: _setupFeeConfig(),
                    accessManager: _accessManager
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
                feeManager: address(this)
            })
        });

        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        accessManager.initialize(initializationData);
    }

    function _createClaimFuse() private {
        _claimFuse = address(new GearboxV3FarmDTokenClaimFuse(IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3));
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
        _accessManager = address(new IporFusionAccessManager(admin));
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

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(
            0x0000000000000000000000000000000000000348,
            8,
            address(0)
        );

        _priceOracleMiddlewareProxy = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", admin))
        );

        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC;

        PriceOracleMiddleware(_priceOracleMiddlewareProxy).setAssetsPricesSources(assets, sources);
        vm.stopPrank();
    }

    function _setupFeeConfig() private view returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfig({
            performanceFeeManager: address(this),
            performanceFeeInPercentage: 0,
            managementFeeManager: address(this),
            managementFeeInPercentage: 0
        });
    }

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](2);
        bytes32[] memory assetsDUsdc = new bytes32[](1);
        assetsDUsdc[0] = PlasmaVaultConfigLib.addressToBytes32(D_USDC);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarketsArbitrum.GEARBOX_POOL_V3, assetsDUsdc);

        bytes32[] memory assetsFarmDUsdc = new bytes32[](1);
        assetsFarmDUsdc[0] = PlasmaVaultConfigLib.addressToBytes32(FARM_D_USDC);
        marketConfigs[1] = MarketSubstratesConfig(IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3, assetsFarmDUsdc);
    }

    function _setupFuses() private returns (address[] memory) {
        gearboxV3DTokenFuse = new Erc4626SupplyFuse(IporFusionMarketsArbitrum.GEARBOX_POOL_V3);
        gearboxV3FarmSupplyFuse = new GearboxV3FarmSupplyFuse(IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3);

        address[] memory fuses = new address[](2);
        fuses[0] = address(gearboxV3DTokenFuse);
        fuses[1] = address(gearboxV3FarmSupplyFuse);
        return fuses;
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        ERC4626BalanceFuse gearboxV3Balances = new ERC4626BalanceFuse(
            IporFusionMarketsArbitrum.GEARBOX_POOL_V3,
            _priceOracleMiddlewareProxy
        );

        GearboxV3FarmBalanceFuse gearboxV3FarmdBalance = new GearboxV3FarmBalanceFuse(
            IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3
        );

        balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(
            IporFusionMarketsArbitrum.GEARBOX_POOL_V3,
            address(gearboxV3Balances)
        );

        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3,
            address(gearboxV3FarmdBalance)
        );
    }

    function _getEnterFuseData(uint256 amount_) private view returns (bytes[] memory data) {
        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({vault: D_USDC, amount: amount_});
        GearboxV3FarmdSupplyFuseEnterData memory enterDataFarm = GearboxV3FarmdSupplyFuseEnterData({
            farmdToken: FARM_D_USDC,
            dTokenAmount: amount_
        });
        data = new bytes[](2);
        data[0] = abi.encode(enterData);
        data[1] = abi.encode(enterDataFarm);
    }

    function testT() external {
        address userOne = address(this);
        uint256 depositAmount = 10_000e6;
        _dealAssets(userOne, depositAmount);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: D_USDC,
            amount: depositAmount
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
        enterCalls[0] = FuseAction(address(gearboxV3DTokenFuse), abi.encodeWithSignature("enter(bytes)", data[0]));
        enterCalls[1] = FuseAction(address(gearboxV3FarmSupplyFuse), abi.encodeWithSignature("enter(bytes)", data[1]));

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarketsArbitrum.GEARBOX_POOL_V3;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        PlasmaVaultGovernance(_plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);

        PlasmaVault(_plasmaVault).execute(enterCalls);

        vm.warp(block.timestamp + 100 days);

        uint256 farmBalanceBefore = IFarmingPool(FARM_D_USDC).farmed(_plasmaVault);

        address rewardsToken = IFarmingPool(FARM_D_USDC).rewardsToken();
        uint256 rewardsClaimManagerRewardsBalanceBefore = ERC20(rewardsToken).balanceOf(_claimRewardsManager);

        // when
        FuseAction[] memory rewardsClaimCalls = new FuseAction[](1);
        rewardsClaimCalls[0] = FuseAction(_claimFuse, abi.encodeWithSignature("claim()"));

        RewardsClaimManager(_claimRewardsManager).claimRewards(rewardsClaimCalls);

        uint256 farmBalanceAfter = IFarmingPool(FARM_D_USDC).farmed(_plasmaVault);
        uint256 rewardsClaimManagerRewardsBalanceAfter = ERC20(rewardsToken).balanceOf(_claimRewardsManager);

        uint256 thisBalanceBeforeTransfer = ERC20(rewardsToken).balanceOf(address(this));

        RewardsClaimManager(_claimRewardsManager).transfer(
            rewardsToken,
            address(this),
            rewardsClaimManagerRewardsBalanceAfter
        );

        uint256 thisBalanceAfterTransfer = ERC20(rewardsToken).balanceOf(address(this));

        // then

        assertApproxEqAbs(farmBalanceBefore, 74714022095617696698, ERROR_DELTA, "farmBalanceBefore");
        assertApproxEqAbs(farmBalanceAfter, 0, ERROR_DELTA, "farmBalanceAfter");
        assertApproxEqAbs(
            rewardsClaimManagerRewardsBalanceBefore,
            0,
            ERROR_DELTA,
            "rewardsClaimManagerRewardsBalanceBefore"
        );
        assertApproxEqAbs(
            rewardsClaimManagerRewardsBalanceAfter,
            74714022095617696698,
            ERROR_DELTA,
            "rewardsClaimManagerRewardsBalanceAfter"
        );
        assertApproxEqAbs(thisBalanceBeforeTransfer, 0, ERROR_DELTA, "thisBalanceBeforeTransfer");
        assertApproxEqAbs(thisBalanceAfterTransfer, 74714022095617696698, ERROR_DELTA, "thisBalanceAfterTransfer");
    }
}