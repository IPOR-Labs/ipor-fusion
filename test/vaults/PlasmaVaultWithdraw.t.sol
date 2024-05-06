// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626Permit} from "../../contracts/tokens/ERC4626/ERC4626Permit.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {CompoundV3BalanceFuse} from "../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {CompoundV3SupplyFuse, CompoundV3SupplyFuseEnterData} from "../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IAavePoolDataProvider} from "../../contracts/fuses/aave_v3/IAavePoolDataProvider.sol";
import {IporPriceOracle} from "../../contracts/priceOracle/IporPriceOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PlasmaVaultLib} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {AaveConstants} from "../../contracts/fuses/aave_v3/AaveConstants.sol";

interface AavePool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

contract PlasmaVaultWithdrawTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant ETHEREUM_AAVE_PRICE_ORACLE_MAINNET = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
    address public constant ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3 = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    uint256 public constant AAVE_V3_MARKET_ID = 1;

    address public constant COMET_V3_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    uint256 public constant COMPOUND_V3_MARKET_ID = 2;

    uint256 public constant ERC4626_MARKET_ID = 3;

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

    IporPriceOracle private iporPriceOracleProxy;

    event AaveV3SupplyExitFuse(address version, address asset, uint256 amount);
    event CompoundV3SupplyExitFuse(address version, address asset, address market, uint256 amount);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19724793);

        userOne = address(0x777);
        userTwo = address(0x888);

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

    function testShouldInstantWithdrawCashAvailableOnPlasmaVault() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai();

        userOne = address(0x777);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plasmaVault.balanceOf(userOne);

        //when
        vm.prank(userOne);
        plasmaVault.withdraw(amount, userOne, userOne);

        //then
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plasmaVault.balanceOf(userOne);

        assertEq(vaultTotalAssetsBefore - amount, vaultTotalAssetsAfter);
        assertEq(userVaultBalanceBefore - amount, userVaultBalanceAfter);

        assertEq(vaultTotalAssetsAfter, 0);
    }

    function testShouldNotInstantWithdrawBecauseNoShares() public {
        // given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai();

        userOne = address(0x777);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        bytes4 selector = bytes4(keccak256("ERC4626ExceededMaxWithdraw(address,uint256,uint256)"));
        //when
        vm.prank(userOne);
        vm.expectRevert(abi.encodeWithSelector(selector, userOne, amount, 0));
        plasmaVault.withdraw(amount, userOne, userOne);
    }

    function testShouldInstantlyWithdrawRequiredExitFromOneMarketAaveV3() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlasmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
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

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlasmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 2 * amount);

        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(2 * amount, userOne);

        PlasmaVault.FuseAction[] memory calls = new PlasmaVault.FuseAction[](1);

        calls[0] = PlasmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: amount, userEModeCategoryId: 1e6}))
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[]
            memory instantWithdrawFuses = new PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = PlasmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        plasmaVault.updateInstantWithdrawalFuses(instantWithdrawFuses);

        //when
        vm.prank(userOne);
        plasmaVault.withdraw(199 * 1e6, userOne, userOne);

        //then
        uint256 userBalanceAfter = ERC20(USDC).balanceOf(userOne);

        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();

        assertEq(userBalanceAfter, 199 * 1e6);
        assertGt(vaultTotalAssetsAfter, 0);
        assertEq(vaultTotalAssetsAfter, 1e6);
    }

    function testShouldInstantWithdrawRequiredExitFromTwoMarketsAaveV3CompoundV3() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlasmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
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
        marketConfigs[1] = PlasmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](2);
        balanceFuses[0] = PlasmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = PlasmaVault.MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 2 * amount);

        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(2 * amount, userOne);

        PlasmaVault.FuseAction[] memory calls = new PlasmaVault.FuseAction[](2);

        calls[0] = PlasmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6, userEModeCategoryId: 1e6}))
            )
        );

        calls[1] = PlasmaVault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6}))
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[]
            memory instantWithdrawFuses = new PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = PlasmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = PlasmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        plasmaVault.updateInstantWithdrawalFuses(instantWithdrawFuses);

        //when
        vm.prank(userOne);
        plasmaVault.withdraw(175 * 1e6, userOne, userOne);

        //then
        uint256 userBalanceAfter = ERC20(USDC).balanceOf(userOne);
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();

        assertEq(userBalanceAfter, 175 * 1e6);

        assertGt(vaultTotalAssetsAfter, 24 * 1e6);
        assertLt(vaultTotalAssetsAfter, 25 * 1e6);
    }

    function testShouldEmitEventWhenInstantWithdrawFromAaveV3() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlasmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
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

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlasmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 2 * amount);

        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(2 * amount, userOne);

        PlasmaVault.FuseAction[] memory calls = new PlasmaVault.FuseAction[](1);

        calls[0] = PlasmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: amount, userEModeCategoryId: 1e6}))
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[]
            memory instantWithdrawFuses = new PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = PlasmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        plasmaVault.updateInstantWithdrawalFuses(instantWithdrawFuses);

        //then
        vm.expectEmit(true, true, true, true);
        emit AaveV3SupplyExitFuse(address(supplyFuseAaveV3), USDC, 99 * 1e6);
        //when
        vm.prank(userOne);
        plasmaVault.withdraw(199 * 1e6, userOne, userOne);
    }

    function testShouldEmitEventsWhenInstantWithdrawExitFromTwoMarketsAaveV3CompoundV3() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlasmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
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
        marketConfigs[1] = PlasmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](2);
        balanceFuses[0] = PlasmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = PlasmaVault.MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 2 * amount);

        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(2 * amount, userOne);

        PlasmaVault.FuseAction[] memory calls = new PlasmaVault.FuseAction[](2);

        calls[0] = PlasmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6, userEModeCategoryId: 1e6}))
            )
        );

        calls[1] = PlasmaVault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6}))
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[]
            memory instantWithdrawFuses = new PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = PlasmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = PlasmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        plasmaVault.updateInstantWithdrawalFuses(instantWithdrawFuses);

        //then
        vm.expectEmit(true, true, true, true);
        emit AaveV3SupplyExitFuse(address(supplyFuseAaveV3), USDC, 50 * 1e6);
        vm.expectEmit(true, true, true, true);
        emit CompoundV3SupplyExitFuse(address(supplyFuseCompoundV3), USDC, COMET_V3_USDC, 25 * 1e6);

        //when
        vm.prank(userOne);
        plasmaVault.withdraw(175 * 1e6, userOne, userOne);
    }

    function testShouldInstantWithdrawExitFromTwoMarketsAaveV3CompoundV3WhenOneMarketFails() public {
        /// @dev scenario:
        /// - userOne deposit 200, userTwo deposit 200,
        /// - 100 moved to AaveV3, 100 moved to CompoundV3, 200 is on vault
        /// - userOne withdraw 175, 25 is on vault, 100 on CompoundV3
        /// - vault transfer 100 aTokens outside
        /// - userTwo withdraw 30, 0 on vault, 95 on CompoundV3

        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlasmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
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
        marketConfigs[1] = PlasmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](2);
        balanceFuses[0] = PlasmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = PlasmaVault.MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        amount = 100 * 1e6;

        /// @dev user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 2 * amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(2 * amount, userOne);

        /// @dev user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), 2 * amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userTwo);
        plasmaVault.deposit(2 * amount, userTwo);

        PlasmaVault.FuseAction[] memory calls = new PlasmaVault.FuseAction[](2);

        calls[0] = PlasmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6, userEModeCategoryId: 1e6}))
            )
        );

        calls[1] = PlasmaVault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6}))
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[]
            memory instantWithdrawFuses = new PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = PlasmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = PlasmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        /// @dev configure order for instant withdraw
        plasmaVault.updateInstantWithdrawalFuses(instantWithdrawFuses);

        vm.prank(userOne);
        plasmaVault.withdraw(175 * 1e6, userOne, userOne);

        address aTokenAddress;
        (aTokenAddress, , ) = IAavePoolDataProvider(AaveConstants.ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3_MAINNET)
            .getReserveTokensAddresses(USDC);

        address userThree = address(0x999);

        /// @dev artificially transfer aTokens to random person, PlasmaVault don't have enough assets to withdraw from Aave V3
        vm.prank(address(plasmaVault));
        ERC20(aTokenAddress).transfer(userThree, 100 * 1e6);

        //when
        vm.prank(userTwo);
        plasmaVault.withdraw(30 * 1e6, userTwo, userTwo);

        //then
        uint256 userOneBalanceAfter = ERC20(USDC).balanceOf(userOne);
        uint256 userTwoBalanceAfter = ERC20(USDC).balanceOf(userTwo);

        assertEq(userOneBalanceAfter, 175 * 1e6);
        assertEq(userTwoBalanceAfter, 30 * 1e6);

        /// CompoundV3 balance
        uint256 vaultTotalAssetInCompoundV3After = plasmaVault.totalAssetsInMarket(COMPOUND_V3_MARKET_ID);

        assertGt(vaultTotalAssetInCompoundV3After, 94 * 1e6, "vaultTotalAssetInCompoundV3After gt");
        assertLt(vaultTotalAssetInCompoundV3After, 95 * 1e6, "vaultTotalAssetInCompoundV3After lt");
    }

    function testShouldNotInstantWithdrawExitFromTwoMarketsAaveV3CompoundV3WhenOneMarketFailsUsedDoesntHaveEnoughShares()
        public
    {
        /// @dev scenario:
        /// - userOne deposit 200, userTwo deposit 200,
        /// - 100 moved to AaveV3, 100 moved to CompoundV3, 200 is on vault
        /// - userOne withdraw 175, 25 directly on vault, 100 on CompoundV3
        /// - vault transfer 100 aTokens outside, 25 directly on vault, 100 on CompoundV3
        /// - userTwo withdraw 120
        /// - transaction failed, because exchange rate changed and for 120 assets not enough user's shares

        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlasmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
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
        marketConfigs[1] = PlasmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](2);
        balanceFuses[0] = PlasmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = PlasmaVault.MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        amount = 100 * 1e6;

        /// @dev user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 2 * amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(2 * amount, userOne);

        /// @dev user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), 2 * amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userTwo);
        plasmaVault.deposit(2 * amount, userTwo);

        PlasmaVault.FuseAction[] memory calls = new PlasmaVault.FuseAction[](2);

        calls[0] = PlasmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6, userEModeCategoryId: 1e6}))
            )
        );

        calls[1] = PlasmaVault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6}))
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[]
            memory instantWithdrawFuses = new PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = PlasmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = PlasmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        /// @dev configure order for instant withdraw
        plasmaVault.updateInstantWithdrawalFuses(instantWithdrawFuses);

        vm.prank(userOne);
        plasmaVault.withdraw(175 * 1e6, userOne, userOne);

        address aTokenAddress;
        (aTokenAddress, , ) = IAavePoolDataProvider(AaveConstants.ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3_MAINNET)
            .getReserveTokensAddresses(USDC);

        address userThree = address(0x999);

        /// @dev artificially transfer aTokens to random person, PlasmaVault don't have enough assets to withdraw from Aave V3
        vm.prank(address(plasmaVault));
        ERC20(aTokenAddress).transfer(userThree, 100 * 1e6);

        //when
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Permit.ERC4626ExceededMaxWithdraw.selector,
                0x0000000000000000000000000000000000000888,
                120000000,
                111111110
            )
        );
        vm.prank(userTwo);
        plasmaVault.withdraw(120 * 1e6, userTwo, userTwo);
    }

    function testShouldRedeemExitFromTwoMarketsAaveV3CompoundV3WhenOneMarketFails() public {
        /// @dev scenario:
        /// - userOne deposit 200, userTwo deposit 200,
        /// - 100 moved to AaveV3, 100 moved to CompoundV3, 200 is on vault
        /// - userOne redeem 175, 25 is on vault, 100 on CompoundV3
        /// - vault transfer 100 aTokens outside
        /// - userTwo redeem 30, 0 on vault, 95 on CompoundV3

        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlasmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
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
        marketConfigs[1] = PlasmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](2);
        balanceFuses[0] = PlasmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = PlasmaVault.MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        amount = 100 * 1e6;

        /// @dev user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 2 * amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(2 * amount, userOne);

        /// @dev user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), 2 * amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userTwo);
        plasmaVault.deposit(2 * amount, userTwo);

        PlasmaVault.FuseAction[] memory calls = new PlasmaVault.FuseAction[](2);

        calls[0] = PlasmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6, userEModeCategoryId: 1e6}))
            )
        );

        calls[1] = PlasmaVault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6}))
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[]
            memory instantWithdrawFuses = new PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = PlasmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = PlasmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        /// @dev configure order for instant withdraw
        plasmaVault.updateInstantWithdrawalFuses(instantWithdrawFuses);

        vm.prank(userOne);
        plasmaVault.redeem(175 * 1e6, userOne, userOne);

        address aTokenAddress;
        (aTokenAddress, , ) = IAavePoolDataProvider(AaveConstants.ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3_MAINNET)
            .getReserveTokensAddresses(USDC);

        address userThree = address(0x999);

        /// @dev artificially transfer aTokens to random person, PlasmaVault don't have enough assets to withdraw from Aave V3
        vm.prank(address(plasmaVault));
        ERC20(aTokenAddress).transfer(userThree, 100 * 1e6);

        //when
        vm.prank(userTwo);
        plasmaVault.redeem(30 * 1e6, userTwo, userTwo);

        //then
        uint256 userOneBalanceAfter = ERC20(USDC).balanceOf(userOne);
        uint256 userTwoBalanceAfter = ERC20(USDC).balanceOf(userTwo);

        assertEq(userOneBalanceAfter, 174999999);
        assertEq(userTwoBalanceAfter, 16666666);

        /// CompoundV3 balance
        uint256 vaultTotalAssetInCompoundV3After = plasmaVault.totalAssetsInMarket(COMPOUND_V3_MARKET_ID);

        assertGt(vaultTotalAssetInCompoundV3After, 94 * 1e6, "vaultTotalAssetInCompoundV3After gt");
        assertLt(vaultTotalAssetInCompoundV3After, 95 * 1e6, "vaultTotalAssetInCompoundV3After lt");
    }

    function testShouldRedeemExitFromOneMarketAaveV3SlippageSavedAgainstSecondIteration() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlasmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
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

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlasmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        amount = 100 * 1e6;

        /// @dev user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 3 * amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(2 * amount, userOne);

        PlasmaVault.FuseAction[] memory calls = new PlasmaVault.FuseAction[](1);

        calls[0] = PlasmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: 2 * amount, userEModeCategoryId: 1e6}))
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[]
            memory instantWithdrawFuses = new PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = PlasmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        /// @dev configure order for instant withdraw
        plasmaVault.updateInstantWithdrawalFuses(instantWithdrawFuses);

        address aTokenAddress;
        (aTokenAddress, , ) = IAavePoolDataProvider(AaveConstants.ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3_MAINNET)
            .getReserveTokensAddresses(USDC);

        /// @dev artificially transfer aTokens to a Plasma Vault to increase shares values
        vm.prank(userOne);
        ERC20(USDC).approve(address(AAVE_POOL), amount);

        vm.prank(userOne);
        AavePool(AAVE_POOL).deposit(USDC, 1 * 1e6, address(plasmaVault), 0);

        //when
        vm.prank(userOne);
        plasmaVault.redeem(200 * 1e6, userOne, userOne);

        //then
        uint256 userOneBalanceAfter = ERC20(USDC).balanceOf(userOne);

        assertEq(userOneBalanceAfter, 3 * amount);
    }

    function testShouldRedeemExitFromOneMarketAaveV3SlippageNOTSavedInFirstIteration() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlasmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
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

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlasmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        amount = 100 * 1e6;

        /// @dev user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 3 * amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(2 * amount, userOne);

        PlasmaVault.FuseAction[] memory calls = new PlasmaVault.FuseAction[](1);

        calls[0] = PlasmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: 2 * amount, userEModeCategoryId: 1e6}))
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[]
            memory instantWithdrawFuses = new PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = PlasmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        /// @dev configure order for instant withdraw
        plasmaVault.updateInstantWithdrawalFuses(instantWithdrawFuses);

        address aTokenAddress;
        (aTokenAddress, , ) = IAavePoolDataProvider(AaveConstants.ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3_MAINNET)
            .getReserveTokensAddresses(USDC);

        /// @dev artificially transfer aTokens to a Plasma Vault to increase shares values
        vm.prank(userOne);
        ERC20(USDC).approve(address(AAVE_POOL), amount);

        /// @dev PlasmaVault earn more tokens than slippage
        vm.prank(userOne);
        AavePool(AAVE_POOL).deposit(USDC, 5 * 1e6, address(plasmaVault), 0);

        //when
        vm.prank(userOne);
        plasmaVault.redeem(170 * 1e6, userOne, userOne);

        //then
        uint256 userOneBalanceAfter = ERC20(USDC).balanceOf(userOne);

        assertEq(userOneBalanceAfter, 269249999);
    }

    function testShouldRedeemAllSharesExitFromTwoMarketsAaveV3CompoundV3WhenOneMarketFails() public {
        /// @dev scenario:
        /// - userOne deposit 200, userTwo deposit 200,
        /// - 100 moved to AaveV3, 100 moved to CompoundV3, 200 is on vault
        /// - userOne redeem 175, 25 is on vault, 100 on CompoundV3
        /// - vault transfer 100 aTokens outside
        /// - userOne redeem 25
        /// - userTwo redeem 200

        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alphas = new address[](1);
        alpha = address(0x1);

        alphas[0] = alpha;

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlasmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
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
        marketConfigs[1] = PlasmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](2);
        balanceFuses[0] = PlasmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = PlasmaVault.MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        amount = 100 * 1e6;

        /// @dev user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 2 * amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(2 * amount, userOne);

        /// @dev user two
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userTwo), 2 * amount);
        vm.prank(userTwo);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userTwo);
        plasmaVault.deposit(2 * amount, userTwo);

        PlasmaVault.FuseAction[] memory calls = new PlasmaVault.FuseAction[](2);

        calls[0] = PlasmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6, userEModeCategoryId: 1e6}))
            )
        );

        calls[1] = PlasmaVault.FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6}))
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[]
            memory instantWithdrawFuses = new PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = PlasmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = PlasmaVaultLib.InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        /// @dev configure order for instant withdraw
        plasmaVault.updateInstantWithdrawalFuses(instantWithdrawFuses);

        vm.prank(userOne);
        plasmaVault.redeem(175 * 1e6, userOne, userOne);

        address aTokenAddress;
        (aTokenAddress, , ) = IAavePoolDataProvider(AaveConstants.ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3_MAINNET)
            .getReserveTokensAddresses(USDC);

        address userThree = address(0x999);

        /// @dev artificially transfer aTokens to random person, PlasmaVault don't have enough assets to withdraw from Aave V3
        vm.prank(address(plasmaVault));
        ERC20(aTokenAddress).transfer(userThree, 100 * 1e6);

        //when
        vm.prank(userTwo);
        plasmaVault.redeem(200 * 1e6, userTwo, userTwo);

        vm.prank(userOne);
        plasmaVault.redeem(25 * 1e6, userOne, userOne);

        //then
        uint256 userOneBalanceAfter = ERC20(USDC).balanceOf(userOne);
        uint256 userTwoBalanceAfter = ERC20(USDC).balanceOf(userTwo);

        assertEq(userOneBalanceAfter, 188888888);
        assertEq(userTwoBalanceAfter, 111111111);

        /// CompoundV3 balance
        uint256 vaultTotalAssetInCompoundV3After = plasmaVault.totalAssetsInMarket(COMPOUND_V3_MARKET_ID);
        assertEq(vaultTotalAssetInCompoundV3After, 0, "vaultTotalAssetInCompoundV3After");
    }

    function _preparePlasmaVaultUsdc() public returns (PlasmaVault) {
        string memory assetName = "IPOR Fusion USDC";
        string memory assetSymbol = "ipfUSDC";
        address underlyingToken = USDC;
        address[] memory alphas = new address[](1);

        alphas[0] = address(0x1);

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = PlasmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
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
        marketConfigs[1] = PlasmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](2);
        balanceFuses[0] = PlasmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = PlasmaVault.MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );
        return plasmaVault;
    }

    function _preparePlasmaVaultDai() public returns (PlasmaVault) {
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        marketConfigs[0] = PlasmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

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

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlasmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        return plasmaVault;
    }
}
