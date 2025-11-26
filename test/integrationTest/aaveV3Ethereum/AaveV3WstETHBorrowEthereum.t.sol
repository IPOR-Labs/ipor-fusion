// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AaveV3BalanceFuse} from "../../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {AaveV3BorrowFuse, AaveV3BorrowFuseEnterData, AaveV3BorrowFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3BorrowFuse.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData, AaveV3SupplyFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {IAavePriceOracle} from "../../../contracts/fuses/aave_v3/ext/IAavePriceOracle.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {WstETHPriceFeedEthereum} from "../../../contracts/price_oracle/price_feed/chains/ethereum/WstETHPriceFeedEthereum.sol";
import {PlasmaVault, FuseAction, MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {BorrowTest} from "../supplyFuseTemplate/BorrowTests.sol";

/// @title Aave V3 WstETH Borrow Integration Test for Ethereum
/// @author IPOR Labs
/// @notice Test contract for Aave V3 WstETH Borrowing functionality on Ethereum
contract AaveV3WstEthBorrowEthereum is BorrowTest {
    address private constant W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address private constant CHAINLINK_ETH = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    /// @notice The address of the Aave V3 Pool Addresses Provider on Ethereum
    address public constant ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    /// @notice The address of the Aave Price Oracle
    address public constant AAVE_PRICE_ORACLE = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;

    uint256 internal depositAmount = 2e18;
    uint256 internal borrowAmount = 1e18;

    /// @notice Setup function for the test
    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20518066);
        setupBorrowAsset();
        init();
    }

    /// @notice Setup asset for the test
    function setupAsset() public override {
        asset = W_ETH;
    }

    /// @notice Setup borrow asset for the test
    function setupBorrowAsset() public override {
        borrowAsset = WST_ETH;
    }

    /// @notice Deal assets to an account
    /// @param account_ The address of the account
    /// @param amount_ The amount of assets to deal
    function dealAssets(address account_, uint256 amount_) public override {
        vm.prank(0xF04a5cC80B1E94C69B48f5ee68a08CD2F09A7c3E);
        ERC20(asset).transfer(account_, amount_);
    }

    /// @notice Setup price oracle for the test
    /// @return assets The addresses of the assets
    /// @return sources The addresses of the price sources
    function setupPriceOracle() public override returns (address[] memory assets, address[] memory sources) {
        assets = new address[](2);
        sources = new address[](2);
        assets[0] = W_ETH;
        sources[0] = CHAINLINK_ETH;

        assets[1] = WST_ETH;
        sources[1] = address(new WstETHPriceFeedEthereum());
    }

    /// @notice Setup market configurations
    /// @return marketConfigs The market configurations
    function setupMarketConfigs() public view override returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory assets = new bytes32[](2);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(W_ETH);
        assets[1] = PlasmaVaultConfigLib.addressToBytes32(WST_ETH);
        marketConfigs[0] = MarketSubstratesConfig(getMarketId(), assets);
    }

    /// @notice Setup market configs with ERC20 balance fuse for testing ERC20 balance tracking
    /// @return marketConfigs The market configurations
    function setupMarketConfigsWithErc20Balance() public view returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](2);
        bytes32[] memory assets = new bytes32[](2);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(W_ETH);
        assets[1] = PlasmaVaultConfigLib.addressToBytes32(WST_ETH);
        marketConfigs[0] = MarketSubstratesConfig(getMarketId(), assets);

        bytes32[] memory assets2 = new bytes32[](1);
        assets2[0] = PlasmaVaultConfigLib.addressToBytes32(WST_ETH);
        marketConfigs[1] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, assets2);
    }

    /// @notice Setup fuses for the test
    function setupFuses() public override {
        AaveV3SupplyFuse fuseSupplyLoc = new AaveV3SupplyFuse(getMarketId(), ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        AaveV3BorrowFuse fuseBorrowLoc = new AaveV3BorrowFuse(getMarketId(), ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        TransientStorageSetInputsFuse fuseSetInputsLoc = new TransientStorageSetInputsFuse();
        fuses = new address[](3);
        fuses[0] = address(fuseSupplyLoc);
        fuses[1] = address(fuseBorrowLoc);
        fuses[2] = address(fuseSetInputsLoc);
    }

    /// @notice Setup balance fuses
    /// @return balanceFuses The balance fuse configurations
    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        AaveV3BalanceFuse aaveV3Balances = new AaveV3BalanceFuse(
            getMarketId(),
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );

        balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(getMarketId(), address(aaveV3Balances));
    }

    /// @notice Setup balance fuses with ERC20 balance fuse for testing ERC20 balance tracking
    /// @return balanceFuses The balance fuse configurations
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

    /// @notice Setup dependency balance graphs with ERC20 balance fuse for testing ERC20 balance tracking
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

    /// @notice Get enter fuse data
    /// @param amount_ The amount to enter
    /// @param data_ The additional data
    /// @return data The enter fuse data
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

    /// @notice Get exit fuse data
    /// @param amount_ The amount to exit
    /// @param data_ The additional data
    /// @return fusesSetup The fuses setup
    /// @return data The exit fuse data
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

    /// @notice Test should enter borrow and ensure ERC20 balance is not taken into account
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

    /// @notice Test should enter borrow and ensure ERC20 balance is taken into account
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

    /// @notice Test should exit borrow and repay
    function testShouldExitBorrowRepay() public {
        // solhint-disable-line function-max-lines
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

    /// @notice Test that constructor reverts when initialized with zero address
    function testShouldRevertWhenInitializingWithZeroAddress() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new AaveV3BorrowFuse(getMarketId(), address(0));
    }

    /// @notice Test that enter function returns early (no-op) when amount is zero.
    /// @dev If this was not the case, a revert would occur because borrowing without collateral is not allowed in Aave.
    function testShouldReturnWhenEnteringWithZeroAmount() public {
        // given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        AaveV3BorrowFuseEnterData memory enterBorrowData = AaveV3BorrowFuseEnterData({asset: borrowAsset, amount: 0});

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(fuses[1], abi.encodeWithSignature("enter((address,uint256))", enterBorrowData));

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        // then
        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
    }

    /// @notice Test that enter function reverts when asset is not supported
    function testShouldRevertWhenEnteringWithUnsupportedAsset() public {
        // given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        address unsupportedAsset = address(0x123);
        AaveV3BorrowFuseEnterData memory enterBorrowData = AaveV3BorrowFuseEnterData({
            asset: unsupportedAsset,
            amount: 100
        });

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(fuses[1], abi.encodeWithSignature("enter((address,uint256))", enterBorrowData));

        // when
        vm.prank(alpha);
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV3BorrowFuse.AaveV3BorrowFuseUnsupportedAsset.selector,
                "enter",
                unsupportedAsset
            )
        );
        PlasmaVault(plasmaVault).execute(calls);
    }

    /// @notice Test that exit function returns early (no-op) when amount is zero
    function testShouldReturnWhenExitingWithZeroAmount() public {
        // given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        AaveV3BorrowFuseExitData memory exitBorrowData = AaveV3BorrowFuseExitData({asset: borrowAsset, amount: 0});

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(fuses[1], abi.encodeWithSignature("exit((address,uint256))", exitBorrowData));

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        // then
        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
    }

    /// @notice Test that exit function reverts when asset is not supported
    function testShouldRevertWhenExitingWithUnsupportedAsset() public {
        // given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        address unsupportedAsset = address(0x123);
        AaveV3BorrowFuseExitData memory exitBorrowData = AaveV3BorrowFuseExitData({
            asset: unsupportedAsset,
            amount: 100
        });

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(fuses[1], abi.encodeWithSignature("exit((address,uint256))", exitBorrowData));

        // when
        vm.prank(alpha);
        vm.expectRevert(
            abi.encodeWithSelector(AaveV3BorrowFuse.AaveV3BorrowFuseUnsupportedAsset.selector, "exit", unsupportedAsset)
        );
        PlasmaVault(plasmaVault).execute(calls);
    }

    /// @notice Test should enter borrow using transient storage
    function testShouldEnterBorrowUsingTransientStorage() public {
        // solhint-disable-line function-max-lines
        //given
        initPlasmaVaultCustom(setupMarketConfigsWithErc20Balance(), setupBalanceFusesWithErc20Balance());
        initApprove();

        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        FuseAction[] memory calls = new FuseAction[](3);

        AaveV3SupplyFuseEnterData memory enterSupplyData = AaveV3SupplyFuseEnterData({
            asset: asset,
            amount: depositAmount,
            userEModeCategoryId: 300
        });

        // 1. Supply
        calls[0] = FuseAction(fuses[0], abi.encodeWithSignature("enter((address,uint256,uint256))", enterSupplyData));

        // 2. Prepare Transient Inputs
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(borrowAsset);
        inputs[1] = TypeConversionLib.toBytes32(borrowAmount);

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = fuses[1]; // AaveV3BorrowFuse
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        calls[1] = FuseAction(fuses[2], abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData));

        // 3. Enter Transient
        calls[2] = FuseAction(fuses[1], abi.encodeWithSignature("enterTransient()"));

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();

        //when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        //then
        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();

        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
        // Assets should decrease slightly due to slippage/fees or stay approx same (borrow doesn't change net asset value immediately except fees)
        // Logic copied from standard enter test:
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 1e17, "totalAssets");
    }

    /// @notice Test should exit borrow using transient storage
    function testShouldExitBorrowUsingTransientStorage() public {
        // solhint-disable-line function-max-lines
        //given
        initPlasmaVaultCustom(setupMarketConfigsWithErc20Balance(), setupBalanceFusesWithErc20Balance());
        initApprove();

        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        // Setup: Standard Enter first
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
        calls[0] = FuseAction(fuses[0], abi.encodeWithSignature("enter((address,uint256,uint256))", enterSupplyData));
        calls[1] = FuseAction(fuses[1], abi.encodeWithSignature("enter((address,uint256))", enterBorrowData));

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        // Prepare Exit Transient
        FuseAction[] memory exitCalls = new FuseAction[](2);

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(borrowAsset);
        inputs[1] = TypeConversionLib.toBytes32(borrowAmount);

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = fuses[1]; // AaveV3BorrowFuse
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        exitCalls[0] = FuseAction(
            fuses[2], // TransientStorageSetInputsFuse
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );

        exitCalls[1] = FuseAction(
            fuses[1], // AaveV3BorrowFuse
            abi.encodeWithSignature("exitTransient()")
        );

        //when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(exitCalls);

        //then
        uint256 assetsInMarketAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(getMarketId());

        assertEq(assetsInMarketAfter, depositAmount, "assetsInMarketAfter");
    }

    /// @notice Test only transient storage fuse inputs setting
    function testTransientStorageFuseOnly() public {
        //given
        initPlasmaVaultCustom(setupMarketConfigsWithErc20Balance(), setupBalanceFusesWithErc20Balance());
        initApprove();

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(borrowAsset);
        inputs[1] = TypeConversionLib.toBytes32(borrowAmount);

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = fuses[1];
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(fuses[2], abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData));

        //when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);
    }

    /// @notice Test that enterTransient returns early when amount is zero
    function testShouldReturnWhenEnteringTransientWithZeroAmount() public {
        // given
        initPlasmaVaultCustom(setupMarketConfigsWithErc20Balance(), setupBalanceFusesWithErc20Balance());
        initApprove();

        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(borrowAsset);
        inputs[1] = TypeConversionLib.toBytes32(uint256(0)); // Zero amount

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = fuses[1];
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(fuses[2], abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData));
        calls[1] = FuseAction(fuses[1], abi.encodeWithSignature("enterTransient()"));

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        // then
        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
    }

    /// @notice Test that enterTransient reverts when asset is not supported
    function testShouldRevertWhenEnteringTransientWithUnsupportedAsset() public {
        // given
        initPlasmaVaultCustom(setupMarketConfigsWithErc20Balance(), setupBalanceFusesWithErc20Balance());
        initApprove();

        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        address unsupportedAsset = address(0x123);
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(unsupportedAsset);
        inputs[1] = TypeConversionLib.toBytes32(uint256(100));

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = fuses[1];
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(fuses[2], abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData));
        calls[1] = FuseAction(fuses[1], abi.encodeWithSignature("enterTransient()"));

        // when
        vm.prank(alpha);
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV3BorrowFuse.AaveV3BorrowFuseUnsupportedAsset.selector,
                "enter",
                unsupportedAsset
            )
        );
        PlasmaVault(plasmaVault).execute(calls);
    }

    /// @notice Test that exitTransient returns early when amount is zero
    function testShouldReturnWhenExitingTransientWithZeroAmount() public {
        // given
        initPlasmaVaultCustom(setupMarketConfigsWithErc20Balance(), setupBalanceFusesWithErc20Balance());
        initApprove();

        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(borrowAsset);
        inputs[1] = TypeConversionLib.toBytes32(uint256(0));

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = fuses[1];
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(fuses[2], abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData));
        calls[1] = FuseAction(fuses[1], abi.encodeWithSignature("exitTransient()"));

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        // then
        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
    }

    /// @notice Test that exitTransient reverts when asset is not supported
    function testShouldRevertWhenExitingTransientWithUnsupportedAsset() public {
        // given
        initPlasmaVaultCustom(setupMarketConfigsWithErc20Balance(), setupBalanceFusesWithErc20Balance());
        initApprove();

        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        address unsupportedAsset = address(0x123);
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(unsupportedAsset);
        inputs[1] = TypeConversionLib.toBytes32(uint256(100));

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = fuses[1];
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(fuses[2], abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData));
        calls[1] = FuseAction(fuses[1], abi.encodeWithSignature("exitTransient()"));

        // when
        vm.prank(alpha);
        vm.expectRevert(
            abi.encodeWithSelector(AaveV3BorrowFuse.AaveV3BorrowFuseUnsupportedAsset.selector, "exit", unsupportedAsset)
        );
        PlasmaVault(plasmaVault).execute(calls);
    }
}
