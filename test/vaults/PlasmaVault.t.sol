// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVault, FeeConfig, FuseAction, MarketBalanceFuseConfig, MarketSubstratesConfig, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData, AaveV3SupplyFuseExitData} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {CompoundV3BalanceFuse} from "../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {CompoundV3SupplyFuse, CompoundV3SupplyFuseEnterData, CompoundV3SupplyFuseExitData} from "../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IAavePoolDataProvider} from "../../contracts/fuses/aave_v3/ext/IAavePoolDataProvider.sol";
import {DoNothingFuse} from "../fuses/DoNothingFuse.sol";
import {PriceOracleMiddleware} from "../../contracts/priceOracle/PriceOracleMiddleware.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IporFusionAccessManager} from "../../contracts/managers/IporFusionAccessManager.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";

contract PlasmaVaultTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @dev Aave Price Oracle mainnet address where base currency is USD
    address public constant ETHEREUM_AAVE_PRICE_ORACLE_MAINNET = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
    address public constant ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3 = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;

    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    uint256 public constant AAVE_V3_MARKET_ID = 1;

    address public constant COMET_V3_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    uint256 public constant COMPOUND_V3_MARKET_ID = 2;

    IAavePoolDataProvider public constant AAVE_POOL_DATA_PROVIDER =
        IAavePoolDataProvider(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);

    address public atomist = address(this);

    string public assetName;
    string public assetSymbol;
    address public underlyingToken;
    address[] public alphas;
    address public alpha;
    uint256 public amount;

    address public userOne;

    PriceOracleMiddleware public priceOracleMiddlewareProxy;
    UsersToRoles public usersToRoles;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        userOne = address(0x777);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(
            0x0000000000000000000000000000000000000348,
            8,
            0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf
        );

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
    }

    function testShouldExecuteSimpleCase() public {
        //given
        assetName = "IPOR Fusion DAI";
        assetSymbol = "ipfDAI";
        underlyingToken = DAI;
        alphas = new address[](1);

        alpha = address(0x1);
        alphas[0] = alpha;

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        FuseAction[] memory calls = new FuseAction[](1);

        amount = 100 * 1e18;

        deal(DAI, address(plasmaVault), amount);

        calls[0] = FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: DAI, amount: amount, userEModeCategoryId: 1e18}))
            )
        );

        //when
        vm.prank(alpha);
        plasmaVault.execute(calls);

        //then
        /// @dev if is here then it means that the transaction was successful
        assertTrue(true);
    }

    function testShouldExecuteTwoSupplyFuses() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);

        alpha = address(0x1);
        alphas[0] = alpha;

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
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
        marketConfigs[1] = MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        FuseAction[] memory calls = new FuseAction[](2);

        amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(plasmaVault), 2 * amount);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: amount, userEModeCategoryId: 1e6}))
            )
        );

        calls[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuseEnterData({asset: USDC, amount: amount}))
            )
        );

        //when
        vm.prank(alpha);
        plasmaVault.execute(calls);

        //then
        /// @dev if is here then it means that the transaction was successful
        assertTrue(true);
    }

    function testShouldUpdateBalanceWhenOneFuse() public {
        //given
        assetName = "IPOR Fusion DAI";
        assetSymbol = "ipfDAI";
        underlyingToken = DAI;
        alphas = new address[](1);

        alpha = address(0x1);
        alphas[0] = alpha;

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        FuseAction[] memory calls = new FuseAction[](1);

        amount = 100 * 1e18;

        deal(DAI, address(plasmaVault), amount);

        calls[0] = FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: DAI, amount: amount, userEModeCategoryId: 1e18}))
            )
        );

        (address aTokenAddress, , ) = AAVE_POOL_DATA_PROVIDER.getReserveTokensAddresses(DAI);

        //when
        vm.prank(alpha);
        plasmaVault.execute(calls);

        //then
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 vaultTotalAssetsInMarket = plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID);

        assertTrue(
            ERC20(aTokenAddress).balanceOf(address(plasmaVault)) == amount,
            "aToken balance should be increased by amount"
        );

        assertGt(vaultTotalAssetsAfter, 99e18, "Vault total assets should be increased by amount");
        assertEq(
            vaultTotalAssetsAfter,
            vaultTotalAssetsInMarket,
            "Vault total assets should be equal to total assets in market"
        );
    }

    function testShouldUpdateBalanceWhenExecuteTwoSupplyFuses() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);

        alpha = address(0x1);
        alphas[0] = alpha;

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
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
        marketConfigs[1] = MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);
        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );
        setupRoles(plasmaVault, accessManager);

        FuseAction[] memory calls = new FuseAction[](2);

        amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(plasmaVault), 2 * amount);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: amount, userEModeCategoryId: 1e6}))
            )
        );

        calls[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuseEnterData({asset: USDC, amount: amount}))
            )
        );

        //when
        vm.prank(alpha);
        plasmaVault.execute(calls);

        //then
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();

        assertGt(
            vaultTotalAssetsAfter,
            199 * 10 ** plasmaVault.decimals(),
            "Vault total assets should be increased by amount"
        );
    }

    function testShouldIncreaseValueOfSharesAndNotChangeNumberOfSharesWhenTouchedMarket() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
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
        DoNothingFuse doNothingFuseAaveV3 = new DoNothingFuse(AAVE_V3_MARKET_ID);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(doNothingFuseAaveV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );
        setupRoles(plasmaVault, accessManager);

        amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 2 * amount);

        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(2 * amount, userOne);

        FuseAction[] memory calls = new FuseAction[](1);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: amount, userEModeCategoryId: 1e6}))
            )
        );

        /// @dev first call
        vm.prank(alpha);
        plasmaVault.execute(calls);

        uint256 userSharesBefore = plasmaVault.balanceOf(userOne);
        uint256 userAssetsBefore = plasmaVault.convertToAssets(userSharesBefore);

        /// @dev artificial time forward
        vm.warp(block.timestamp + 100 days);

        FuseAction[] memory callsSecond = new FuseAction[](1);

        /// @dev do nothing only touch the market
        callsSecond[0] = FuseAction(
            address(doNothingFuseAaveV3),
            abi.encodeWithSignature("enter(bytes)", abi.encode(DoNothingFuse.DoNothingFuseEnterData({asset: USDC})))
        );

        //when
        /// @dev second call
        vm.prank(alpha);
        plasmaVault.execute(callsSecond);

        //then
        uint256 userSharesAfter = plasmaVault.balanceOf(userOne);
        uint256 userAssetsAfter = plasmaVault.convertToAssets(userSharesAfter);

        assertEq(userSharesBefore, userSharesAfter, "User shares before and after should be equal");
        assertGt(
            userAssetsAfter,
            userAssetsBefore + 2 * 10 ** plasmaVault.decimals(),
            "User assets after should be greater than user assets before"
        );
    }

    function testShouldNOTIncreaseValueOfSharesAndAmountOfSharesWhenNotTouchedMarket() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
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
        marketConfigs[1] = MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        DoNothingFuse doNothingFuseCompoundV3 = new DoNothingFuse(COMPOUND_V3_MARKET_ID);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(doNothingFuseCompoundV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 2 * amount);

        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(2 * amount, userOne);

        FuseAction[] memory calls = new FuseAction[](1);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: amount, userEModeCategoryId: 0}))
            )
        );

        /// @dev first call
        vm.prank(alpha);
        plasmaVault.execute(calls);

        uint256 userSharesBefore = plasmaVault.balanceOf(userOne);
        uint256 userAssetsBefore = plasmaVault.convertToAssets(userSharesBefore);

        vm.warp(block.timestamp + 1000 days);

        FuseAction[] memory callsSecond = new FuseAction[](1);

        callsSecond[0] = FuseAction(
            address(doNothingFuseCompoundV3),
            abi.encodeWithSignature("enter(bytes)", abi.encode(DoNothingFuse.DoNothingFuseEnterData({asset: USDC})))
        );

        //when
        /// @dev second call
        vm.prank(alpha);
        plasmaVault.execute(callsSecond);

        //then
        uint256 userSharesAfter = plasmaVault.balanceOf(userOne);
        uint256 userAssetsAfter = plasmaVault.convertToAssets(userSharesAfter);

        assertEq(userSharesBefore, userSharesAfter, "User shares before and after should be equal");
        assertEq(userAssetsAfter, userAssetsBefore, "User assets before and after should be equal");
    }

    function testShouldExitFromAaveV3SupplyFuse() public {
        //given
        assetName = "IPOR Fusion DAI";
        assetSymbol = "ipfDAI";
        underlyingToken = DAI;
        alphas = new address[](1);

        alpha = address(0x1);
        alphas[0] = alpha;

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );
        setupRoles(plasmaVault, accessManager);

        FuseAction[] memory calls = new FuseAction[](1);

        amount = 100 * 1e18;

        deal(DAI, address(plasmaVault), amount);

        calls[0] = FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: DAI, amount: amount, userEModeCategoryId: 1e18}))
            )
        );

        vm.prank(alpha);
        plasmaVault.execute(calls);

        FuseAction[] memory callsSecond = new FuseAction[](1);

        callsSecond[0] = FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature("exit(bytes)", abi.encode(AaveV3SupplyFuseExitData({asset: DAI, amount: amount})))
        );

        uint256 totalAssetsInMarketBefore = plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID);

        vm.warp(block.timestamp + 100 days);

        //when
        vm.prank(alpha);
        plasmaVault.execute(callsSecond);

        //then
        uint256 totalAssetsInMarketAfter = plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID);
        assertGt(
            totalAssetsInMarketBefore,
            totalAssetsInMarketAfter,
            "Total assets in market should be decreased by amount"
        );
    }

    function testShouldExitFromTwoMarketsAaveV3SupplyAndCompoundV3Supply() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);

        alpha = address(0x1);
        alphas[0] = alpha;

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
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
        marketConfigs[1] = MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );
        setupRoles(plasmaVault, accessManager);

        FuseAction[] memory calls = new FuseAction[](2);

        amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(plasmaVault), 2 * amount);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: amount, userEModeCategoryId: 1e6}))
            )
        );

        calls[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuseEnterData({asset: USDC, amount: amount}))
            )
        );

        vm.prank(alpha);
        plasmaVault.execute(calls);

        FuseAction[] memory callsSecond = new FuseAction[](2);

        callsSecond[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature("exit(bytes)", abi.encode(AaveV3SupplyFuseExitData({asset: USDC, amount: amount})))
        );

        callsSecond[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "exit(bytes)",
                abi.encode(CompoundV3SupplyFuseExitData({asset: USDC, amount: amount}))
            )
        );

        uint256 totalAssetsInMarketBefore = plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID);
        uint256 totalAssetsInMarketBeforeCompound = plasmaVault.totalAssetsInMarket(COMPOUND_V3_MARKET_ID);

        vm.warp(block.timestamp + 1 seconds);

        //when
        vm.prank(alpha);
        plasmaVault.execute(callsSecond);

        //then
        uint256 totalAssetsInMarketAfter = plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID);
        uint256 totalAssetsInMarketAfterCompound = plasmaVault.totalAssetsInMarket(COMPOUND_V3_MARKET_ID);

        assertGt(
            totalAssetsInMarketBefore,
            totalAssetsInMarketAfter,
            "Total assets in market should be decreased by amount"
        );

        assertGt(
            totalAssetsInMarketBeforeCompound,
            totalAssetsInMarketAfterCompound,
            "Total assets in market should be decreased by amount"
        );
    }

    function createAccessManager(UsersToRoles memory usersToRoles) public returns (IporFusionAccessManager) {
        if (usersToRoles.superAdmin == address(0)) {
            usersToRoles.superAdmin = atomist;
            usersToRoles.atomist = atomist;
            address[] memory alphas = new address[](1);
            alphas[0] = alpha;
            usersToRoles.alphas = alphas;
        }
        return RoleLib.createAccessManager(usersToRoles, vm);
    }

    function setupRoles(PlasmaVault plasmaVault, IporFusionAccessManager accessManager) public {
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager);
    }
}
