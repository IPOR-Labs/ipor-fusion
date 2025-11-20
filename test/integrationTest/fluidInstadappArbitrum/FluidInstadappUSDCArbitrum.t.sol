// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SupplyTest} from "../supplyFuseTemplate/SupplyTests.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData, Erc4626SupplyFuseExitData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

contract FluidInstadappUSDCArbitrum is SupplyTest {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant CHAINLINK_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address public constant F_TOKEN = 0x1A996cb54bb95462040408C06122D45D6Cdb6096;
    address public constant FLUID_LENDING_STAKING_REWARDS = 0x48f89d731C5e3b5BeE8235162FC2C639Ba62DB7d; // stake / exit

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 233461793);
        init();
    }

    function getMarketId() public pure override returns (uint256) {
        return IporFusionMarkets.FLUID_INSTADAPP_POOL;
    }

    function setupAsset() public override {
        asset = USDC;
    }

    function dealAssets(address account_, uint256 amount_) public override {
        vm.prank(0x47c031236e19d024b42f8AE6780E44A573170703);
        ERC20(asset).transfer(account_, amount_);
    }

    function setupPriceOracle() public pure override returns (address[] memory assets, address[] memory sources) {
        assets = new address[](1);
        sources = new address[](1);
        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC;
    }

    function setupMarketConfigs() public pure override returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(F_TOKEN);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.FLUID_INSTADAPP_POOL, assets);
    }

    function setupFuses() public override {
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(IporFusionMarkets.FLUID_INSTADAPP_POOL);
        fuses = new address[](1);
        fuses[0] = address(fuse);
    }

    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        Erc4626BalanceFuse fluidInstadappBalances = new Erc4626BalanceFuse(IporFusionMarkets.FLUID_INSTADAPP_POOL);

        balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(
            IporFusionMarkets.FLUID_INSTADAPP_POOL,
            address(fluidInstadappBalances)
        );
    }

    function getEnterFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (bytes[] memory data) {
        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: F_TOKEN,
            vaultAssetAmount: amount_
        });
        data = new bytes[](1);
        data[0] = abi.encodeWithSignature("enter((address,uint256))", enterData);
    }

    function getExitFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (address[] memory fusesSetup, bytes[] memory data) {
        Erc4626SupplyFuseExitData memory exitData = Erc4626SupplyFuseExitData({
            vault: F_TOKEN,
            vaultAssetAmount: amount_
        });
        data = new bytes[](1);
        data[0] = abi.encodeWithSignature("exit((address,uint256))", exitData);
        fusesSetup = fuses;
    }
}
