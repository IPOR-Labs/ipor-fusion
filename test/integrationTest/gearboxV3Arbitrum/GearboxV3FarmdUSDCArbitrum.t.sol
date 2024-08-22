// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SupplyTest} from "../supplyFuseTemplate/SupplyTests.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData, Erc4626SupplyFuseExitData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {ERC4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {IporFusionMarketsArbitrum} from "../../../contracts/libraries/IporFusionMarketsArbitrum.sol";
import {GearboxV3FarmdSupplyFuseExitData, GearboxV3FarmdSupplyFuseEnterData, GearboxV3FarmSupplyFuse} from "../../../contracts/fuses/gearbox_v3/GearboxV3FarmSupplyFuse.sol";
import {GearboxV3FarmBalanceFuse} from "../../../contracts/fuses/gearbox_v3/GearboxV3FarmBalanceFuse.sol";

contract GearboxV3FarmdUSDCArbitrum is SupplyTest {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant CHAINLINK_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address public constant D_USDC = 0x890A69EF363C9c7BdD5E36eb95Ceb569F63ACbF6;
    address public constant FARM_D_USDC = 0xD0181a36B0566a8645B7eECFf2148adE7Ecf2BE9;
    address public constant PRICE_ORACLE_MIDDLEWARE_USD = 0x85a3Ee1688eE8D320eDF4024fB67734Fa8492cF4;

    GearboxV3FarmSupplyFuse public gearboxV3FarmSupplyFuse;
    Erc4626SupplyFuse public gearboxV3DTokenFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 226213814);
        init();
    }

    function getMarketId() public view override returns (uint256) {
        return IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3;
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
        marketConfigs = new MarketSubstratesConfig[](2);
        bytes32[] memory assetsDUsdc = new bytes32[](1);
        assetsDUsdc[0] = PlasmaVaultConfigLib.addressToBytes32(D_USDC);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarketsArbitrum.GEARBOX_POOL_V3, assetsDUsdc);

        bytes32[] memory assetsFarmDUsdc = new bytes32[](1);
        assetsFarmDUsdc[0] = PlasmaVaultConfigLib.addressToBytes32(FARM_D_USDC);
        marketConfigs[1] = MarketSubstratesConfig(IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3, assetsFarmDUsdc);
    }

    function setupFuses() public override {
        gearboxV3DTokenFuse = new Erc4626SupplyFuse(IporFusionMarketsArbitrum.GEARBOX_POOL_V3);
        gearboxV3FarmSupplyFuse = new GearboxV3FarmSupplyFuse(IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3);
        fuses = new address[](2);
        fuses[0] = address(gearboxV3DTokenFuse);
        fuses[1] = address(gearboxV3FarmSupplyFuse);
    }

    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        ERC4626BalanceFuse gearboxV3Balances = new ERC4626BalanceFuse(IporFusionMarketsArbitrum.GEARBOX_POOL_V3);

        GearboxV3FarmBalanceFuse gearboxV3FarmdBalances = new GearboxV3FarmBalanceFuse(
            IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3
        );

        balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(
            IporFusionMarketsArbitrum.GEARBOX_POOL_V3,
            address(gearboxV3Balances)
        );

        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarketsArbitrum.GEARBOX_FARM_DTOKEN_V3,
            address(gearboxV3FarmdBalances)
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
        Erc4626SupplyFuseExitData memory exitData = Erc4626SupplyFuseExitData({
            vault: D_USDC,
            vaultAssetAmount: amount_
        });
        GearboxV3FarmdSupplyFuseExitData memory exitDataFarm = GearboxV3FarmdSupplyFuseExitData({
            farmdToken: FARM_D_USDC,
            dTokenAmount: amount_
        });
        data = new bytes[](2);
        data[1] = abi.encode(exitData);
        data[0] = abi.encode(exitDataFarm);

        fusesSetup = new address[](2);
        fusesSetup[0] = address(gearboxV3FarmSupplyFuse);
        fusesSetup[1] = address(gearboxV3DTokenFuse);
    }
}
