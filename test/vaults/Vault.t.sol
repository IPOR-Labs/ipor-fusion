// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VaultFactory} from "../../contracts/vaults/VaultFactory.sol";
import {Vault} from "../../contracts/vaults/Vault.sol";
import {AaveV3SupplyFuse} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {CompoundV3BalanceFuse} from "../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {CompoundV3SupplyFuse} from "../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {MarketConfigurationLib} from "../../contracts/libraries/MarketConfigurationLib.sol";
import {IAavePoolDataProvider} from "../../contracts/fuses/aave_v3/IAavePoolDataProvider.sol";
import {DoNothingFuse} from "../fuses/DoNothingFuse.sol";

contract VaultTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    VaultFactory internal vaultFactory;

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
    address[] public keepers;
    address public keeper;
    uint256 public amount;

    address public userOne;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        vaultFactory = new VaultFactory(owner);
        userOne = address(0x777);
    }

    function testShouldExecuteSimpleCase() public {
        //given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(DAI);
        marketConfigs[0] = Vault.MarketConfig(AAVE_V3_MARKET_ID, assets);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(AAVE_POOL, AAVE_V3_MARKET_ID);

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);

        Vault.FuseStruct[] memory balanceFuses = new Vault.FuseStruct[](1);
        balanceFuses[0] = Vault.FuseStruct(AAVE_V3_MARKET_ID, address(balanceFuse));

        Vault vault = Vault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    keepers,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        Vault.FuseAction[] memory calls = new Vault.FuseAction[](1);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(vault), amount);

        calls[0] = Vault.FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyFuse.AaveV3SupplyFuseData({asset: DAI, amount: amount, userEModeCategoryId: 1e18})
                )
            )
        );

        //when
        vm.prank(keeper);
        vault.execute(calls);

        //then
        /// @dev if is here then it means that the transaction was successful
        assertTrue(true);
    }

    function testShouldExecuteTwoSupplyFuses() public {
        //given
        string memory assetName = "IPOR Fusion USDC";
        string memory assetSymbol = "ipfUSDC";
        address underlyingToken = USDC;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = Vault.MarketConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(AAVE_POOL, AAVE_V3_MARKET_ID);

        /// @dev Market Compound V3
        marketConfigs[1] = Vault.MarketConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMET_V3_USDC, COMPOUND_V3_MARKET_ID);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMET_V3_USDC, COMPOUND_V3_MARKET_ID);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        Vault.FuseStruct[] memory balanceFuses = new Vault.FuseStruct[](2);
        balanceFuses[0] = Vault.FuseStruct(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = Vault.FuseStruct(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        Vault vault = Vault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    keepers,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        Vault.FuseAction[] memory calls = new Vault.FuseAction[](2);

        uint256 amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(vault), 2 * amount);

        calls[0] = Vault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyFuse.AaveV3SupplyFuseData({asset: USDC, amount: amount, userEModeCategoryId: 1e6})
                )
            )
        );

        calls[1] = Vault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuse.CompoundV3SupplyFuseData({asset: USDC, amount: amount}))
            )
        );

        //when
        vm.prank(keeper);
        vault.execute(calls);

        //then
        /// @dev if is here then it means that the transaction was successful
        assertTrue(true);
    }

    function testShouldUpdateBalanceWhenOneFuse() public {
        //given
        assetName = "IPOR Fusion DAI";
        assetSymbol = "ipfDAI";
        underlyingToken = DAI;
        keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(DAI);
        marketConfigs[0] = Vault.MarketConfig(AAVE_V3_MARKET_ID, assets);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(AAVE_POOL, AAVE_V3_MARKET_ID);

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);

        Vault.FuseStruct[] memory balanceFuses = new Vault.FuseStruct[](1);
        balanceFuses[0] = Vault.FuseStruct(AAVE_V3_MARKET_ID, address(balanceFuse));

        Vault vault = Vault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    keepers,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        Vault.FuseAction[] memory calls = new Vault.FuseAction[](1);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(vault), amount);

        calls[0] = Vault.FuseAction(
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
        vm.prank(keeper);
        vault.execute(calls);

        //then
        uint256 vaultTotalAssetsAfter = vault.totalAssets();
        uint256 vaultTotalAssetsInMarket = vault.totalAssetsInMarket(AAVE_V3_MARKET_ID);

        assertTrue(
            ERC20(aTokenAddress).balanceOf(address(vault)) == amount,
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
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = Vault.MarketConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(AAVE_POOL, AAVE_V3_MARKET_ID);

        /// @dev Market Compound V3
        marketConfigs[1] = Vault.MarketConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMET_V3_USDC, COMPOUND_V3_MARKET_ID);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMET_V3_USDC, COMPOUND_V3_MARKET_ID);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        Vault.FuseStruct[] memory balanceFuses = new Vault.FuseStruct[](2);
        balanceFuses[0] = Vault.FuseStruct(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = Vault.FuseStruct(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        Vault vault = Vault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    keepers,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        Vault.FuseAction[] memory calls = new Vault.FuseAction[](2);

        uint256 amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(vault), 2 * amount);

        calls[0] = Vault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyFuse.AaveV3SupplyFuseData({asset: USDC, amount: amount, userEModeCategoryId: 1e6})
                )
            )
        );

        calls[1] = Vault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuse.CompoundV3SupplyFuseData({asset: USDC, amount: amount}))
            )
        );

        //when
        vm.prank(keeper);
        vault.execute(calls);

        //then
        uint256 vaultTotalAssetsAfter = vault.totalAssets();

        assertGt(vaultTotalAssetsAfter, 199e18, "Vault total assets should be increased by amount");
        assertGt(vaultTotalAssetsAfter, 199e18, "Vault total assets should be increased by amount + amount - 1");
    }

    function testShouldIncreaseValueOfSharesAndNotChangeNumberOfSharesWhenTouchedMarket() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        keepers = new address[](1);
        keeper = address(0x1);

        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = Vault.MarketConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(AAVE_POOL, AAVE_V3_MARKET_ID);
        DoNothingFuse doNothingFuseAaveV3 = new DoNothingFuse(AAVE_V3_MARKET_ID);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(doNothingFuseAaveV3);

        Vault.FuseStruct[] memory balanceFuses = new Vault.FuseStruct[](1);
        balanceFuses[0] = Vault.FuseStruct(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        Vault vault = Vault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    keepers,
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
        ERC20(USDC).approve(address(vault), 3 * amount);

        vm.prank(userOne);
        vault.deposit(2 * amount, userOne);

        Vault.FuseAction[] memory calls = new Vault.FuseAction[](1);

        calls[0] = Vault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyFuse.AaveV3SupplyFuseData({asset: USDC, amount: amount, userEModeCategoryId: 1e6})
                )
            )
        );

        /// @dev first call
        vm.prank(keeper);
        vault.execute(calls);

        uint256 userSharesBefore = vault.balanceOf(userOne);
        uint256 userAssetsBefore = vault.convertToAssets(userSharesBefore);

        /// @dev artificial time forward
        vm.warp(block.timestamp + 100 days);

        Vault.FuseAction[] memory callsSecond = new Vault.FuseAction[](1);

        /// @dev do nothing only touch the market
        callsSecond[0] = Vault.FuseAction(
            address(doNothingFuseAaveV3),
            abi.encodeWithSignature("enter(bytes)", abi.encode(DoNothingFuse.DoNothingFuseData({asset: USDC})))
        );

        //when
        /// @dev second call
        vm.prank(keeper);
        vault.execute(callsSecond);

        //then
        uint256 userSharesAfter = vault.balanceOf(userOne);
        uint256 userAssetsAfter = vault.convertToAssets(userSharesAfter);

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
        keepers = new address[](1);
        keeper = address(0x1);

        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = Vault.MarketConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(AAVE_POOL, AAVE_V3_MARKET_ID);

        /// @dev Market Compound V3
        marketConfigs[1] = Vault.MarketConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMET_V3_USDC, COMPOUND_V3_MARKET_ID);
        DoNothingFuse doNothingFuseCompoundV3 = new DoNothingFuse(COMPOUND_V3_MARKET_ID);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(doNothingFuseCompoundV3);

        Vault.FuseStruct[] memory balanceFuses = new Vault.FuseStruct[](2);
        balanceFuses[0] = Vault.FuseStruct(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = Vault.FuseStruct(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        Vault vault = Vault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    keepers,
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
        ERC20(USDC).approve(address(vault), 3 * amount);

        vm.prank(userOne);
        vault.deposit(2 * amount, userOne);

        Vault.FuseAction[] memory calls = new Vault.FuseAction[](1);

        calls[0] = Vault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuse.AaveV3SupplyFuseData({asset: USDC, amount: amount, userEModeCategoryId: 0}))
            )
        );

        /// @dev first call
        vm.prank(keeper);
        vault.execute(calls);

        uint256 userSharesBefore = vault.balanceOf(userOne);
        uint256 userAssetsBefore = vault.convertToAssets(userSharesBefore);

        vm.warp(block.timestamp + 1000 days);

        Vault.FuseAction[] memory callsSecond = new Vault.FuseAction[](1);

        callsSecond[0] = Vault.FuseAction(
            address(doNothingFuseCompoundV3),
            abi.encodeWithSignature("enter(bytes)", abi.encode(DoNothingFuse.DoNothingFuseData({asset: USDC})))
        );

        //when
        /// @dev second call
        vm.prank(keeper);
        vault.execute(callsSecond);

        //then
        uint256 userSharesAfter = vault.balanceOf(userOne);
        uint256 userAssetsAfter = vault.convertToAssets(userSharesAfter);

        assertEq(userSharesBefore, userSharesAfter, "User shares before and after should be equal");
        assertEq(userAssetsAfter, userAssetsBefore, "User assets before and after should be equal");
    }
}
