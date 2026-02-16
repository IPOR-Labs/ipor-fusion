// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Erc4626SupplyFuse} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626SupplyFuseEnterData, Erc4626SupplyFuseExitData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {IWETH9} from "./IWETH9.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";

contract Erc4626SupplyFuseTest is Test {
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19538857);
    }

    function testShouldBeAbleToSupplyWethToMetaMorpho() external {
        // given
        //https://app.morpho.org/vault?vault=0x38989BBA00BDF8181F4082995b3DEAe96163aC5D
        address marketAddress = 0x38989BBA00BDF8181F4082995b3DEAe96163aC5D;
        IERC4626 vault = IERC4626(marketAddress);
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        uint256 decimals = vault.decimals();
        uint256 amount = 100 * 10 ** decimals;

        deal(address(vaultMock), 1_000 * 10 ** decimals);
        vm.prank(address(vaultMock));
        IWETH9(WETH).deposit{value: 1_000 * 10 ** decimals}();

        uint256 balanceBefore = ERC20(vault.asset()).balanceOf(address(vaultMock));
        uint256 balanceOnMarketBefore = vault.balanceOf(address(vaultMock));

        address[] memory assets = new address[](1);
        assets[0] = address(vault);
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // when
        vaultMock.enterErc4626Supply(Erc4626SupplyFuseEnterData({vault: marketAddress, vaultAssetAmount: amount, minSharesOut: 0}));

        // then
        uint256 balanceAfter = ERC20(vault.asset()).balanceOf(address(vaultMock));
        uint256 balanceOnCometAfter = vault.balanceOf(address(vaultMock));

        assertEq(balanceAfter + amount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(balanceOnCometAfter > balanceOnMarketBefore, "collateral balance should be increased by amount");
    }

    function testShouldBeAbleToSupplyWethToMetaMorphoUsingTransientStorage() external {
        // given
        address marketAddress = 0x38989BBA00BDF8181F4082995b3DEAe96163aC5D;
        IERC4626 vault = IERC4626(marketAddress);
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        uint256 decimals = vault.decimals();
        uint256 amount = 100 * 10 ** decimals;

        deal(address(vaultMock), 1_000 * 10 ** decimals);
        vm.prank(address(vaultMock));
        IWETH9(WETH).deposit{value: 1_000 * 10 ** decimals}();

        uint256 balanceBefore = ERC20(vault.asset()).balanceOf(address(vaultMock));
        uint256 balanceOnMarketBefore = vault.balanceOf(address(vaultMock));

        address[] memory assets = new address[](1);
        assets[0] = address(vault);
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(marketAddress);
        inputs[1] = TypeConversionLib.toBytes32(amount);
        inputs[2] = TypeConversionLib.toBytes32(uint256(0));
        vaultMock.setInputs(address(fuse), inputs);

        // when
        vaultMock.enterErc4626SupplyTransient();

        // then
        uint256 balanceAfter = ERC20(vault.asset()).balanceOf(address(vaultMock));
        uint256 balanceOnCometAfter = vault.balanceOf(address(vaultMock));

        assertEq(balanceAfter + amount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(balanceOnCometAfter > balanceOnMarketBefore, "collateral balance should be increased by amount");

        bytes32[] memory outputs = vaultMock.getOutputs(address(fuse));
        assertEq(outputs.length, 1, "should have 1 output");
        assertEq(TypeConversionLib.toUint256(outputs[0]), amount, "output amount should match input amount");
    }

    function testShouldBeAbleToWithdrawWethFromMetaMorpho() external {
        // given
        //https://app.morpho.org/vault?vault=0x38989BBA00BDF8181F4082995b3DEAe96163aC5D
        address marketAddress = 0x38989BBA00BDF8181F4082995b3DEAe96163aC5D;
        IERC4626 vault = IERC4626(marketAddress);
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        uint256 decimals = vault.decimals();
        uint256 amount = 100 * 10 ** decimals;

        //        _supplyTokensToMockVault(vault.asset(), address(vaultMock), 1_000 * 10 ** decimals);
        deal(address(vaultMock), 1_000 * 10 ** decimals);
        vm.prank(address(vaultMock));
        IWETH9(WETH).deposit{value: 1_000 * 10 ** decimals}();

        address[] memory assets = new address[](1);
        assets[0] = address(vault);
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);
        vaultMock.enterErc4626Supply(Erc4626SupplyFuseEnterData({vault: marketAddress, vaultAssetAmount: amount, minSharesOut: 0}));

        uint256 balanceBefore = ERC20(vault.asset()).balanceOf(address(vaultMock));
        uint256 balanceOnMarketBefore = vault.balanceOf(address(vaultMock));

        // when
        vaultMock.exitErc4626Supply(Erc4626SupplyFuseExitData({vault: marketAddress, vaultAssetAmount: amount / 2, maxSharesBurned: 0}));

        // then
        uint256 balanceAfter = ERC20(vault.asset()).balanceOf(address(vaultMock));
        uint256 balanceOnCometAfter = vault.balanceOf(address(vaultMock));

        assertTrue(balanceAfter > balanceBefore, "vault balance should be increased");
        assertTrue(balanceOnCometAfter < balanceOnMarketBefore, "collateral balance should be decreased");
    }

    function testShouldBeAbleToWithdrawWethFromMetaMorphoUsingTransientStorage() external {
        // given
        address marketAddress = 0x38989BBA00BDF8181F4082995b3DEAe96163aC5D;
        IERC4626 vault = IERC4626(marketAddress);
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        uint256 decimals = vault.decimals();
        uint256 amount = 100 * 10 ** decimals;

        deal(address(vaultMock), 1_000 * 10 ** decimals);
        vm.prank(address(vaultMock));
        IWETH9(WETH).deposit{value: 1_000 * 10 ** decimals}();

        address[] memory assets = new address[](1);
        assets[0] = address(vault);
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);
        vaultMock.enterErc4626Supply(Erc4626SupplyFuseEnterData({vault: marketAddress, vaultAssetAmount: amount, minSharesOut: 0}));

        uint256 balanceBefore = ERC20(vault.asset()).balanceOf(address(vaultMock));
        uint256 balanceOnMarketBefore = vault.balanceOf(address(vaultMock));

        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(marketAddress);
        inputs[1] = TypeConversionLib.toBytes32(amount / 2);
        inputs[2] = TypeConversionLib.toBytes32(uint256(0));
        vaultMock.setInputs(address(fuse), inputs);

        // when
        vaultMock.exitErc4626SupplyTransient();

        // then
        uint256 balanceAfter = ERC20(vault.asset()).balanceOf(address(vaultMock));
        uint256 balanceOnCometAfter = vault.balanceOf(address(vaultMock));

        assertTrue(balanceAfter > balanceBefore, "vault balance should be increased");
        assertTrue(balanceOnCometAfter < balanceOnMarketBefore, "collateral balance should be decreased");

        bytes32[] memory outputs = vaultMock.getOutputs(address(fuse));
        assertEq(outputs.length, 1, "should have 1 output");
        assertTrue(TypeConversionLib.toUint256(outputs[0]) > 0, "should return shares");
    }

    function testShouldRevertWhenEnteringTransientWithUnsupportedVault() external {
        // given
        address marketAddress = 0x38989BBA00BDF8181F4082995b3DEAe96163aC5D;
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(marketAddress);
        inputs[1] = TypeConversionLib.toBytes32(uint256(100));
        inputs[2] = TypeConversionLib.toBytes32(uint256(0));
        vaultMock.setInputs(address(fuse), inputs);

        // when
        vm.expectRevert(
            abi.encodeWithSelector(Erc4626SupplyFuse.Erc4626SupplyFuseUnsupportedVault.selector, "enter", marketAddress)
        );
        vaultMock.enterErc4626SupplyTransient();
    }

    function testShouldRevertWhenExitingTransientWithUnsupportedVault() external {
        // given
        address marketAddress = 0x38989BBA00BDF8181F4082995b3DEAe96163aC5D;
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(marketAddress);
        inputs[1] = TypeConversionLib.toBytes32(uint256(100));
        inputs[2] = TypeConversionLib.toBytes32(uint256(0));
        vaultMock.setInputs(address(fuse), inputs);

        // when
        vm.expectRevert(
            abi.encodeWithSelector(Erc4626SupplyFuse.Erc4626SupplyFuseUnsupportedVault.selector, "exit", marketAddress)
        );
        vaultMock.exitErc4626SupplyTransient();
    }

    function testShouldReturnZeroWhenEnteringTransientWithZeroAmount() external {
        // given
        address marketAddress = 0x38989BBA00BDF8181F4082995b3DEAe96163aC5D;
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(marketAddress);
        inputs[1] = TypeConversionLib.toBytes32(uint256(0));
        inputs[2] = TypeConversionLib.toBytes32(uint256(0));
        vaultMock.setInputs(address(fuse), inputs);

        // when
        vaultMock.enterErc4626SupplyTransient();

        // then
        bytes32[] memory outputs = vaultMock.getOutputs(address(fuse));
        assertEq(outputs.length, 1, "should have 1 output");
        assertEq(TypeConversionLib.toUint256(outputs[0]), 0, "should return 0");
    }

    function testShouldReturnZeroWhenExitingTransientWithZeroAmount() external {
        // given
        address marketAddress = 0x38989BBA00BDF8181F4082995b3DEAe96163aC5D;
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(marketAddress);
        inputs[1] = TypeConversionLib.toBytes32(uint256(0));
        inputs[2] = TypeConversionLib.toBytes32(uint256(0));
        vaultMock.setInputs(address(fuse), inputs);

        // when
        vaultMock.exitErc4626SupplyTransient();

        // then
        bytes32[] memory outputs = vaultMock.getOutputs(address(fuse));
        assertEq(outputs.length, 1, "should have 1 output");
        assertEq(TypeConversionLib.toUint256(outputs[0]), 0, "should return 0");
    }

    function testShouldReturnZeroWhenEnteringTransientWithZeroBalance() external {
        // given
        address marketAddress = 0x38989BBA00BDF8181F4082995b3DEAe96163aC5D;
        IERC4626 vault = IERC4626(marketAddress);
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        address[] memory assets = new address[](1);
        assets[0] = address(vault);
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(marketAddress);
        inputs[1] = TypeConversionLib.toBytes32(uint256(100)); // Amount > 0 but balance is 0
        inputs[2] = TypeConversionLib.toBytes32(uint256(0));
        vaultMock.setInputs(address(fuse), inputs);

        // when
        vaultMock.enterErc4626SupplyTransient();

        // then
        bytes32[] memory outputs = vaultMock.getOutputs(address(fuse));
        assertEq(outputs.length, 1, "should have 1 output");
        assertEq(TypeConversionLib.toUint256(outputs[0]), 0, "should return 0");
    }

    function testShouldReturnZeroWhenExitingTransientWithZeroBalance() external {
        // given
        address marketAddress = 0x38989BBA00BDF8181F4082995b3DEAe96163aC5D;
        IERC4626 vault = IERC4626(marketAddress);
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        address[] memory assets = new address[](1);
        assets[0] = address(vault);
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // Don't supply anything so balance in vault is 0

        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(marketAddress);
        inputs[1] = TypeConversionLib.toBytes32(uint256(100)); // Amount > 0 but balance in vault is 0
        inputs[2] = TypeConversionLib.toBytes32(uint256(0));
        vaultMock.setInputs(address(fuse), inputs);

        // when
        vaultMock.exitErc4626SupplyTransient();

        // then
        bytes32[] memory outputs = vaultMock.getOutputs(address(fuse));
        assertEq(outputs.length, 1, "should have 1 output");
        assertEq(TypeConversionLib.toUint256(outputs[0]), 0, "should return 0");
    }

    function testShouldBeAbleToSupplyDaiToMetaMorpho() external {
        // given
        //https://app.morpho.org/vault?vault=0x500331c9fF24D9d11aee6B07734Aa72343EA74a5
        address marketAddress = 0x500331c9fF24D9d11aee6B07734Aa72343EA74a5;
        IERC4626 vault = IERC4626(marketAddress);
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        uint256 decimals = vault.decimals();
        uint256 amount = 100 * 10 ** decimals;

        deal(vault.asset(), address(vaultMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(vault.asset()).balanceOf(address(vaultMock));
        uint256 balanceOnMarketBefore = vault.balanceOf(address(vaultMock));

        address[] memory assets = new address[](1);
        assets[0] = address(vault);
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // when
        vaultMock.enterErc4626Supply(Erc4626SupplyFuseEnterData({vault: marketAddress, vaultAssetAmount: amount, minSharesOut: 0}));

        // then
        uint256 balanceAfter = ERC20(vault.asset()).balanceOf(address(vaultMock));
        uint256 balanceOnCometAfter = vault.balanceOf(address(vaultMock));

        assertEq(balanceAfter + amount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(balanceOnCometAfter > balanceOnMarketBefore, "collateral balance should be increased by amount");
    }

    function testShouldBeAbleToWithdrawDaiFromMetaMorpho() external {
        // given
        //https://app.morpho.org/vault?vault=0x500331c9fF24D9d11aee6B07734Aa72343EA74a5
        address marketAddress = 0x500331c9fF24D9d11aee6B07734Aa72343EA74a5;
        IERC4626 vault = IERC4626(marketAddress);
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        uint256 decimals = vault.decimals();
        uint256 amount = 100 * 10 ** decimals;

        deal(vault.asset(), address(vaultMock), 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = address(vault);
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);
        vaultMock.enterErc4626Supply(Erc4626SupplyFuseEnterData({vault: marketAddress, vaultAssetAmount: amount, minSharesOut: 0}));

        uint256 balanceBefore = ERC20(vault.asset()).balanceOf(address(vaultMock));
        uint256 balanceOnMarketBefore = vault.balanceOf(address(vaultMock));

        // when
        vaultMock.exitErc4626Supply(Erc4626SupplyFuseExitData({vault: marketAddress, vaultAssetAmount: amount / 2, maxSharesBurned: 0}));

        // then
        uint256 balanceAfter = ERC20(vault.asset()).balanceOf(address(vaultMock));
        uint256 balanceOnCometAfter = vault.balanceOf(address(vaultMock));

        assertTrue(balanceAfter > balanceBefore, "vault balance should be increased");
        assertTrue(balanceOnCometAfter < balanceOnMarketBefore, "collateral balance should be decreased");
    }

    function testShouldBeAbleToInstantWithdrawWethFromMetaMorpho() external {
        // given
        address marketAddress = 0x38989BBA00BDF8181F4082995b3DEAe96163aC5D;
        IERC4626 vault = IERC4626(marketAddress);
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        uint256 decimals = vault.decimals();
        uint256 amount = 100 * 10 ** decimals;

        deal(address(vaultMock), 1_000 * 10 ** decimals);
        vm.prank(address(vaultMock));
        IWETH9(WETH).deposit{value: 1_000 * 10 ** decimals}();

        address[] memory assets = new address[](1);
        assets[0] = address(vault);
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);
        vaultMock.enterErc4626Supply(Erc4626SupplyFuseEnterData({vault: marketAddress, vaultAssetAmount: amount, minSharesOut: 0}));

        uint256 balanceBefore = ERC20(vault.asset()).balanceOf(address(vaultMock));

        // when
        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(amount / 2); // amount
        params[1] = TypeConversionLib.toBytes32(marketAddress); // vault

        vaultMock.instantWithdraw(params);

        // then
        uint256 balanceAfter = ERC20(vault.asset()).balanceOf(address(vaultMock));
        assertTrue(balanceAfter > balanceBefore, "vault balance should be increased");
    }

    function testShouldRevertWhenSharesBelowMinSharesOut() external {
        // given
        address marketAddress = 0x38989BBA00BDF8181F4082995b3DEAe96163aC5D;
        IERC4626 vault = IERC4626(marketAddress);
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        uint256 decimals = vault.decimals();
        uint256 amount = 100 * 10 ** decimals;

        deal(address(vaultMock), 1_000 * 10 ** decimals);
        vm.prank(address(vaultMock));
        IWETH9(WETH).deposit{value: 1_000 * 10 ** decimals}();

        address[] memory assets = new address[](1);
        assets[0] = address(vault);
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // when
        vm.expectRevert(
            abi.encodeWithSelector(
                Erc4626SupplyFuse.Erc4626SupplyFuseInsufficientShares.selector,
                vault.previewDeposit(amount),
                type(uint256).max
            )
        );
        vaultMock.enterErc4626Supply(
            Erc4626SupplyFuseEnterData({vault: marketAddress, vaultAssetAmount: amount, minSharesOut: type(uint256).max})
        );
    }

    function testShouldSupplyWhenMinSharesOutMet() external {
        // given
        address marketAddress = 0x38989BBA00BDF8181F4082995b3DEAe96163aC5D;
        IERC4626 vault = IERC4626(marketAddress);
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        uint256 decimals = vault.decimals();
        uint256 amount = 100 * 10 ** decimals;

        deal(address(vaultMock), 1_000 * 10 ** decimals);
        vm.prank(address(vaultMock));
        IWETH9(WETH).deposit{value: 1_000 * 10 ** decimals}();

        uint256 balanceBefore = ERC20(vault.asset()).balanceOf(address(vaultMock));
        uint256 balanceOnMarketBefore = vault.balanceOf(address(vaultMock));

        address[] memory assets = new address[](1);
        assets[0] = address(vault);
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        uint256 expectedShares = vault.previewDeposit(amount);

        // when
        vaultMock.enterErc4626Supply(
            Erc4626SupplyFuseEnterData({vault: marketAddress, vaultAssetAmount: amount, minSharesOut: expectedShares})
        );

        // then
        uint256 balanceAfter = ERC20(vault.asset()).balanceOf(address(vaultMock));
        uint256 balanceOnCometAfter = vault.balanceOf(address(vaultMock));

        assertEq(balanceAfter + amount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(balanceOnCometAfter > balanceOnMarketBefore, "collateral balance should be increased by amount");
    }

    function testShouldRevertWhenSharesBurnedExceedsMax() external {
        // given
        address marketAddress = 0x38989BBA00BDF8181F4082995b3DEAe96163aC5D;
        IERC4626 vault = IERC4626(marketAddress);
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        uint256 decimals = vault.decimals();
        uint256 amount = 100 * 10 ** decimals;

        deal(address(vaultMock), 1_000 * 10 ** decimals);
        vm.prank(address(vaultMock));
        IWETH9(WETH).deposit{value: 1_000 * 10 ** decimals}();

        address[] memory assets = new address[](1);
        assets[0] = address(vault);
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);
        vaultMock.enterErc4626Supply(Erc4626SupplyFuseEnterData({vault: marketAddress, vaultAssetAmount: amount, minSharesOut: 0}));

        // when
        vm.expectRevert(
            abi.encodeWithSelector(
                Erc4626SupplyFuse.Erc4626SupplyFuseExcessiveSharesBurned.selector,
                vault.previewWithdraw(amount / 2),
                1
            )
        );
        vaultMock.exitErc4626Supply(
            Erc4626SupplyFuseExitData({vault: marketAddress, vaultAssetAmount: amount / 2, maxSharesBurned: 1})
        );
    }

    function testShouldWithdrawWhenMaxSharesBurnedMet() external {
        // given
        address marketAddress = 0x38989BBA00BDF8181F4082995b3DEAe96163aC5D;
        IERC4626 vault = IERC4626(marketAddress);
        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        uint256 decimals = vault.decimals();
        uint256 amount = 100 * 10 ** decimals;

        deal(address(vaultMock), 1_000 * 10 ** decimals);
        vm.prank(address(vaultMock));
        IWETH9(WETH).deposit{value: 1_000 * 10 ** decimals}();

        uint256 balanceBefore = ERC20(vault.asset()).balanceOf(address(vaultMock));

        address[] memory assets = new address[](1);
        assets[0] = address(vault);
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);
        vaultMock.enterErc4626Supply(Erc4626SupplyFuseEnterData({vault: marketAddress, vaultAssetAmount: amount, minSharesOut: 0}));

        uint256 expectedShares = vault.previewWithdraw(amount / 2);

        // when
        vaultMock.exitErc4626Supply(
            Erc4626SupplyFuseExitData({vault: marketAddress, vaultAssetAmount: amount / 2, maxSharesBurned: expectedShares})
        );

        // then
        uint256 balanceAfter = ERC20(vault.asset()).balanceOf(address(vaultMock));
        assertTrue(balanceAfter > balanceBefore - amount, "vault balance should reflect partial withdrawal");
    }

    function _supplyTokensToMockVault(address asset, address to, uint256 amount) private {
        deal(asset, to, amount);
    }
}

