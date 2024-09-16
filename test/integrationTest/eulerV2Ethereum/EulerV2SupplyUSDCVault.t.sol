// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SupplyTest} from "../supplyFuseTemplate/SupplyTests.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData, Erc4626SupplyFuseExitData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {ERC4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

contract EulerV2SupplyUSDCVault is SupplyTest {
    // eUSDC-1
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant EULER_VAULT = 0xB93d4928f39fBcd6C89a7DFbF0A867E6344561bE;
    address public constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20626532);
        init();
    }

    function getMarketId() public view override returns (uint256) {
        return IporFusionMarkets.EULER_V2;
    }

    function setupAsset() public override {
        asset = USDC;
    }

    function dealAssets(address account_, uint256 amount_) public override {
        vm.prank(0x4B16c5dE96EB2117bBE5fd171E4d203624B014aa);
        ERC20(asset).transfer(account_, amount_);
    }

    function setupPriceOracle() public override returns (address[] memory assets, address[] memory sources) {
        assets = new address[](1);
        sources = new address[](1);
        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC_USD;
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
        ERC4626BalanceFuse eulerV2Balances = new ERC4626BalanceFuse(IporFusionMarkets.EULER_V2);

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
            vault: EULER_VAULT,
            vaultAssetAmount: amount_
        });
        data = new bytes[](1);
        data[0] = abi.encodeWithSignature("exit((address,uint256))", exitData);
        fusesSetup = fuses;
    }
}
