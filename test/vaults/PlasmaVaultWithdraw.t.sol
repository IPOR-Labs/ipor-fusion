// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {PlasmaVault, MarketSubstratesConfig, MarketBalanceFuseConfig, FuseAction, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {CompoundV3BalanceFuse} from "../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {CompoundV3SupplyFuse, CompoundV3SupplyFuseEnterData} from "../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IAavePoolDataProvider} from "../../contracts/fuses/aave_v3/ext/IAavePoolDataProvider.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {PlasmaVaultLib} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
interface AavePool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

contract PlasmaVaultWithdrawTest is Test {
    uint256 public constant WITHDRAW_FROM_MARKETS_OFFSET = 10;
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address public constant ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3 = 0x41393e5e337606dc3821075Af65AeE84D7688CBD;
    uint256 public constant AAVE_V3_MARKET_ID = 1;

    address public constant COMET_V3_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    uint256 public constant COMPOUND_V3_MARKET_ID = 2;

    uint256 public constant ERC4626_MARKET_ID = 3;

    address public atomist = address(this);

    string public assetName;
    string public assetSymbol;
    address public underlyingToken;
    address public alpha;
    uint256 public amount;
    uint256 public sharesAmount;

    address public userOne;
    address public userTwo;

    PriceOracleMiddleware public priceOracleMiddlewareProxy;
    UsersToRoles public usersToRoles;

    event AaveV3SupplyFuseExit(address version, address asset, uint256 amount);
    event CompoundV3SupplyFuseExit(address version, address asset, address market, uint256 amount);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 21036301);

        userOne = address(0x777);
        userTwo = address(0x888);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
    }

    function testShouldInstantWithdrawCashAvailableOnPlasmaVault() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai(0);

        userOne = address(0x777);

        amount = 100 * 1e18;
        sharesAmount = 100 * 10 ** plasmaVault.decimals();

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
        assertEq(userVaultBalanceBefore - sharesAmount, userVaultBalanceAfter);

        assertEq(vaultTotalAssetsAfter, 0);
    }

    function testShouldBeAbleWithdrawAfterRedemptioLock() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai(10 minutes);

        userOne = address(0x777);

        amount = 100 * 1e18;
        sharesAmount = 100 * 10 ** plasmaVault.decimals();

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plasmaVault.balanceOf(userOne);

        //when
        vm.warp(block.timestamp + 15 minutes);
        vm.prank(userOne);
        plasmaVault.withdraw(amount, userOne, userOne);

        //then
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plasmaVault.balanceOf(userOne);

        assertEq(vaultTotalAssetsBefore - amount, vaultTotalAssetsAfter);
        assertEq(userVaultBalanceBefore - sharesAmount, userVaultBalanceAfter);

        assertEq(vaultTotalAssetsAfter, 0);
    }

    function testShouldBeAbleRedeemAfterRedemptioLock() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai(10 minutes);

        userOne = address(0x777);

        amount = 100 * 1e18;
        sharesAmount = 100 * 10 ** plasmaVault.decimals();

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plasmaVault.balanceOf(userOne);

        //when
        vm.warp(block.timestamp + 15 minutes);
        vm.prank(userOne);
        plasmaVault.withdraw(amount, userOne, userOne);

        //then
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plasmaVault.balanceOf(userOne);

        assertEq(vaultTotalAssetsBefore - amount, vaultTotalAssetsAfter, "vaultTotalAssetsBefore - amount");
        assertEq(userVaultBalanceBefore - sharesAmount, userVaultBalanceAfter, "userVaultBalanceBefore - amount");

        assertEq(vaultTotalAssetsAfter, 0);
    }

    function testShouldNotBeAbleWithdrawDuringRedemptionLock() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai(10 minutes);

        userOne = address(0x777);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        bytes memory error = abi.encodeWithSignature("AccountIsLocked(uint256)", 1729783655);

        //when
        vm.warp(block.timestamp + 5 minutes);
        vm.expectRevert(error);
        vm.prank(userOne);
        plasmaVault.withdraw(amount, userOne, userOne);
    }

    function testShouldNotBeAbleTransferDuringRedemptionLock() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai(10 minutes);

        userOne = address(0x777);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        bytes memory error = abi.encodeWithSignature("AccountIsLocked(uint256)", 1729783655);

        //when
        vm.warp(block.timestamp + 5 minutes);
        vm.expectRevert(error);
        vm.prank(userOne);
        plasmaVault.transfer(userTwo, amount);
    }

    function testShouldNotBeAbleTransferFromDuringRedemptionLock() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai(10 minutes);

        vm.prank(userOne);
        plasmaVault.approve(address(userTwo), type(uint256).max);

        userOne = address(0x777);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        bytes memory error = abi.encodeWithSignature("AccountIsLocked(uint256)", 1729783655);

        //when
        vm.warp(block.timestamp + 5 minutes);
        vm.expectRevert(error);
        vm.prank(userTwo);
        plasmaVault.transferFrom(userOne, userTwo, amount);
    }

    function testShouldNotBeAbleRedeemDuringRedemptionLock() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai(10 minutes);

        userOne = address(0x777);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        bytes memory error = abi.encodeWithSignature("AccountIsLocked(uint256)", 1729783655);

        //when
        vm.warp(block.timestamp + 5 minutes);
        vm.expectRevert(error);
        vm.prank(userOne);
        plasmaVault.redeem(10e18, userOne, userOne);
    }

    function testShouldNotInstantWithdrawBecauseNoShares() public {
        // given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai(0);

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
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseAaveV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
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
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: amount, userEModeCategoryId: 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

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

    function testShouldInstantlyWithdrawExitFromOneMarketAaveV3TotalSupplyCapAchieved() public {
        /// @dev Scenario: test shows that even if total supply cap is achieved and performance fee and managment fee will be minted in shares of vault, user can still withdraw his assets

        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseAaveV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        amount = 200 * 1e6;
        sharesAmount = 200 * 10 ** (6 + PlasmaVaultLib.DECIMALS_OFFSET);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                sharesAmount,
                address(0)
            )
        );
        setupRoles(plasmaVault, accessManager);

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount);

        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), amount);

        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        FuseAction[] memory calls = new FuseAction[](1);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: amount, userEModeCategoryId: 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

        //when
        /// @dev important in this test to accrue some interest in external markets
        vm.warp(block.timestamp + 100 days);

        vm.prank(userOne);
        plasmaVault.withdraw(199 * 1e6, userOne, userOne);

        //then
        uint256 userBalanceAfter = ERC20(USDC).balanceOf(userOne);

        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();

        assertEq(userBalanceAfter, 199 * 1e6);
        assertGt(vaultTotalAssetsAfter, 0);
        assertGt(vaultTotalAssetsAfter, 4708504);
    }

    function testShouldInstantWithdrawRequiredExitFromTwoMarketsAaveV3CompoundV3() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
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

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
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

        FuseAction[] memory calls = new FuseAction[](2);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6, userEModeCategoryId: 1e6})
            )
        );

        calls[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                CompoundV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

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
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseAaveV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
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
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: amount, userEModeCategoryId: 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

        //then
        vm.expectEmit(true, true, true, true);
        emit AaveV3SupplyFuseExit(address(supplyFuseAaveV3), USDC, 99 * 1e6 + WITHDRAW_FROM_MARKETS_OFFSET);
        //when
        vm.prank(userOne);
        plasmaVault.withdraw(199 * 1e6, userOne, userOne);
    }

    function testShouldEmitEventsWhenInstantWithdrawExitFromTwoMarketsAaveV3CompoundV3() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
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

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
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

        FuseAction[] memory calls = new FuseAction[](2);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6, userEModeCategoryId: 1e6})
            )
        );

        calls[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                CompoundV3SupplyFuseEnterData({asset: USDC, amount: 50 * 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

        //then
        vm.expectEmit(true, true, true, true);
        emit AaveV3SupplyFuseExit(address(supplyFuseAaveV3), USDC, 50 * 1e6 + 1);
        vm.expectEmit(true, true, true, true);
        emit CompoundV3SupplyFuseExit(
            address(supplyFuseCompoundV3),
            USDC,
            COMET_V3_USDC,
            25 * 1e6 + WITHDRAW_FROM_MARKETS_OFFSET - 1
        );
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
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
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

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );

        setupRoles(plasmaVault, accessManager);

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

        FuseAction[] memory calls = new FuseAction[](2);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6, userEModeCategoryId: 1e6})
            )
        );

        calls[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                CompoundV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        /// @dev configure order for instant withdraw
        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

        vm.prank(userOne);
        plasmaVault.withdraw(175 * 1e6, userOne, userOne);

        address aTokenAddress;
        (aTokenAddress, , ) = IAavePoolDataProvider(ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3).getReserveTokensAddresses(
            USDC
        );

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
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
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

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );

        setupRoles(plasmaVault, accessManager);

        amount = 100 * 1e6;
        sharesAmount = 100 * 10 ** plasmaVault.decimals();

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

        FuseAction[] memory calls = new FuseAction[](2);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6, userEModeCategoryId: 1e6})
            )
        );

        calls[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                CompoundV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        /// @dev configure order for instant withdraw
        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

        vm.prank(userOne);
        plasmaVault.withdraw(175 * 1e6, userOne, userOne);

        address aTokenAddress;
        (aTokenAddress, , ) = IAavePoolDataProvider(ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3).getReserveTokensAddresses(
            USDC
        );

        address userThree = address(0x999);

        /// @dev artificially transfer aTokens to random person, PlasmaVault don't have enough assets to withdraw from Aave V3
        vm.prank(address(plasmaVault));
        ERC20(aTokenAddress).transfer(userThree, 100 * 1e6);

        //when
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626.ERC4626ExceededMaxWithdraw.selector,
                0x0000000000000000000000000000000000000888,
                120000000,
                111111109
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
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
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

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );

        setupRoles(plasmaVault, accessManager);

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

        FuseAction[] memory calls = new FuseAction[](2);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6, userEModeCategoryId: 1e6})
            )
        );

        calls[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                CompoundV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        /// @dev configure order for instant withdraw
        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

        vm.startPrank(userOne);
        plasmaVault.redeem(175 * 10 ** plasmaVault.decimals(), userOne, userOne);
        vm.stopPrank();

        address aTokenAddress;
        (aTokenAddress, , ) = IAavePoolDataProvider(ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3).getReserveTokensAddresses(
            USDC
        );

        address userThree = address(0x999);

        /// @dev artificially transfer aTokens to random person, PlasmaVault don't have enough assets to withdraw from Aave V3
        vm.prank(address(plasmaVault));
        ERC20(aTokenAddress).transfer(userThree, 100 * 1e6);

        //when
        vm.startPrank(userTwo);
        plasmaVault.redeem(30 * 10 ** plasmaVault.decimals(), userTwo, userTwo);
        vm.stopPrank();

        //then
        uint256 userOneBalanceAfter = ERC20(USDC).balanceOf(userOne);
        uint256 userTwoBalanceAfter = ERC20(USDC).balanceOf(userTwo);

        assertApproxEqAbs(userOneBalanceAfter, 175 * 1e6, 1, "userOneBalanceAfter aprox");
        assertEq(userTwoBalanceAfter, 16666666, "userTwoBalanceAfter");

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
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseAaveV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );

        setupRoles(plasmaVault, accessManager);

        amount = 100 * 1e6;

        /// @dev user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 3 * amount);

        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(2 * amount, userOne);

        FuseAction[] memory calls = new FuseAction[](1);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: 2 * amount, userEModeCategoryId: 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        /// @dev configure order for instant withdraw
        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

        address aTokenAddress;
        (aTokenAddress, , ) = IAavePoolDataProvider(ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3).getReserveTokensAddresses(
            USDC
        );

        /// @dev artificially transfer aTokens to a Plasma Vault to increase shares values
        vm.prank(userOne);
        ERC20(USDC).approve(address(AAVE_POOL), amount);

        vm.prank(userOne);
        AavePool(AAVE_POOL).deposit(USDC, 1 * 1e6, address(plasmaVault), 0);

        //when
        vm.startPrank(userOne);
        plasmaVault.redeem(200 * 10 ** plasmaVault.decimals(), userOne, userOne);
        vm.stopPrank();

        //then
        uint256 userOneBalanceAfter = ERC20(USDC).balanceOf(userOne);

        assertApproxEqAbs(userOneBalanceAfter, 3 * amount, 100, "userOneBalanceAfter");
    }

    function testShouldRedeemExitFromOneMarketAaveV3SlippageNOTSavedInFirstIteration() public {
        //given
        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseAaveV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );

        setupRoles(plasmaVault, accessManager);

        amount = 100 * 1e6;

        /// @dev user one
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), 3 * amount);
        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(2 * amount, userOne);

        FuseAction[] memory calls = new FuseAction[](1);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: 2 * amount, userEModeCategoryId: 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        /// @dev configure order for instant withdraw
        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

        address aTokenAddress;
        (aTokenAddress, , ) = IAavePoolDataProvider(ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3).getReserveTokensAddresses(
            USDC
        );

        /// @dev artificially transfer aTokens to a Plasma Vault to increase shares values
        vm.prank(userOne);
        ERC20(USDC).approve(address(AAVE_POOL), amount);

        /// @dev PlasmaVault earn more tokens than slippage
        vm.prank(userOne);
        AavePool(AAVE_POOL).deposit(USDC, 5 * 1e6, address(plasmaVault), 0);

        //when
        vm.startPrank(userOne);
        plasmaVault.redeem(170 * 10 ** plasmaVault.decimals(), userOne, userOne);
        vm.stopPrank();

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
        alpha = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
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

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVaultBase plasmaVaultBase = new PlasmaVaultBase();

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(plasmaVaultBase),
                type(uint256).max,
                address(0)
            )
        );
        setupRoles(plasmaVault, accessManager);

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

        FuseAction[] memory calls = new FuseAction[](2);

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6, userEModeCategoryId: 1e6})
            )
        );

        calls[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                CompoundV3SupplyFuseEnterData({asset: USDC, amount: 100 * 1e6})
            )
        );

        /// @dev first call to move some assets to a external market
        vm.prank(alpha);
        plasmaVault.execute(calls);

        /// @dev prepare instant withdraw config
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = 0;
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseAaveV3),
            params: instantWithdrawParams
        });

        instantWithdrawFuses[1] = InstantWithdrawalFusesParamsStruct({
            fuse: address(supplyFuseCompoundV3),
            params: instantWithdrawParams
        });

        /// @dev configure order for instant withdraw
        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);

        vm.startPrank(userOne);
        plasmaVault.redeem(175 * 10 ** plasmaVault.decimals(), userOne, userOne);
        vm.stopPrank();

        address aTokenAddress;
        (aTokenAddress, , ) = IAavePoolDataProvider(ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3).getReserveTokensAddresses(
            USDC
        );

        address userThree = address(0x999);

        /// @dev artificially transfer aTokens to random person, PlasmaVault don't have enough assets to withdraw from Aave V3
        vm.prank(address(plasmaVault));
        ERC20(aTokenAddress).transfer(userThree, 100 * 1e6);

        //when
        vm.startPrank(userTwo);
        plasmaVault.redeem(200 * 10 ** plasmaVault.decimals(), userTwo, userTwo);
        vm.stopPrank();

        vm.startPrank(userOne);
        plasmaVault.redeem(25 * 10 ** plasmaVault.decimals(), userOne, userOne);
        vm.stopPrank();

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

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
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

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );

        setupRoles(plasmaVault, accessManager);
        return plasmaVault;
    }

    function _preparePlasmaVaultDai(uint256 redemptionDelay) public returns (PlasmaVault) {
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, redemptionDelay);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max,
                address(0)
            )
        );

        setupRoles(plasmaVault, accessManager);

        return plasmaVault;
    }

    function createAccessManager(
        UsersToRoles memory usersToRoles_,
        uint256 redemptionDelay_
    ) public returns (IporFusionAccessManager) {
        if (usersToRoles_.superAdmin == address(0)) {
            usersToRoles_.superAdmin = atomist;
            usersToRoles_.atomist = atomist;
            address[] memory alphas = new address[](1);
            alphas[0] = alpha;
            usersToRoles_.alphas = alphas;
        }
        return RoleLib.createAccessManager(usersToRoles_, redemptionDelay_, vm);
    }

    function setupRoles(PlasmaVault plasmaVault, IporFusionAccessManager accessManager) public {
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager);
    }

    function testShouldNotBeAbleWithdrawDuringRedemptionLockWithDifferentRecipient() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai(10 minutes);

        userOne = address(0x777);
        userTwo = address(0x888);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(amount, userTwo);

        bytes memory error = abi.encodeWithSignature("AccountIsLocked(uint256)", 1729783655);

        //when
        vm.warp(block.timestamp + 5 minutes);
        vm.expectRevert(error);
        vm.prank(userTwo);
        plasmaVault.withdraw(amount, userTwo, userTwo);
    }

    function testShouldNotBeAbleWithdrawDuringRedemptionLockWithDifferentRecipientAndApproved() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai(10 minutes);

        userOne = address(0x777);
        userTwo = address(0x888);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(amount, userTwo);

        bytes memory error = abi.encodeWithSignature("AccountIsLocked(uint256)", 1729783655);

        vm.prank(userTwo);
        plasmaVault.approve(userOne, amount);

        //when
        vm.warp(block.timestamp + 5 minutes);
        vm.expectRevert(error);
        vm.prank(userOne);
        plasmaVault.withdraw(amount, userOne, userTwo);
    }

    function testShouldBeAbleWithdrawDuringRedemptionLockWithDifferentRecipientAndApproved() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai(10 minutes);

        userOne = address(0x777);
        userTwo = address(0x888);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(amount, userTwo);

        bytes memory error = abi.encodeWithSignature("AccountIsLocked(uint256)", 1729783655);

        vm.prank(userTwo);
        plasmaVault.approve(userOne, 10 ** 2 * amount);

        uint256 userOneBalanceBefore = ERC20(DAI).balanceOf(userOne);
        //when
        vm.warp(block.timestamp + 60 minutes);
        vm.prank(userOne);
        plasmaVault.withdraw(amount, userOne, userTwo);

        uint256 userOneBalanceAfter = ERC20(DAI).balanceOf(userOne);

        assertEq(userOneBalanceAfter, userOneBalanceBefore + amount);
    }

    function testShouldNotBeAbleWithdrawDuringRedemptionLockAfterMintWithDifferentRecipient() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai(10 minutes);

        userOne = address(0x777);
        userTwo = address(0x888);

        uint256 amount = 100 * 1e18;
        uint256 sharesAmount = 100 * 10 ** plasmaVault.decimals();

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.mint(sharesAmount, userTwo);

        bytes memory error = abi.encodeWithSignature("AccountIsLocked(uint256)", 1729783655);

        //when
        vm.warp(block.timestamp + 5 minutes);
        vm.expectRevert(error);
        vm.prank(userTwo);
        plasmaVault.withdraw(amount, userTwo, userTwo);
    }

    function testShouldNotBeAbleTransferSharesDuringRedemptionLockForRecipient() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai(10 minutes);

        userOne = address(0x777);
        userTwo = address(0x888);
        address userThree = address(0x999);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(amount, userTwo);

        bytes memory error = abi.encodeWithSignature("AccountIsLocked(uint256)", 1729783655);

        //when
        vm.warp(block.timestamp + 5 minutes);
        vm.expectRevert(error);
        vm.prank(userTwo);
        plasmaVault.transfer(userThree, amount);
    }

    function testShouldNotBeAbleTransferFromSharesDuringRedemptionLockForRecipient() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai(10 minutes);

        userOne = address(0x777);
        userTwo = address(0x888);
        address userThree = address(0x999);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        vm.prank(userOne);
        plasmaVault.deposit(amount, userTwo);

        // userTwo approves userThree to transfer their shares
        vm.prank(userTwo);
        plasmaVault.approve(userThree, amount);

        bytes memory error = abi.encodeWithSignature("AccountIsLocked(uint256)", 1729783655);

        //when
        vm.warp(block.timestamp + 5 minutes);
        vm.expectRevert(error);
        vm.prank(userThree);
        plasmaVault.transferFrom(userTwo, userOne, amount);
    }
}