import {MockERC20} from "../../test_helpers/MockERC20.sol";
import {MockERC4626} from "../../test_helpers/MockErc4626.sol";
import {MockERC4626WithFee} from "../../test_helpers/MockERC4626WithFee.sol";

contract Erc4626SupplyFuseWithFeeTest is Test {
    uint256 private constant MARKET_ID = 1;
    uint256 private constant DEPOSIT_AMOUNT = 1_000e18;
    uint256 private constant WITHDRAWAL_FEE_BPS = 500; // 5%

    MockERC20 private underlyingToken;
    MockERC4626WithFee private feeVault;
    MockERC4626 private standardVault;
    Erc4626SupplyFuse private fuse;
    PlasmaVaultMock private vaultMock;

    function setUp() public {
        underlyingToken = new MockERC20("Mock Token", "MTK", 18);
        feeVault = new MockERC4626WithFee(underlyingToken, "Fee Vault", "fVLT", WITHDRAWAL_FEE_BPS);
        standardVault = new MockERC4626(underlyingToken, "Standard Vault", "sVLT");
        fuse = new Erc4626SupplyFuse(MARKET_ID);
        vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        // Grant both vaults as substrates
        address[] memory assets = new address[](2);
        assets[0] = address(feeVault);
        assets[1] = address(standardVault);
        vaultMock.grantAssetsToMarket(MARKET_ID, assets);
    }

    function _depositToFeeVault(uint256 amount) private {
        underlyingToken.mint(address(vaultMock), amount);
        vaultMock.enterErc4626Supply(
            Erc4626SupplyFuseEnterData({vault: address(feeVault), vaultAssetAmount: amount})
        );
    }

    function _depositToStandardVault(uint256 amount) private {
        underlyingToken.mint(address(vaultMock), amount);
        vaultMock.enterErc4626Supply(
            Erc4626SupplyFuseEnterData({vault: address(standardVault), vaultAssetAmount: amount})
        );
    }

    /// @notice Full exit from a fee-bearing vault succeeds using maxWithdraw.
    /// With the old `convertToAssets(balanceOf)` approach, this would revert
    /// with ERC4626ExceededMaxWithdraw because convertToAssets overestimates
    /// the actual withdrawable amount.
    function testShouldExitFromFeeVaultUsingMaxWithdraw() external {
        // given
        _depositToFeeVault(DEPOSIT_AMOUNT);

        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));
        uint256 sharesBefore = feeVault.balanceOf(address(vaultMock));
        assertTrue(sharesBefore > 0, "should have shares after deposit");

        // Verify that maxWithdraw < convertToAssets (the fee creates the gap)
        uint256 maxWithdrawAmount = feeVault.maxWithdraw(address(vaultMock));
        uint256 convertToAssetsAmount = feeVault.convertToAssets(sharesBefore);
        assertTrue(maxWithdrawAmount < convertToAssetsAmount, "maxWithdraw should be less than convertToAssets for fee vault");

        // when - request full exit (type(uint256).max to trigger cap)
        vaultMock.exitErc4626Supply(
            Erc4626SupplyFuseExitData({vault: address(feeVault), vaultAssetAmount: type(uint256).max})
        );

        // then
        uint256 balanceAfter = underlyingToken.balanceOf(address(vaultMock));
        uint256 sharesAfter = feeVault.balanceOf(address(vaultMock));

        assertTrue(balanceAfter > balanceBefore, "underlying balance should increase after exit");
        assertEq(sharesAfter, 0, "all shares should be redeemed after full exit");
    }

    /// @notice When requested amount exceeds maxWithdraw, it gets capped to maxWithdraw.
    function testShouldCapExitAmountToMaxWithdrawForFeeVault() external {
        // given
        _depositToFeeVault(DEPOSIT_AMOUNT);

        uint256 maxWithdrawAmount = feeVault.maxWithdraw(address(vaultMock));
        uint256 requestedAmount = maxWithdrawAmount + 100e18; // Request more than maxWithdraw

        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));

        // when
        vaultMock.exitErc4626Supply(
            Erc4626SupplyFuseExitData({vault: address(feeVault), vaultAssetAmount: requestedAmount})
        );

        // then
        uint256 balanceAfter = underlyingToken.balanceOf(address(vaultMock));
        uint256 withdrawn = balanceAfter - balanceBefore;

        // Withdrawn amount should equal maxWithdraw (capped)
        assertEq(withdrawn, maxWithdrawAmount, "withdrawn amount should be capped to maxWithdraw");
    }

    /// @notice Partial withdrawal (amount < maxWithdraw) works correctly with fee vault.
    function testShouldExitPartialAmountFromFeeVault() external {
        // given
        _depositToFeeVault(DEPOSIT_AMOUNT);

        uint256 maxWithdrawAmount = feeVault.maxWithdraw(address(vaultMock));
        uint256 partialAmount = maxWithdrawAmount / 2;
        assertTrue(partialAmount > 0, "partial amount should be positive");

        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));
        uint256 sharesBefore = feeVault.balanceOf(address(vaultMock));

        // when
        vaultMock.exitErc4626Supply(
            Erc4626SupplyFuseExitData({vault: address(feeVault), vaultAssetAmount: partialAmount})
        );

        // then
        uint256 balanceAfter = underlyingToken.balanceOf(address(vaultMock));
        uint256 sharesAfter = feeVault.balanceOf(address(vaultMock));

        assertEq(balanceAfter - balanceBefore, partialAmount, "should withdraw exact partial amount");
        assertTrue(sharesAfter < sharesBefore, "shares should decrease after partial withdrawal");
        assertTrue(sharesAfter > 0, "should still have remaining shares");
    }

    /// @notice Standard (no-fee) vault behavior is identical to before the change.
    /// For standard ERC4626, maxWithdraw returns convertToAssets(balanceOf(owner)) with Floor rounding.
    function testShouldExitFromStandardVaultUnchanged() external {
        // given
        _depositToStandardVault(DEPOSIT_AMOUNT);

        uint256 sharesBefore = standardVault.balanceOf(address(vaultMock));
        assertTrue(sharesBefore > 0, "should have shares after deposit");

        // Verify standard vault: maxWithdraw == convertToAssets
        uint256 maxWithdrawAmount = standardVault.maxWithdraw(address(vaultMock));
        uint256 convertToAssetsAmount = standardVault.convertToAssets(sharesBefore);
        assertEq(maxWithdrawAmount, convertToAssetsAmount, "maxWithdraw should equal convertToAssets for standard vault");

        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));

        // when - full exit
        vaultMock.exitErc4626Supply(
            Erc4626SupplyFuseExitData({vault: address(standardVault), vaultAssetAmount: type(uint256).max})
        );

        // then
        uint256 balanceAfter = underlyingToken.balanceOf(address(vaultMock));
        uint256 sharesAfter = standardVault.balanceOf(address(vaultMock));

        assertTrue(balanceAfter > balanceBefore, "underlying balance should increase");
        assertEq(sharesAfter, 0, "all shares should be redeemed");
        assertEq(balanceAfter - balanceBefore, DEPOSIT_AMOUNT, "should recover full deposit from standard vault");
    }
}
