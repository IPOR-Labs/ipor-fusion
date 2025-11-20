// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BorrowTest} from "../supplyFuseTemplate/BorrowTests.sol";
import {IAavePriceOracle} from "../../../contracts/fuses/aave_v3/ext/IAavePriceOracle.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData, AaveV3SupplyFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BorrowFuse, AaveV3BorrowFuseEnterData, AaveV3BorrowFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3BorrowFuse.sol";
import {PlasmaVault, FuseAction, MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {AaveV3BalanceFuse} from "../../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {WstETHPriceFeedEthereum} from "../../../contracts/price_oracle/price_feed/chains/ethereum/WstETHPriceFeedEthereum.sol";

contract AaveV3WstEthBorrowEthereum is BorrowTest {
    address private constant W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address private constant CHAINLINK_ETH = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address public constant AAVE_PRICE_ORACLE = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;

    uint256 internal depositAmount = 2e18;
    uint256 internal borrowAmount = 1e18;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20518066);
        setupBorrowAsset();
        init();
    }

    function setupAsset() public override {
        asset = W_ETH;
    }

    function setupBorrowAsset() public override {
        borrowAsset = WST_ETH;
    }

    function dealAssets(address account_, uint256 amount_) public override {
        vm.prank(0xF04a5cC80B1E94C69B48f5ee68a08CD2F09A7c3E);
        ERC20(asset).transfer(account_, amount_);
    }

    function setupPriceOracle() public override returns (address[] memory assets, address[] memory sources) {
        assets = new address[](2);
        sources = new address[](2);
        assets[0] = W_ETH;
        sources[0] = CHAINLINK_ETH;

        assets[1] = WST_ETH;
        sources[1] = address(new WstETHPriceFeedEthereum());
    }

    function setupMarketConfigs() public override returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory assets = new bytes32[](2);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(W_ETH);
        assets[1] = PlasmaVaultConfigLib.addressToBytes32(WST_ETH);
        marketConfigs[0] = MarketSubstratesConfig(getMarketId(), assets);
    }

    function setupMarketConfigsWithErc20Balance() public returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](2);
        bytes32[] memory assets = new bytes32[](2);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(W_ETH);
        assets[1] = PlasmaVaultConfigLib.addressToBytes32(WST_ETH);
        marketConfigs[0] = MarketSubstratesConfig(getMarketId(), assets);

        bytes32[] memory assets2 = new bytes32[](1);
        assets2[0] = PlasmaVaultConfigLib.addressToBytes32(WST_ETH);
        marketConfigs[1] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, assets2);
    }

    function setupFuses() public override {
        AaveV3SupplyFuse fuseSupplyLoc = new AaveV3SupplyFuse(getMarketId(), ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        AaveV3BorrowFuse fuseBorrowLoc = new AaveV3BorrowFuse(getMarketId(), ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        fuses = new address[](2);
        fuses[0] = address(fuseSupplyLoc);
        fuses[1] = address(fuseBorrowLoc);
    }

    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        AaveV3BalanceFuse aaveV3Balances = new AaveV3BalanceFuse(
            getMarketId(),
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );

        balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(getMarketId(), address(aaveV3Balances));
    }

    function setupBalanceFusesWithErc20Balance() public returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        AaveV3BalanceFuse aaveV3Balances = new AaveV3BalanceFuse(
            getMarketId(),
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );

        ERC20BalanceFuse erc20Balances = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(getMarketId(), address(aaveV3Balances));

        balanceFuses[1] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20Balances));
    }

    function setupDependencyBalanceGraphsWithErc20BalanceFuse() public {
        uint256[] memory marketIds = new uint256[](1);

        marketIds[0] = IporFusionMarkets.AAVE_V3;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependencies = new uint256[][](1);
        dependencies[0] = dependence;

        vm.prank(accounts[0]);
        PlasmaVaultGovernance(plasmaVault).updateDependencyBalanceGraphs(marketIds, dependencies);
    }

    function getEnterFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (bytes[] memory data) {
        AaveV3SupplyFuseEnterData memory enterSupplyData = AaveV3SupplyFuseEnterData({
            asset: asset,
            amount: amount_,
            userEModeCategoryId: 300
        });

        AaveV3BorrowFuseEnterData memory enterBorrowData = AaveV3BorrowFuseEnterData({
            asset: borrowAsset,
            amount: amount_
        });

        data = new bytes[](2);

        data[0] = abi.encode(enterSupplyData);
        data[1] = abi.encode(enterBorrowData);
    }

    function getExitFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (address[] memory fusesSetup, bytes[] memory data) {
        AaveV3SupplyFuseExitData memory exitSupplyData = AaveV3SupplyFuseExitData({asset: asset, amount: amount_});

        AaveV3BorrowFuseExitData memory exitBorrowData = AaveV3BorrowFuseExitData({
            asset: borrowAsset,
            amount: amount_
        });

        data = new bytes[](2);

        data[0] = abi.encode(exitSupplyData);
        data[1] = abi.encode(exitBorrowData);

        fusesSetup = fuses;
    }

    function testShouldEnterBorrowErc20BalanceNotTakenIntoAccount() public {
        //given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        FuseAction[] memory calls = new FuseAction[](2);

        AaveV3SupplyFuseEnterData memory enterSupplyData = AaveV3SupplyFuseEnterData({
            asset: asset,
            amount: depositAmount,
            userEModeCategoryId: 300
        });

        AaveV3BorrowFuseEnterData memory enterBorrowData = AaveV3BorrowFuseEnterData({
            asset: borrowAsset,
            amount: borrowAmount
        });

        address supplyFuse = fuses[0];
        address borrowFuse = fuses[1];

        calls[0] = FuseAction(supplyFuse, abi.encodeWithSignature("enter((address,uint256,uint256))", enterSupplyData));
        calls[1] = FuseAction(borrowFuse, abi.encodeWithSignature("enter((address,uint256))", enterBorrowData));

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();

        uint256 borrowAssetPrice = IAavePriceOracle(AAVE_PRICE_ORACLE).getAssetPrice(borrowAsset);
        (uint256 assetPrice, ) = IPriceOracleMiddleware(priceOracle).getAssetPrice(asset);

        // Adjust borrowAssetPrice from 8 decimals to 18 decimals
        borrowAssetPrice = borrowAssetPrice * 1e10;

        // Calculate vault balance in underlying
        uint256 vaultBalanceInUnderlying = ((depositAmount * assetPrice - borrowAmount * borrowAssetPrice)) /
            assetPrice;

        //when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        //then
        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(getMarketId());

        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
        assertApproxEqAbs(totalAssetsAfter, vaultBalanceInUnderlying, ERROR_DELTA, "totalAssets");
        assertApproxEqAbs(assetsInMarketAfter, vaultBalanceInUnderlying, ERROR_DELTA, "assetsInMarket");
    }

    function testShouldEnterBorrowErc20BalanceISTakenIntoAccount() public {
        //given
        initPlasmaVaultCustom(setupMarketConfigsWithErc20Balance(), setupBalanceFusesWithErc20Balance());
        initApprove();
        setupDependencyBalanceGraphsWithErc20BalanceFuse();

        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        FuseAction[] memory calls = new FuseAction[](2);

        AaveV3SupplyFuseEnterData memory enterSupplyData = AaveV3SupplyFuseEnterData({
            asset: asset,
            amount: depositAmount,
            userEModeCategoryId: 300
        });

        AaveV3BorrowFuseEnterData memory enterBorrowData = AaveV3BorrowFuseEnterData({
            asset: borrowAsset,
            amount: borrowAmount
        });

        address supplyFuse = fuses[0];
        address borrowFuse = fuses[1];

        calls[0] = FuseAction(supplyFuse, abi.encodeWithSignature("enter((address,uint256,uint256))", enterSupplyData));
        calls[1] = FuseAction(borrowFuse, abi.encodeWithSignature("enter((address,uint256))", enterBorrowData));

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();

        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(getMarketId());

        //when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        //then
        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(getMarketId());

        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
        assertGt(totalAssetsAfter, totalAssetsBefore - 1e16, "totalAssets");
        assertEq(assetsInMarketBefore, 0, "assetsInMarketBefore");
        assertGt(assetsInMarketAfter, 0, "assetsInMarketAfter");
    }

    function testShouldExitBorrowRepay() public {
        //given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(getMarketId());

        FuseAction[] memory calls = new FuseAction[](2);

        AaveV3SupplyFuseEnterData memory enterSupplyData = AaveV3SupplyFuseEnterData({
            asset: asset,
            amount: depositAmount,
            userEModeCategoryId: 300
        });

        AaveV3BorrowFuseEnterData memory enterBorrowData = AaveV3BorrowFuseEnterData({
            asset: borrowAsset,
            amount: borrowAmount
        });

        address supplyFuse = fuses[0];
        address borrowFuse = fuses[1];

        calls[0] = FuseAction(supplyFuse, abi.encodeWithSignature("enter((address,uint256,uint256))", enterSupplyData));
        calls[1] = FuseAction(borrowFuse, abi.encodeWithSignature("enter((address,uint256))", enterBorrowData));

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        FuseAction[] memory exitCalls = new FuseAction[](1);

        AaveV3BorrowFuseExitData memory exitBorrowData = AaveV3BorrowFuseExitData({
            asset: borrowAsset,
            amount: borrowAmount
        });

        exitCalls[0] = FuseAction(
            fuses[1], /// @dev borrow fuse
            abi.encodeWithSignature("exit((address,uint256))", exitBorrowData)
        );

        //when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(exitCalls);

        //then
        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(getMarketId());

        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
        assertEq(totalAssetsAfter, totalAssetsBefore, "totalAssetsBefore");

        assertEq(assetsInMarketAfter, depositAmount, "assetsInMarketBefore");
        assertEq(assetsInMarketBefore, 0, "assetsInMarketAfter");
    }
}
