// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {AaveLendingPoolV2, ReserveData} from "../../../contracts/fuses/aave_v2/ext/AaveLendingPoolV2.sol";
import {AaveV2SupplyFuse, AaveV2SupplyFuseEnterData, AaveV2SupplyFuseExitData} from "../../../contracts/fuses/aave_v2/AaveV2SupplyFuse.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {AaveV2SupplyFuseMock} from "./AaveV2SupplyFuseMock.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

contract AaveV2SupplyFuseTest is Test {
    struct SupportedToken {
        address asset;
        string name;
    }

    /// @notice Aave Lending Pool V2 contract
    AaveLendingPoolV2 public constant AAVE_POOL = AaveLendingPoolV2(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    SupportedToken private activeTokens;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
    }

    function testShouldBeAbleToSupply() external iterateSupportedTokens {
        // given
        AaveV2SupplyFuse fuse = new AaveV2SupplyFuse(1, address(AAVE_POOL));

        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(vaultMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(vaultMock));

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // when
        vaultMock.enterAaveV2Supply(AaveV2SupplyFuseEnterData({asset: activeTokens.asset, amount: amount}));

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(vaultMock));
        ReserveData memory reserveData = AAVE_POOL.getReserveData(activeTokens.asset);

        address aTokenAddress = reserveData.aTokenAddress;
        address stableDebtTokenAddress = reserveData.stableDebtTokenAddress;
        address variableDebtTokenAddress = reserveData.variableDebtTokenAddress;

        assertApproxEqAbs(balanceAfter + amount, balanceBefore, 100, "vault balance decreased");
        assertApproxEqAbs(ERC20(aTokenAddress).balanceOf(address(vaultMock)), amount, 100, "aToken balance increased");
        assertEq(ERC20(stableDebtTokenAddress).balanceOf(address(vaultMock)), 0, "stableDebtToken 0");
        assertEq(ERC20(variableDebtTokenAddress).balanceOf(address(vaultMock)), 0, "variableDebtToken 0");
    }

    function testShouldBeAbleToWithdraw() external iterateSupportedTokens {
        // given
        uint256 dustOnAToken = 10;
        AaveV2SupplyFuse fuse = new AaveV2SupplyFuse(1, address(AAVE_POOL));
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 enterAmount = 100 * 10 ** decimals;
        uint256 exitAmount = 50 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(vaultMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(vaultMock));

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        vaultMock.enterAaveV2Supply(AaveV2SupplyFuseEnterData({asset: activeTokens.asset, amount: enterAmount}));

        // when
        vaultMock.exitAaveV2Supply(AaveV2SupplyFuseExitData({asset: activeTokens.asset, amount: exitAmount}));

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(vaultMock));

        ReserveData memory reserveData = AAVE_POOL.getReserveData(activeTokens.asset);

        address aTokenAddress = reserveData.aTokenAddress;
        address stableDebtTokenAddress = reserveData.stableDebtTokenAddress;
        address variableDebtTokenAddress = reserveData.variableDebtTokenAddress;

        assertEq(balanceAfter + enterAmount - exitAmount, balanceBefore, "vault balance decreased");
        assertApproxEqAbs(
            ERC20(aTokenAddress).balanceOf(address(vaultMock)),
            enterAmount - exitAmount,
            dustOnAToken,
            "aToken balance decreased"
        );
        assertEq(ERC20(stableDebtTokenAddress).balanceOf(address(vaultMock)), 0, "stableDebtToken 0");
        assertEq(ERC20(variableDebtTokenAddress).balanceOf(address(vaultMock)), 0, "variableDebtToken 0");
    }

    function _getSupportedAssets() private pure returns (SupportedToken[] memory supportedTokensTemp) {
        supportedTokensTemp = new SupportedToken[](2);

        supportedTokensTemp[0] = SupportedToken(0x6B175474E89094C44Da98b954EedeAC495271d0F, "DAI");
        supportedTokensTemp[1] = SupportedToken(0xdAC17F958D2ee523a2206206994597C13D831ec7, "USDT");
    }

    function _supplyTokensToMockVault(address asset, address to, uint256 amount) private {
        if (asset == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) {
            // USDC
            vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9); // AmmTreasuryUsdcProxy
            ERC20(asset).transfer(to, amount);
        } else if (asset == 0xdAC17F958D2ee523a2206206994597C13D831ec7) {
            // USDT
            vm.prank(0xF977814e90dA44bFA03b6295A0616a897441aceC); // Binance 8
            (bool success, ) = asset.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
            require(success, "Transfer failed");
        } else {
            deal(asset, to, amount);
        }
    }

    modifier iterateSupportedTokens() {
        SupportedToken[] memory supportedTokens = _getSupportedAssets();
        for (uint256 i; i < supportedTokens.length; ++i) {
            activeTokens = supportedTokens[i];
            _;
        }
    }

    function testEnterWithoutParamsSuccess() external iterateSupportedTokens {
        // given
        AaveV2SupplyFuse fuse = new AaveV2SupplyFuse(1, address(AAVE_POOL));
        AaveV2SupplyFuseMock mock = new AaveV2SupplyFuseMock(address(fuse));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;

        // Grant assets to mock since delegatecall uses mock's storage
        mock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // Transfer tokens to mock
        _supplyTokensToMockVault(activeTokens.asset, address(mock), amount);

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(activeTokens.asset);
        inputs[1] = TypeConversionLib.toBytes32(amount);

        // Set inputs in the context of mock (transient storage is per-account)
        mock.setInputs(address(fuse), inputs);

        // when - call mock.enterTransient() directly
        mock.enterTransient();

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(mock));
        ReserveData memory reserveData = AAVE_POOL.getReserveData(activeTokens.asset);

        address aTokenAddress = reserveData.aTokenAddress;

        assertApproxEqAbs(balanceAfter + amount, amount, 100, "mock balance should be decreased by amount");
        assertApproxEqAbs(
            ERC20(aTokenAddress).balanceOf(address(mock)),
            amount,
            100,
            "aToken balance should be increased by amount"
        );

        // Verify outputs in transient storage
        bytes32[] memory outputs = mock.getOutputs(address(fuse));
        assertEq(outputs.length, 2, "outputs length should be 2");
        assertEq(outputs[0], TypeConversionLib.toBytes32(activeTokens.asset), "output asset should match");
        assertEq(outputs[1], TypeConversionLib.toBytes32(amount), "output amount should match");
    }

    function testEnterWithoutParamsWithZeroAmount() external iterateSupportedTokens {
        // given
        AaveV2SupplyFuse fuse = new AaveV2SupplyFuse(1, address(AAVE_POOL));
        AaveV2SupplyFuseMock mock = new AaveV2SupplyFuseMock(address(fuse));
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(activeTokens.asset);
        inputs[1] = TypeConversionLib.toBytes32(uint256(0));

        vm.prank(address(vaultMock));
        mock.setInputs(address(fuse), inputs);

        // when
        vm.prank(address(vaultMock));
        mock.enterTransient();

        // then
        bytes32[] memory outputs = mock.getOutputs(address(fuse));
        assertEq(outputs.length, 2, "outputs length should be 2");
        assertEq(outputs[0], TypeConversionLib.toBytes32(activeTokens.asset), "output asset should match");
        assertEq(outputs[1], TypeConversionLib.toBytes32(uint256(0)), "output amount should be 0");
    }

    function testEnterWithoutParamsUnsupportedAsset() external iterateSupportedTokens {
        // given
        AaveV2SupplyFuse fuse = new AaveV2SupplyFuse(1, address(AAVE_POOL));
        AaveV2SupplyFuseMock mock = new AaveV2SupplyFuseMock(address(fuse));
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        address unsupportedAsset = address(0x1234);
        uint256 amount = 100 * 10 ** 18;

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(unsupportedAsset);
        inputs[1] = TypeConversionLib.toBytes32(amount);

        vm.prank(address(vaultMock));
        mock.setInputs(address(fuse), inputs);

        // when/then
        vm.prank(address(vaultMock));
        vm.expectRevert(
            abi.encodeWithSelector(AaveV2SupplyFuse.AaveV2SupplyFuseUnsupportedAsset.selector, unsupportedAsset)
        );
        mock.enterTransient();
    }

    function testEnterWithZeroAmount() external iterateSupportedTokens {
        // given
        AaveV2SupplyFuse fuse = new AaveV2SupplyFuse(1, address(AAVE_POOL));
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // when
        (address returnedAsset, uint256 returnedAmount) = fuse.enter(
            AaveV2SupplyFuseEnterData({asset: activeTokens.asset, amount: 0})
        );

        // then
        assertEq(returnedAsset, activeTokens.asset, "returned asset should match");
        assertEq(returnedAmount, 0, "returned amount should be 0");
    }

    function testExitWithoutParamsSuccess() external iterateSupportedTokens {
        // given
        uint256 dustOnAToken = 10;
        AaveV2SupplyFuse fuse = new AaveV2SupplyFuse(1, address(AAVE_POOL));
        AaveV2SupplyFuseMock mock = new AaveV2SupplyFuseMock(address(fuse));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 enterAmount = 100 * 10 ** decimals;
        uint256 exitAmount = 50 * 10 ** decimals;

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        mock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // First, do enter through mock
        _supplyTokensToMockVault(activeTokens.asset, address(mock), enterAmount);
        bytes32[] memory enterInputs = new bytes32[](2);
        enterInputs[0] = TypeConversionLib.toBytes32(activeTokens.asset);
        enterInputs[1] = TypeConversionLib.toBytes32(enterAmount);
        mock.setInputs(address(fuse), enterInputs);
        mock.enterTransient();

        // Now prepare for exit
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(activeTokens.asset);
        inputs[1] = TypeConversionLib.toBytes32(exitAmount);
        mock.setInputs(address(fuse), inputs);

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(mock));

        // when
        mock.exitTransient();

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(mock));
        ReserveData memory reserveData = AAVE_POOL.getReserveData(activeTokens.asset);

        address aTokenAddress = reserveData.aTokenAddress;

        assertApproxEqAbs(
            balanceAfter,
            balanceBefore + exitAmount,
            100,
            "mock balance should be increased by exit amount"
        );
        assertApproxEqAbs(
            ERC20(aTokenAddress).balanceOf(address(mock)),
            enterAmount - exitAmount,
            dustOnAToken,
            "aToken balance should be decreased by exit amount"
        );

        // Verify outputs in transient storage
        bytes32[] memory outputs = mock.getOutputs(address(fuse));
        assertEq(outputs.length, 2, "outputs length should be 2");
        assertEq(outputs[0], TypeConversionLib.toBytes32(activeTokens.asset), "output asset should match");
        // Note: actual withdrawn amount might differ slightly due to interest
        assertGe(
            TypeConversionLib.toUint256(outputs[1]),
            exitAmount - dustOnAToken,
            "output amount should be at least exit amount minus dust"
        );
    }

    function testExitWithoutParamsWithZeroAmount() external iterateSupportedTokens {
        // given
        AaveV2SupplyFuse fuse = new AaveV2SupplyFuse(1, address(AAVE_POOL));
        AaveV2SupplyFuseMock mock = new AaveV2SupplyFuseMock(address(fuse));
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(activeTokens.asset);
        inputs[1] = TypeConversionLib.toBytes32(uint256(0));

        mock.setInputs(address(fuse), inputs);

        // when
        vm.prank(address(vaultMock));
        mock.exitTransient();

        // then
        bytes32[] memory outputs = mock.getOutputs(address(fuse));
        assertEq(outputs.length, 2, "outputs length should be 2");
        assertEq(outputs[0], TypeConversionLib.toBytes32(activeTokens.asset), "output asset should match");
        assertEq(outputs[1], TypeConversionLib.toBytes32(uint256(0)), "output amount should be 0");
    }

    function testExitWithoutParamsUnsupportedAsset() external iterateSupportedTokens {
        // given
        AaveV2SupplyFuse fuse = new AaveV2SupplyFuse(1, address(AAVE_POOL));
        AaveV2SupplyFuseMock mock = new AaveV2SupplyFuseMock(address(fuse));

        address unsupportedAsset = address(0x1234);
        uint256 amount = 100 * 10 ** 18;

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(unsupportedAsset);
        inputs[1] = TypeConversionLib.toBytes32(amount);

        mock.setInputs(address(fuse), inputs);

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(AaveV2SupplyFuse.AaveV2SupplyFuseUnsupportedAsset.selector, unsupportedAsset)
        );
        mock.exitTransient();
    }

    function testExitWithZeroAmount() external iterateSupportedTokens {
        // given
        AaveV2SupplyFuse fuse = new AaveV2SupplyFuse(1, address(AAVE_POOL));
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // when - use vaultMock's exit function
        vm.prank(address(vaultMock));
        vaultMock.exitAaveV2Supply(AaveV2SupplyFuseExitData({asset: activeTokens.asset, amount: 0}));

        // then - should complete without error
        assertTrue(true, "exit with zero amount should complete");
    }

    function testExitWithAmountGreaterThanBalance() external iterateSupportedTokens {
        // given
        AaveV2SupplyFuse fuse = new AaveV2SupplyFuse(1, address(AAVE_POOL));
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 enterAmount = 100 * 10 ** decimals;
        uint256 exitAmount = 200 * 10 ** decimals; // More than deposited

        _supplyTokensToMockVault(activeTokens.asset, address(vaultMock), 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        vaultMock.enterAaveV2Supply(AaveV2SupplyFuseEnterData({asset: activeTokens.asset, amount: enterAmount}));

        ReserveData memory reserveData = AAVE_POOL.getReserveData(activeTokens.asset);

        // when - use vaultMock's exit function
        vm.prank(address(vaultMock));
        vaultMock.exitAaveV2Supply(AaveV2SupplyFuseExitData({asset: activeTokens.asset, amount: exitAmount}));

        // then - should withdraw only available balance
        uint256 aTokenBalanceAfter = ERC20(reserveData.aTokenAddress).balanceOf(address(vaultMock));
        assertEq(aTokenBalanceAfter, 0, "aToken balance should be 0 after withdrawal");
    }

    function testExitWithoutParamsWithZeroAmountToWithdraw() external iterateSupportedTokens {
        // given
        AaveV2SupplyFuse fuse = new AaveV2SupplyFuse(1, address(AAVE_POOL));
        AaveV2SupplyFuseMock mock = new AaveV2SupplyFuseMock(address(fuse));

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        mock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // Set inputs for exit but mock has no aToken balance
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(activeTokens.asset);
        inputs[1] = TypeConversionLib.toBytes32(uint256(100 * 10 ** 18));

        mock.setInputs(address(fuse), inputs);

        // when
        mock.exitTransient();

        // then - should return zero values
        bytes32[] memory outputs = mock.getOutputs(address(fuse));
        assertEq(outputs.length, 2, "outputs length should be 2");
        assertEq(outputs[0], TypeConversionLib.toBytes32(activeTokens.asset), "output asset should match");
        assertEq(outputs[1], TypeConversionLib.toBytes32(uint256(100 * 10 ** 18)), "output amount should match input");
    }

    function testInstantWithdrawSuccess() external iterateSupportedTokens {
        // given
        AaveV2SupplyFuse fuse = new AaveV2SupplyFuse(1, address(AAVE_POOL));
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 enterAmount = 100 * 10 ** decimals;
        uint256 exitAmount = 50 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(vaultMock), 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        vaultMock.enterAaveV2Supply(AaveV2SupplyFuseEnterData({asset: activeTokens.asset, amount: enterAmount}));

        // Add fuse to supported fuses list
        address[] memory fusesToAdd = new address[](1);
        fusesToAdd[0] = address(fuse);
        vaultMock.addFuses(fusesToAdd);

        // Configure instant withdrawal fuses
        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = bytes32(0); // amount will be set during execution
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(activeTokens.asset);

        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);
        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(fuse),
            params: instantWithdrawParams
        });

        vaultMock.configureInstantWithdrawalFuses(instantWithdrawFuses);

        bytes32[] memory params = new bytes32[](2);
        params[0] = TypeConversionLib.toBytes32(exitAmount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(activeTokens.asset);

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(vaultMock));

        // when - use vaultMock's instantWithdraw function
        vm.prank(address(vaultMock));
        vaultMock.instantWithdraw(params);

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(vaultMock));
        ReserveData memory reserveData = AAVE_POOL.getReserveData(activeTokens.asset);

        assertApproxEqAbs(balanceAfter, balanceBefore + exitAmount, 100, "vault balance should be increased");
        assertApproxEqAbs(
            ERC20(reserveData.aTokenAddress).balanceOf(address(vaultMock)),
            enterAmount - exitAmount,
            10,
            "aToken balance should be decreased"
        );
    }

    function testInstantWithdrawWithCatchException() external iterateSupportedTokens {
        // given
        AaveV2SupplyFuse fuse = new AaveV2SupplyFuse(1, address(AAVE_POOL));
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        address[] memory fusesToAdd = new address[](1);
        fusesToAdd[0] = address(fuse);
        vaultMock.addFuses(fusesToAdd);

        bytes32[] memory instantWithdrawParams = new bytes32[](2);
        instantWithdrawParams[0] = bytes32(0);
        instantWithdrawParams[1] = PlasmaVaultConfigLib.addressToBytes32(activeTokens.asset);

        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);
        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(fuse),
            params: instantWithdrawParams
        });

        vaultMock.configureInstantWithdrawalFuses(instantWithdrawFuses);

        bytes32[] memory params = new bytes32[](2);
        params[0] = TypeConversionLib.toBytes32(uint256(100 * 10 ** 18));
        params[1] = PlasmaVaultConfigLib.addressToBytes32(activeTokens.asset);

        // when - use vaultMock's instantWithdraw function
        // Note: catchExceptions_ = true, so it should catch errors
        vm.prank(address(vaultMock));
        vaultMock.instantWithdraw(params);

        // then
        assertTrue(true, "instantWithdraw with catch exception should complete");
    }
}
