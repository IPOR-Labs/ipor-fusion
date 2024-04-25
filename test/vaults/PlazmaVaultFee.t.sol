// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlazmaVaultFactory} from "../../contracts/vaults/PlazmaVaultFactory.sol";
import {PlazmaVault} from "../../contracts/vaults/PlazmaVault.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData, AaveV3SupplyFuseExitData} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {CompoundV3BalanceFuse} from "../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {CompoundV3SupplyFuse, CompoundV3SupplyFuseEnterData, CompoundV3SupplyFuseExitData} from "../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {PlazmaVaultConfigLib} from "../../contracts/libraries/PlazmaVaultConfigLib.sol";
import {IAavePoolDataProvider} from "../../contracts/fuses/aave_v3/IAavePoolDataProvider.sol";
import {IporPriceOracle} from "../../contracts/priceOracle/IporPriceOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PlazmaVaultLib} from "../../contracts/libraries/PlazmaVaultLib.sol";

interface AavePool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

contract PlazmaVaultFeeTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @dev Aave Price Oracle mainnet address where base currency is USD
    address public constant ETHEREUM_AAVE_PRICE_ORACLE_MAINNET = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
    address public constant ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3 = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    PlazmaVaultFactory internal vaultFactory;

    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    uint256 public constant AAVE_V3_MARKET_ID = 1;

    address public constant COMET_V3_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    uint256 public constant COMPOUND_V3_MARKET_ID = 2;

    IAavePoolDataProvider public constant AAVE_POOL_DATA_PROVIDER =
        IAavePoolDataProvider(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);

    address public owner = address(this);

    string public assetName;
    string public assetSymbol;
    address public underlyingToken;
    address[] public alphas;
    address public alpha;
    uint256 public amount;

    address public userOne;
    address public userTwo;
    address public dao;
    uint256 public performanceFeeInPercentage;

    IporPriceOracle private iporPriceOracleProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        vaultFactory = new PlazmaVaultFactory(owner);

        userOne = address(0x777);
        userTwo = address(0x888);
        dao = address(0x999);

        IporPriceOracle implementation = new IporPriceOracle(
            0x0000000000000000000000000000000000000348,
            8,
            0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf
        );

        iporPriceOracleProxy = IporPriceOracle(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
    }

    function testShouldExitFromTwoMarketsAaveV3SupplyAndCompoundV3SupplyAndCalculatePerformanceFee() public {
        //given
        performanceFeeInPercentage = 5;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);

        alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlazmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        /// @dev Market Compound V3
        marketConfigs[1] = PlazmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](2);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = PlazmaVault.MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses,
                    dao,
                    performanceFeeInPercentage
                )
            )
        );

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](2);

        amount = 100 * 1e6;

        /// @dev user one deposit
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plazmaVault), 2 * amount);

        vm.prank(userOne);
        plazmaVault.deposit(amount, userOne);

        /// @dev user two deposit
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plazmaVault), 2 * amount);

        vm.prank(userTwo);
        plazmaVault.deposit(amount, userTwo);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: amount, userEModeCategoryId: 1e6}))
            )
        );

        calls[1] = PlazmaVault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuseEnterData({asset: USDC, amount: amount}))
            )
        );

        vm.prank(alpha);
        plazmaVault.execute(calls);

        PlazmaVault.FuseAction[] memory callsSecond = new PlazmaVault.FuseAction[](2);

        callsSecond[0] = PlazmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature("exit(bytes)", abi.encode(AaveV3SupplyFuseExitData({asset: USDC, amount: amount})))
        );

        callsSecond[1] = PlazmaVault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "exit(bytes)",
                abi.encode(CompoundV3SupplyFuseExitData({asset: USDC, amount: amount}))
            )
        );

        vm.warp(block.timestamp + 365 days);

        //when
        vm.prank(alpha);
        plazmaVault.execute(callsSecond);

        //then
        uint256 userOneBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(userTwo));
        uint256 daoBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(dao));

        assertEq(userOneBalanceOfAssets, 108536113);
        assertEq(userTwoBalanceOfAssets, 108536113);
        assertEq(daoBalanceOfAssets, 894656);
    }

    function testShouldExitFromTwoMarketsAaveV3SupplyAndCompoundV3SupplyAndCalculatePerformanceFeeTimeIsNotChanged()
        public
    {
        //given
        performanceFeeInPercentage = 5;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);

        alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlazmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        /// @dev Market Compound V3
        marketConfigs[1] = PlazmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](2);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = PlazmaVault.MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses,
                    dao,
                    performanceFeeInPercentage
                )
            )
        );

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](2);

        amount = 100 * 1e6;

        /// @dev user one deposit
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plazmaVault), 2 * amount);

        vm.prank(userOne);
        plazmaVault.deposit(amount, userOne);

        /// @dev user two deposit
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plazmaVault), 2 * amount);

        vm.prank(userTwo);
        plazmaVault.deposit(amount, userTwo);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: amount, userEModeCategoryId: 1e6}))
            )
        );

        calls[1] = PlazmaVault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuseEnterData({asset: USDC, amount: amount}))
            )
        );

        vm.prank(alpha);
        plazmaVault.execute(calls);

        PlazmaVault.FuseAction[] memory callsSecond = new PlazmaVault.FuseAction[](2);

        callsSecond[0] = PlazmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature("exit(bytes)", abi.encode(AaveV3SupplyFuseExitData({asset: USDC, amount: amount})))
        );

        callsSecond[1] = PlazmaVault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "exit(bytes)",
                abi.encode(CompoundV3SupplyFuseExitData({asset: USDC, amount: amount}))
            )
        );

        //        vm.warp(block.timestamp + 365 days);

        //when
        vm.prank(alpha);
        plazmaVault.execute(callsSecond);

        //then
        uint256 userOneBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(userTwo));
        uint256 daoBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(dao));

        assertEq(userOneBalanceOfAssets, 99999999);
        assertEq(userTwoBalanceOfAssets, 99999999);
        assertEq(daoBalanceOfAssets, 0);
    }

    function testShouldInstantWithdrawRequiredExitFromTwoMarketsAaveV3CompoundV3AndCalculatePerformanceFee() public {
        //given
        performanceFeeInPercentage = 5;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlazmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        /// @dev Market Compound V3
        marketConfigs[1] = PlazmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](2);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = PlazmaVault.MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses,
                    dao,
                    performanceFeeInPercentage
                )
            )
        );

        amount = 100 * 1e6;

        //user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plazmaVault), 2 * amount);
        vm.prank(userOne);
        plazmaVault.deposit(amount, userOne);

        //user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plazmaVault), 2 * amount);
        vm.prank(userTwo);
        plazmaVault.deposit(amount, userTwo);
        uint256 userTwoBalanceOfSharesBefore = plazmaVault.balanceOf(userTwo);

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](2);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6, userEModeCategoryId: 1e6}))
            )
        );

        calls[1] = PlazmaVault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6}))
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plazmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        PlazmaVaultLib.InstantWithdrawalFusesParamsStruct[]
            memory instantWithdrawFuses = new PlazmaVaultLib.InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlazmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = PlazmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = PlazmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        plazmaVault.updateInstantWithdrawalFuses(instantWithdrawFuses);

        /// @dev move time to gather interest
        vm.warp(block.timestamp + 365 days);

        //when
        vm.prank(userOne);
        plazmaVault.withdraw(75 * 1e6, userOne, userOne);

        //then
        uint256 userTwoBalanceOfSharesAfter = plazmaVault.balanceOf(userTwo);
        uint256 userOneBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(userTwo));
        uint256 daoBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(dao));

        assertEq(userOneBalanceOfAssets, 28798996, "userOneBalanceOfAssets");
        assertEq(userTwoBalanceOfAssets, 103798996, "userTwoBalanceOfAssets");
        assertEq(daoBalanceOfAssets, 399085, "daoBalanceOfAssets");
        assertEq(userTwoBalanceOfSharesBefore, userTwoBalanceOfSharesAfter, "userTwoBalanceOfShares not changed");
    }

    function testShouldInstantWithdrawRequiredExitFromTwoMarketsAaveV3CompoundV3AndCalculatePerformanceFeeTimeIsNotChanged()
        public
    {
        //given
        performanceFeeInPercentage = 5;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlazmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        /// @dev Market Compound V3
        marketConfigs[1] = PlazmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](2);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = PlazmaVault.MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses,
                    dao,
                    performanceFeeInPercentage
                )
            )
        );

        amount = 100 * 1e6;

        //user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plazmaVault), 2 * amount);
        vm.prank(userOne);
        plazmaVault.deposit(amount, userOne);

        //user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plazmaVault), 2 * amount);
        vm.prank(userTwo);
        plazmaVault.deposit(amount, userTwo);
        uint256 userTwoBalanceOfSharesBefore = plazmaVault.balanceOf(userTwo);

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](2);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6, userEModeCategoryId: 1e6}))
            )
        );

        calls[1] = PlazmaVault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6}))
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plazmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        PlazmaVaultLib.InstantWithdrawalFusesParamsStruct[]
            memory instantWithdrawFuses = new PlazmaVaultLib.InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlazmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = PlazmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = PlazmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        plazmaVault.updateInstantWithdrawalFuses(instantWithdrawFuses);

        //when
        vm.prank(userOne);
        plazmaVault.withdraw(75 * 1e6, userOne, userOne);

        //then
        uint256 userTwoBalanceOfSharesAfter = plazmaVault.balanceOf(userTwo);
        uint256 userOneBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(userTwo));
        uint256 daoBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(dao));

        assertEq(userOneBalanceOfAssets, 24999998, "userOneBalanceOfAssets on plazma vault stayed 25 usd");
        assertEq(userTwoBalanceOfAssets, 99999999, "userTwoBalanceOfAssets on plazma vault stayed 100 usd");
        assertEq(daoBalanceOfAssets, 0, "daoBalanceOfAssets - no interest when time is not changed");
        assertEq(userTwoBalanceOfSharesBefore, userTwoBalanceOfSharesAfter, "userTwoBalanceOfShares not changed");
    }

    function testShouldInstantWithdrawNoTouchedMarketsAndCalculatePerformanceFeeTimeIsNotChanged() public {
        //given
        performanceFeeInPercentage = 5;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlazmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        /// @dev Market Compound V3
        marketConfigs[1] = PlazmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](2);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = PlazmaVault.MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses,
                    dao,
                    performanceFeeInPercentage
                )
            )
        );

        amount = 100 * 1e6;

        //user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plazmaVault), 2 * amount);
        vm.prank(userOne);
        plazmaVault.deposit(amount, userOne);

        //user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plazmaVault), 2 * amount);
        vm.prank(userTwo);
        plazmaVault.deposit(amount, userTwo);
        uint256 userTwoBalanceOfSharesBefore = plazmaVault.balanceOf(userTwo);

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](2);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6, userEModeCategoryId: 1e6}))
            )
        );

        calls[1] = PlazmaVault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6}))
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plazmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        PlazmaVaultLib.InstantWithdrawalFusesParamsStruct[]
            memory instantWithdrawFuses = new PlazmaVaultLib.InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlazmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = PlazmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = PlazmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        plazmaVault.updateInstantWithdrawalFuses(instantWithdrawFuses);

        //when
        vm.prank(userOne);
        plazmaVault.withdraw(75 * 1e6, userOne, userOne);

        //then
        uint256 userTwoBalanceOfSharesAfter = plazmaVault.balanceOf(userTwo);
        uint256 userOneBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(userTwo));
        uint256 daoBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(dao));

        assertEq(userOneBalanceOfAssets, 24999999, "userOneBalanceOfAssets on plazma vault stayed 25 usd");
        assertEq(userTwoBalanceOfAssets, 100000000, "userTwoBalanceOfAssets on plazma vault stayed 100 usd");
        assertEq(daoBalanceOfAssets, 0, "daoBalanceOfAssets - no interest when time is not changed");
        assertEq(userTwoBalanceOfSharesBefore, userTwoBalanceOfSharesAfter, "userTwoBalanceOfShares not changed");
    }

    function testShouldInstantWithdrawNoTouchedMarketsAndCalculatePerformanceFeeTimeChanged365days() public {
        //given
        performanceFeeInPercentage = 5;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlazmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        /// @dev Market Compound V3
        marketConfigs[1] = PlazmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](2);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = PlazmaVault.MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses,
                    dao,
                    performanceFeeInPercentage
                )
            )
        );

        amount = 100 * 1e6;

        //user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plazmaVault), 2 * amount);
        vm.prank(userOne);
        plazmaVault.deposit(amount, userOne);

        //user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plazmaVault), 2 * amount);
        vm.prank(userTwo);
        plazmaVault.deposit(amount, userTwo);
        uint256 userTwoBalanceOfSharesBefore = plazmaVault.balanceOf(userTwo);

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](2);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6, userEModeCategoryId: 1e6}))
            )
        );

        calls[1] = PlazmaVault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6}))
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plazmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        PlazmaVaultLib.InstantWithdrawalFusesParamsStruct[]
            memory instantWithdrawFuses = new PlazmaVaultLib.InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlazmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = PlazmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = PlazmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        plazmaVault.updateInstantWithdrawalFuses(instantWithdrawFuses);

        /// @dev move time to gather interest
        vm.warp(block.timestamp + 365 days);

        //when
        vm.prank(userOne);
        plazmaVault.withdraw(75 * 1e6, userOne, userOne);

        //then
        uint256 userTwoBalanceOfSharesAfter = plazmaVault.balanceOf(userTwo);
        uint256 userOneBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(userTwo));
        uint256 daoBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(dao));

        assertEq(userOneBalanceOfAssets, 24999999, "userOneBalanceOfAssets on plazma vault stayed 25 usd");
        assertEq(userTwoBalanceOfAssets, 100000000, "userTwoBalanceOfAssets on plazma vault stayed 100 usd");
        assertEq(daoBalanceOfAssets, 0, "daoBalanceOfAssets - no interest when time is not changed");
        assertEq(userTwoBalanceOfSharesBefore, userTwoBalanceOfSharesAfter, "userTwoBalanceOfShares not changed");
    }

    function testShouldRedeemExitFromOneMarketAaveV3AndCalculatePerformanceFeeTimeIsChanged() public {
        //given
        performanceFeeInPercentage = 5;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlazmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseAaveV3);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses,
                    dao,
                    performanceFeeInPercentage
                )
            )
        );

        amount = 100 * 1e6;

        //user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount + 5 * 1e6);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plazmaVault), 2 * amount);
        vm.prank(userOne);
        plazmaVault.deposit(amount, userOne);

        //user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plazmaVault), 2 * amount);
        vm.prank(userTwo);
        plazmaVault.deposit(amount, userTwo);
        uint256 userTwoBalanceOfSharesBefore = plazmaVault.balanceOf(userTwo);

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](1);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: 2 * amount, userEModeCategoryId: 1e6}))
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plazmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        PlazmaVaultLib.InstantWithdrawalFusesParamsStruct[]
            memory instantWithdrawFuses = new PlazmaVaultLib.InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlazmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = PlazmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        /// @dev configure order for instant withdraw
        plazmaVault.updateInstantWithdrawalFuses(instantWithdrawFuses);

        /// @dev move time to gather interest
        vm.warp(block.timestamp + 365 days);

        //when
        vm.prank(userOne);
        plazmaVault.redeem(70 * 1e6, userOne, userOne);

        //then
        uint256 userTwoBalanceOfSharesAfter = plazmaVault.balanceOf(userTwo);
        uint256 userOneBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(userTwo));
        uint256 daoBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(dao));

        assertEq(userOneBalanceOfAssets, 32279599, "userOneBalanceOfAssets on plazma vault");
        assertEq(userTwoBalanceOfAssets, 107598665, "userTwoBalanceOfAssets on plazma vault");
        assertEq(daoBalanceOfAssets, 796753, "daoBalanceOfAssets");
        assertEq(userTwoBalanceOfSharesBefore, userTwoBalanceOfSharesAfter, "userTwoBalanceOfShares not changed");
    }

    function testShouldRedeemExitFromOneMarketAaveV3AndCalculatePerformanceFeeTimeIsNOTChanged() public {
        //given
        performanceFeeInPercentage = 5;

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlazmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseAaveV3);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses,
                    dao,
                    performanceFeeInPercentage
                )
            )
        );

        amount = 100 * 1e6;

        //user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount + 5 * 1e6);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plazmaVault), 2 * amount);
        vm.prank(userOne);
        plazmaVault.deposit(amount, userOne);

        //user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plazmaVault), 2 * amount);
        vm.prank(userTwo);
        plazmaVault.deposit(amount, userTwo);
        uint256 userTwoBalanceOfSharesBefore = plazmaVault.balanceOf(userTwo);

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](1);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: 2 * amount, userEModeCategoryId: 1e6}))
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plazmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        PlazmaVaultLib.InstantWithdrawalFusesParamsStruct[]
            memory instantWithdrawFuses = new PlazmaVaultLib.InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlazmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = PlazmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        /// @dev configure order for instant withdraw
        plazmaVault.updateInstantWithdrawalFuses(instantWithdrawFuses);

        //when
        vm.prank(userOne);
        plazmaVault.redeem(70 * 1e6, userOne, userOne);

        //then
        uint256 userTwoBalanceOfSharesAfter = plazmaVault.balanceOf(userTwo);
        uint256 userOneBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(userOne));
        uint256 userTwoBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(userTwo));
        uint256 daoBalanceOfAssets = plazmaVault.convertToAssets(plazmaVault.balanceOf(dao));

        assertEq(userOneBalanceOfAssets, 30000000, "userOneBalanceOfAssets on plazma vault");
        assertEq(userTwoBalanceOfAssets, 100000000, "userTwoBalanceOfAssets on plazma vault");
        assertEq(daoBalanceOfAssets, 0, "daoBalanceOfAssets");
        assertEq(userTwoBalanceOfSharesBefore, userTwoBalanceOfSharesAfter, "userTwoBalanceOfShares not changed");
    }
}
