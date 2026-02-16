// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SupplyTest} from "../supplyFuseTemplate/SupplyTests.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData, Erc4626SupplyFuseExitData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

contract EulerV2SupplyWETHVault is SupplyTest {
    // eWETH-1
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant EULER_VAULT = 0xb3b36220fA7d12f7055dab5c9FD18E860e9a6bF8;
    address public constant CHAINLINK_WETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20626532);
        init();
    }

    function getMarketId() public view override returns (uint256) {
        return IporFusionMarkets.EULER_V2;
    }

    function setupAsset() public override {
        asset = WETH;
    }

    function dealAssets(address account_, uint256 amount_) public override {
        vm.prank(0xF04a5cC80B1E94C69B48f5ee68a08CD2F09A7c3E);
        ERC20(asset).transfer(account_, amount_);
    }

    function setupPriceOracle() public override returns (address[] memory assets, address[] memory sources) {
        assets = new address[](1);
        sources = new address[](1);
        assets[0] = WETH;
        sources[0] = CHAINLINK_WETH_USD;
    }

    function setupMarketConfigs() public override returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(EULER_VAULT);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.EULER_V2, assets);
    }

    function setupFuses() public override {
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(IporFusionMarkets.EULER_V2);
        fuses = new address[](1);
        fuses[0] = address(fuse);
    }

    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        Erc4626BalanceFuse eulerV2Balances = new Erc4626BalanceFuse(IporFusionMarkets.EULER_V2);

        balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(IporFusionMarkets.EULER_V2, address(eulerV2Balances));
    }

    function getEnterFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (bytes[] memory data) {
        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: EULER_VAULT,
            vaultAssetAmount: amount_,
            minSharesOut: 0
        });
        data = new bytes[](1);
        data[0] = abi.encodeWithSignature("enter((address,uint256,uint256))", enterData);
    }

    function getExitFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (address[] memory fusesSetup, bytes[] memory data) {
        Erc4626SupplyFuseExitData memory exitData = Erc4626SupplyFuseExitData({
            vault: EULER_VAULT,
            vaultAssetAmount: amount_,
            maxSharesBurned: 0
        });
        data = new bytes[](1);
        data[0] = abi.encodeWithSignature("exit((address,uint256,uint256))", exitData);
        fusesSetup = fuses;
    }
}
