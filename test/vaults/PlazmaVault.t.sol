// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlazmaVaultFactory} from "../../contracts/vaults/PlazmaVaultFactory.sol";
import {PlazmaVault} from "../../contracts/vaults/PlazmaVault.sol";
import {AaveV3SupplyFuse} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {CompoundV3BalanceFuse} from "../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {CompoundV3SupplyFuse} from "../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {MarketConfigurationLib} from "../../contracts/libraries/MarketConfigurationLib.sol";
import {IAavePoolDataProvider} from "../../contracts/fuses/aave_v3/IAavePoolDataProvider.sol";
import {DoNothingFuse} from "../fuses/DoNothingFuse.sol";

contract PlazmaVaultTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

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

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        vaultFactory = new PlazmaVaultFactory(owner);
        userOne = address(0x777);
    }

    function testShouldExecuteSimpleCase() public {
        //given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(DAI);
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(AAVE_POOL, AAVE_V3_MARKET_ID);

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](1);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(plazmaVault), amount);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyFuse.AaveV3SupplyFuseData({asset: DAI, amount: amount, userEModeCategoryId: 1e18})
                )
            )
        );

        //when
        vm.prank(alpha);
        plazmaVault.execute(calls);

        //then
        /// @dev if is here then it means that the transaction was successful
        assertTrue(true);
    }

    function testShouldExecuteTwoSupplyFuses() public {
        //given
        string memory assetName = "IPOR Fusion USDC";
        string memory assetSymbol = "ipfUSDC";
        address underlyingToken = USDC;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(AAVE_POOL, AAVE_V3_MARKET_ID);

        /// @dev Market Compound V3
        marketConfigs[1] = PlazmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMET_V3_USDC, COMPOUND_V3_MARKET_ID);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMET_V3_USDC, COMPOUND_V3_MARKET_ID);

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
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](2);

        uint256 amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(plazmaVault), 2 * amount);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyFuse.AaveV3SupplyFuseData({asset: USDC, amount: amount, userEModeCategoryId: 1e6})
                )
            )
        );

        calls[1] = PlazmaVault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuse.CompoundV3SupplyFuseData({asset: USDC, amount: amount}))
            )
        );

        //when
        vm.prank(alpha);
        plazmaVault.execute(calls);

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

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(DAI);
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(AAVE_POOL, AAVE_V3_MARKET_ID);

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](1);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(plazmaVault), amount);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyFuse.AaveV3SupplyFuseData({asset: DAI, amount: amount, userEModeCategoryId: 1e18})
                )
            )
        );

        (address aTokenAddress, , ) = AAVE_POOL_DATA_PROVIDER.getReserveTokensAddresses(DAI);

        //when
        vm.prank(alpha);
        plazmaVault.execute(calls);

        //then
        uint256 vaultTotalAssetsAfter = plazmaVault.totalAssets();
        uint256 vaultTotalAssetsInMarket = plazmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID);

        assertTrue(
            ERC20(aTokenAddress).balanceOf(address(plazmaVault)) == amount,
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
        string memory assetName = "IPOR Fusion USDC";
        string memory assetSymbol = "ipfUSDC";
        address underlyingToken = USDC;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(AAVE_POOL, AAVE_V3_MARKET_ID);

        /// @dev Market Compound V3
        marketConfigs[1] = PlazmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMET_V3_USDC, COMPOUND_V3_MARKET_ID);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMET_V3_USDC, COMPOUND_V3_MARKET_ID);

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
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](2);

        uint256 amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(plazmaVault), 2 * amount);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyFuse.AaveV3SupplyFuseData({asset: USDC, amount: amount, userEModeCategoryId: 1e6})
                )
            )
        );

        calls[1] = PlazmaVault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuse.CompoundV3SupplyFuseData({asset: USDC, amount: amount}))
            )
        );

        //when
        vm.prank(alpha);
        plazmaVault.execute(calls);

        //then
        uint256 vaultTotalAssetsAfter = plazmaVault.totalAssets();

        assertGt(vaultTotalAssetsAfter, 199e18, "Vault total assets should be increased by amount");
        assertGt(vaultTotalAssetsAfter, 199e18, "Vault total assets should be increased by amount + amount - 1");
    }

    function testShouldIncreaseValueOfSharesAndNotChangeNumberOfSharesWhenTouchedMarket() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(AAVE_POOL, AAVE_V3_MARKET_ID);
        DoNothingFuse doNothingFuseAaveV3 = new DoNothingFuse(AAVE_V3_MARKET_ID);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(doNothingFuseAaveV3);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 2 * amount);

        vm.prank(userOne);
        ERC20(USDC).approve(address(plazmaVault), 3 * amount);

        vm.prank(userOne);
        plazmaVault.deposit(2 * amount, userOne);

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](1);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyFuse.AaveV3SupplyFuseData({asset: USDC, amount: amount, userEModeCategoryId: 1e6})
                )
            )
        );

        /// @dev first call
        vm.prank(alpha);
        plazmaVault.execute(calls);

        uint256 userSharesBefore = plazmaVault.balanceOf(userOne);
        uint256 userAssetsBefore = plazmaVault.convertToAssets(userSharesBefore);

        /// @dev artificial time forward
        vm.warp(block.timestamp + 100 days);

        PlazmaVault.FuseAction[] memory callsSecond = new PlazmaVault.FuseAction[](1);

        /// @dev do nothing only touch the market
        callsSecond[0] = PlazmaVault.FuseAction(
            address(doNothingFuseAaveV3),
            abi.encodeWithSignature("enter(bytes)", abi.encode(DoNothingFuse.DoNothingFuseData({asset: USDC})))
        );

        //when
        /// @dev second call
        vm.prank(alpha);
        plazmaVault.execute(callsSecond);

        //then
        uint256 userSharesAfter = plazmaVault.balanceOf(userOne);
        uint256 userAssetsAfter = plazmaVault.convertToAssets(userSharesAfter);

        assertEq(userSharesBefore, userSharesAfter, "User shares before and after should be equal");
        assertGt(
            userAssetsAfter,
            userAssetsBefore + 2e18,
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

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(AAVE_POOL, AAVE_V3_MARKET_ID);

        /// @dev Market Compound V3
        marketConfigs[1] = PlazmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMET_V3_USDC, COMPOUND_V3_MARKET_ID);
        DoNothingFuse doNothingFuseCompoundV3 = new DoNothingFuse(COMPOUND_V3_MARKET_ID);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(doNothingFuseCompoundV3);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](2);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = PlazmaVault.MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 2 * amount);

        vm.prank(userOne);
        ERC20(USDC).approve(address(plazmaVault), 3 * amount);

        vm.prank(userOne);
        plazmaVault.deposit(2 * amount, userOne);

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](1);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuse.AaveV3SupplyFuseData({asset: USDC, amount: amount, userEModeCategoryId: 0}))
            )
        );

        /// @dev first call
        vm.prank(alpha);
        plazmaVault.execute(calls);

        uint256 userSharesBefore = plazmaVault.balanceOf(userOne);
        uint256 userAssetsBefore = plazmaVault.convertToAssets(userSharesBefore);

        vm.warp(block.timestamp + 1000 days);

        PlazmaVault.FuseAction[] memory callsSecond = new PlazmaVault.FuseAction[](1);

        callsSecond[0] = PlazmaVault.FuseAction(
            address(doNothingFuseCompoundV3),
            abi.encodeWithSignature("enter(bytes)", abi.encode(DoNothingFuse.DoNothingFuseData({asset: USDC})))
        );

        //when
        /// @dev second call
        vm.prank(alpha);
        plazmaVault.execute(callsSecond);

        //then
        uint256 userSharesAfter = plazmaVault.balanceOf(userOne);
        uint256 userAssetsAfter = plazmaVault.convertToAssets(userSharesAfter);

        assertEq(userSharesBefore, userSharesAfter, "User shares before and after should be equal");
        assertEq(userAssetsAfter, userAssetsBefore, "User assets before and after should be equal");
    }

    function testShouldExitFromAaveV3SupplyFuse() public {
        //given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(DAI);
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(AAVE_POOL, AAVE_V3_MARKET_ID);

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](1);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(plazmaVault), amount);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyFuse.AaveV3SupplyFuseData({asset: DAI, amount: amount, userEModeCategoryId: 1e18})
                )
            )
        );

        vm.prank(alpha);
        plazmaVault.execute(calls);

        PlazmaVault.FuseAction[] memory callsSecond = new PlazmaVault.FuseAction[](1);

        callsSecond[0] = PlazmaVault.FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "exit(bytes)",
                abi.encode(
                    AaveV3SupplyFuse.AaveV3SupplyFuseData({asset: DAI, amount: amount, userEModeCategoryId: 1e18})
                )
            )
        );

        uint256 totalAssetsInMarketBefore = plazmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID);

        //when
        vm.prank(alpha);
        plazmaVault.execute(callsSecond);

        //then
        uint256 totalAssetsInMarketAfter = plazmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID);
        assertGt(
            totalAssetsInMarketBefore,
            totalAssetsInMarketAfter,
            "Total assets in market should be decreased by amount"
        );
    }

    //    function testShouldExitFromTwoMarkets() public {
    //        //TODO: implement
    //    }
}
