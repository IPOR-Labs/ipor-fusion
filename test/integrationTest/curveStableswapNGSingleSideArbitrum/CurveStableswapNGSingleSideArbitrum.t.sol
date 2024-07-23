// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {IUSDM} from "./IUSDM.sol";
import {SupplyTest} from "../supplyFuseTemplate/SupplyTests.sol";
import {CurveStableswapNGSingleSideSupplyFuse, CurveStableswapNGSingleSideSupplyFuseEnterData, CurveStableswapNGSingleSideSupplyFuseExitData} from "../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideSupplyFuse.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {CurveStableswapNGSingleSideBalanceFuse} from "../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideBalanceFuse.sol";
import {USDMPriceFeed} from "./../../../contracts/priceOracle/priceFeed/USDMPriceFeed.sol";
import {ICurveStableswapNG} from "./../../../contracts/fuses/curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {IChronicle, IToll} from "./../../../contracts/priceOracle/IChronicle.sol";

contract CurveStableswapNGSingleSideArbitrum is SupplyTest {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant USDM = 0x59D9356E565Ab3A36dD77763Fc0d87fEaf85508C;
    address public constant CURVE_STABLESWAP_NG_POOL = 0x4bD135524897333bec344e50ddD85126554E58B4;
    uint256 public constant MARKET_ID = 1;
    address public constant USDM_MINT_ROLE = 0x48AEB395FB0E4ff8433e9f2fa6E0579838d33B62;
    address public constant USD = 0x0000000000000000000000000000000000000348;
    address public constant WUSDM = 0x57F5E098CaD7A3D1Eed53991D4d66C45C9AF7812;
    address public constant CHRONICLE_ADMIN = 0x39aBD7819E5632Fa06D2ECBba45Dca5c90687EE3;
    address public constant WUSDM_USD_ORACLE_FEED = 0xdC6720c996Fad27256c7fd6E0a271e2A4687eF18;
    IChronicle public constant CHRONICLE = IChronicle(WUSDM_USD_ORACLE_FEED);
    USDMPriceFeed public priceFeed;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 227567789);
        priceFeed = new USDMPriceFeed();
        // price feed admin needs to whitelist the caller address for reading the price
        vm.prank(CHRONICLE_ADMIN);
        IToll(address(CHRONICLE)).kiss(address(priceFeed));
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
        sources[0] = address(priceFeed);
    }

    function setupMarketConfigs() public override returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory lpTokens = new bytes32[](1);
        lpTokens[0] = PlasmaVaultConfigLib.addressToBytes32(CURVE_STABLESWAP_NG_POOL);
        marketConfigs[0] = MarketSubstratesConfig(MARKET_ID, lpTokens);
    }

    function setupFuses() public override {
        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(MARKET_ID);
        fuses = new address[](1);
        fuses[0] = address(fuse);
    }

    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        CurveStableswapNGSingleSideBalanceFuse curveStableswapNGSingleSideBalanceFuse = new CurveStableswapNGSingleSideBalanceFuse(
                MARKET_ID,
                address(priceOracle)
            );
        balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(MARKET_ID, address(curveStableswapNGSingleSideBalanceFuse));
    }

    function getEnterFuseData(
        uint256 amount_,
        bytes32[] memory data_
    ) public view virtual override returns (bytes[] memory data) {
        CurveStableswapNGSingleSideSupplyFuseEnterData
            memory enterData = CurveStableswapNGSingleSideSupplyFuseEnterData({
                curveStableswapNG: ICurveStableswapNG(CURVE_STABLESWAP_NG_POOL),
                asset: asset,
                amount: amount_,
                minMintAmount: 0
            });
        data = abi.encode(enterData);
    }

    function getExitFuseData(
        uint256 amount_, // LP token amount to burn
        bytes32[] memory data_
    ) public view virtual override returns (bytes[] memory data) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = amount_;
        uint256 burnAmount = ICurveStableswapNG(CURVE_STABLESWAP_NG_POOL).calc_token_amount(amounts, false);
        CurveStableswapNGSingleSideSupplyFuseExitData memory exitData = CurveStableswapNGSingleSideSupplyFuseExitData({
            curveStableswapNG: ICurveStableswapNG(CURVE_STABLESWAP_NG_POOL),
            burnAmount: burnAmount,
            asset: asset,
            minReceived: 0
        });
        data = abi.encode(exitData);
    }
}
