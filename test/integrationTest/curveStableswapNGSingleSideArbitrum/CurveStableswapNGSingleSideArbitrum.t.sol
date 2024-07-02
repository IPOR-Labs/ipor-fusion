// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IUSDM} from "./IUSDM.sol";
import {SupplyTest} from "../supplyFuseTemplate/SupplyTests.sol";
import {CurveStableswapNGSingleSideSupplyFuse, CurveStableswapNGSingleSideSupplyFuseEnterData, CurveStableswapNGSingleSideSupplyFuseExitData} from "../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideSupplyFuse.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {CurveStableswapNGSingleSideBalanceFuse} from "../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideBalanceFuse.sol";
import {USDMPriceFeed} from "./../../../contracts/priceOracle/priceFeed/USDMPriceFeed.sol";
import {PriceOracleMock} from "../../fuses/curve_stableswap_ng/PriceOracleMock.sol";

contract CurveStableswapNGSingleSideArbitrum is SupplyTest {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant USDM = 0x59D9356E565Ab3A36dD77763Fc0d87fEaf85508C;
    address public constant CURVE_STABLESWAP_NG_POOL = 0x4bD135524897333bec344e50ddD85126554E58B4;
    uint256 public constant MARKET_ID = 1;
    address public constant USDM_MINT_ROLE = 0x48AEB395FB0E4ff8433e9f2fa6E0579838d33B62;
    address public constant USD = 0x0000000000000000000000000000000000000348;
    USDMPriceFeed public priceFeed;
    PriceOracleMock public priceOracleMock;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 227567789);
        priceFeed = new USDMPriceFeed();
        priceOracleMock = new PriceOracleMock(USD, 8);
        priceOracleMock.setPrice(USDM, 1e18);
        init();
    }

    function setupAsset() public override {
        asset = USDM;
    }

    function dealAssets(address account_, uint256 amount_) public override {
        vm.prank(USDM_MINT_ROLE); // deployer
        IUSDM(asset).mint(account_, amount_);
    }

    function setupPriceOracle() public override returns (address[] memory assets, address[] memory sources) {
        assets = new address[](1);
        sources = new address[](1);
        assets[0] = USDM;
        sources[0] = address(priceFeed); // USDM Price Feed hardcoded to 1
    }

    function setupMarketConfigs() public override returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory lpTokens = new bytes32[](1);
        lpTokens[0] = PlasmaVaultConfigLib.addressToBytes32(CURVE_STABLESWAP_NG_POOL);
        marketConfigs[0] = MarketSubstratesConfig(MARKET_ID, lpTokens);
    }

    function setupFuses() public override {
        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(
            MARKET_ID,
            CURVE_STABLESWAP_NG_POOL
        );
        fuses = new address[](1);
        fuses[0] = address(fuse);
    }

    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        CurveStableswapNGSingleSideBalanceFuse curveStableswapNGSingleSideBalanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
                MARKET_ID,
                address(priceOracleMock)
            );
        balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(MARKET_ID, address(curveStableswapNGSingleSideBalanceFuse));
    }

    function getEnterFuseData(
        uint256 amount_,
        //solhint-disable-next-line var
        bytes32[] memory data_
    ) public view virtual override returns (bytes memory data) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = amount_;
        CurveStableswapNGSingleSideSupplyFuseEnterData
            memory enterData = CurveStableswapNGSingleSideSupplyFuseEnterData({
                asset: asset,
                amounts: amounts,
                minMintAmount: 0
            });
        data = abi.encode(enterData);
    }

    function getExitFuseData(
        uint256 amount_, // LP token amount to burn
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (bytes memory data) {
        CurveStableswapNGSingleSideSupplyFuseExitData memory exitData = CurveStableswapNGSingleSideSupplyFuseExitData({
            burnAmount: amount_,
            asset: asset,
            minReceived: 0
        });
        data = abi.encode(exitData);
    }
}
