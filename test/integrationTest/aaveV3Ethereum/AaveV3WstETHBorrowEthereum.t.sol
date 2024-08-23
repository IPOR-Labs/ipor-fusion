// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BorrowTest} from "../supplyFuseTemplate/BorrowTests.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData, AaveV3SupplyFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BorrowFuse, AaveV3BorrowFuseEnterData, AaveV3BorrowFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3BorrowFuse.sol";
import {PlasmaVault, FuseAction, MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {AaveV3BalanceFuse} from "../../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../../contracts/priceOracle/IPriceOracleMiddleware.sol";

contract AaveV3WstEthBorrowEthereum is BorrowTest {
    address private constant W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address private constant CHAINLINK_ETH = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant AAVE_POOL_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
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
        assets = new address[](1);
        sources = new address[](1);
        assets[0] = W_ETH;
        sources[0] = CHAINLINK_ETH;
    }

    function setupMarketConfigs() public override returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory assets = new bytes32[](2);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(W_ETH);
        assets[1] = PlasmaVaultConfigLib.addressToBytes32(WST_ETH);
        marketConfigs[0] = MarketSubstratesConfig(getMarketId(), assets);
    }

    function setupFuses() public override {
        AaveV3SupplyFuse fuseSupplyLoc = new AaveV3SupplyFuse(getMarketId(), AAVE_POOL, AAVE_POOL_DATA_PROVIDER);
        AaveV3BorrowFuse fuseBorrowLoc = new AaveV3BorrowFuse(getMarketId(), AAVE_POOL);
        fuses = new address[](2);
        fuses[0] = address(fuseSupplyLoc);
        fuses[1] = address(fuseBorrowLoc);
    }

    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        AaveV3BalanceFuse aaveV3Balances = new AaveV3BalanceFuse(
            getMarketId(),
            AAVE_PRICE_ORACLE,
            AAVE_POOL_DATA_PROVIDER
        );

        balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(getMarketId(), address(aaveV3Balances));
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

    function testShouldEnterBorrow() public {
        //given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        FuseAction[] memory calls = new FuseAction[](2);

        bytes memory enterSupplyFuseData = getEnterFuseData(depositAmount, new bytes32[](0))[0];
        address supplyFuse = fuses[0];
        address borrowFuse = fuses[1];

        calls[0] = FuseAction(supplyFuse, abi.encodeWithSignature("enter(bytes)", enterSupplyFuseData));

        bytes memory enterBorrowFuseData = getEnterFuseData(borrowAmount, new bytes32[](0))[1];
        calls[1] = FuseAction(borrowFuse, abi.encodeWithSignature("enter(bytes)", enterBorrowFuseData));

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();

        uint256 priceBorrowAsset = IPriceOracleMiddleware(AAVE_PRICE_ORACLE).getAssetPrice(borrowAsset) * 10 ** 18;
        uint256 priceDepositAsset = IPriceOracleMiddleware(priceOracle).getAssetPrice(asset) * 10 ** 18;

        uint256 vaultBalanceInUnderlying = (((depositAmount * priceDepositAsset) /
            10 ** 18 -
            (borrowAmount * priceBorrowAsset) /
            10 ** 18) * 10 ** 18) / priceDepositAsset;

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

    function testShouldExitBorrowRepay() public {
        //given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(getMarketId());

        FuseAction[] memory calls = new FuseAction[](2);

        bytes memory enterSupplyFuseData = getEnterFuseData(depositAmount, new bytes32[](0))[0];

        calls[0] = FuseAction(
            fuses[0], /// @dev supply fuse
            abi.encodeWithSignature("enter(bytes)", enterSupplyFuseData)
        );

        bytes memory enterBorrowFuseData = getEnterFuseData(borrowAmount, new bytes32[](0))[1];

        calls[1] = FuseAction(
            fuses[1], /// @dev borrow fuse
            abi.encodeWithSignature("enter(bytes)", enterBorrowFuseData)
        );

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        FuseAction[] memory exitCalls = new FuseAction[](1);

        bytes[] memory exitBorrowFuseData;

        (, exitBorrowFuseData) = getExitFuseData(borrowAmount, new bytes32[](0));

        exitCalls[0] = FuseAction(
            fuses[1], /// @dev borrow fuse
            abi.encodeWithSignature("exit(bytes)", exitBorrowFuseData[1])
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
