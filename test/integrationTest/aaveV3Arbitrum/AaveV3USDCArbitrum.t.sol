// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {ERC20} from "@fusion/@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SupplyTest} from "../supplyFuseTemplate/SupplyTests.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData, AaveV3SupplyFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {AaveV3BalanceFuse} from "../../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";

contract AaveV3USDCArbitrum is SupplyTest {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant CHAINLINK_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    uint256 public constant MARKET_ID = 1;
    address public constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public constant AAVE_POOL_DATA_PROVIDER = 0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654;
    address public constant AAVE_PRICE_ORACLE = 0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 202220653);
        init();
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
        marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        marketConfigs[0] = MarketSubstratesConfig(MARKET_ID, assets);
    }

    function setupFuses() public override {
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(MARKET_ID, AAVE_POOL, AAVE_POOL_DATA_PROVIDER);
        fuses = new address[](1);
        fuses[0] = address(fuse);
    }

    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        AaveV3BalanceFuse aaveV3Balances = new AaveV3BalanceFuse(MARKET_ID, AAVE_PRICE_ORACLE, AAVE_POOL_DATA_PROVIDER);

        balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(MARKET_ID, address(aaveV3Balances));
    }

    function getEnterFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (bytes memory data) {
        AaveV3SupplyFuseEnterData memory enterData = AaveV3SupplyFuseEnterData({
            asset: asset,
            amount: amount_,
            userEModeCategoryId: 300
        });
        data = abi.encode(enterData);
    }

    function getExitFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (bytes memory data) {
        AaveV3SupplyFuseExitData memory enterData = AaveV3SupplyFuseExitData({asset: asset, amount: amount_});
        data = abi.encode(enterData);
    }
}
