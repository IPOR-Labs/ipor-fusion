// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SupplyTest} from "../supplyFuseTemplate/SupplyTests.sol";
import {console2} from "forge-std/Test.sol";
import {AaveV3SupplyFuse} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {PlazmaVault} from "../../../contracts/vaults/PlazmaVault.sol";
import "../../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";

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

    function testShouldWork() external {
        assertTrue(true, "It should work");
    }

    function setupAsset() public override {
        asset = USDC;
    }

    function dealAssets(address account_, uint256 amount_) public override {
        console2.log("dealAssets inside AaveV3USDCArbitrum");
        vm.prank(0x47c031236e19d024b42f8AE6780E44A573170703);
        ERC20(asset).transfer(account_, amount_);
        console2.log("dealAssets inside AaveV3USDCArbitrum");
    }

    function setupPriceOracle() public override returns (address[] memory assets, address[] memory sources) {
        assets = new address[](1);
        sources = new address[](1);
        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC;
    }

    function setupMarketConfigs() public override returns (PlazmaVault.MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new PlazmaVault.MarketSubstratesConfig[](1);
        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlazmaVaultConfigLib.addressToBytes32(USDC);
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(MARKET_ID, assets);
    }

    function setupFuses() public override returns (address[] memory fuses) {
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(MARKET_ID, AAVE_POOL, AAVE_POOL_DATA_PROVIDER);
        fuses = new address[](1);
        fuses[0] = address(fuse);
    }

    function setupBalanceFuses() public override returns (PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses) {
        AaveV3BalanceFuse aaveV3Balances = new AaveV3BalanceFuse(MARKET_ID, AAVE_PRICE_ORACLE, AAVE_POOL_DATA_PROVIDER);

        balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(MARKET_ID, address(aaveV3Balances));
    }
}
