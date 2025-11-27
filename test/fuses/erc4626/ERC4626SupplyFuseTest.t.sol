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
        vaultMock.enterErc4626Supply(Erc4626SupplyFuseEnterData({vault: marketAddress, vaultAssetAmount: amount}));

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

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(marketAddress);
        inputs[1] = TypeConversionLib.toBytes32(amount);
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
        vaultMock.enterErc4626Supply(Erc4626SupplyFuseEnterData({vault: marketAddress, vaultAssetAmount: amount}));

        uint256 balanceBefore = ERC20(vault.asset()).balanceOf(address(vaultMock));
        uint256 balanceOnMarketBefore = vault.balanceOf(address(vaultMock));

        // when
        vaultMock.exitErc4626Supply(Erc4626SupplyFuseExitData({vault: marketAddress, vaultAssetAmount: amount / 2}));

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
        vaultMock.enterErc4626Supply(Erc4626SupplyFuseEnterData({vault: marketAddress, vaultAssetAmount: amount}));

        uint256 balanceBefore = ERC20(vault.asset()).balanceOf(address(vaultMock));
        uint256 balanceOnMarketBefore = vault.balanceOf(address(vaultMock));

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(marketAddress);
        inputs[1] = TypeConversionLib.toBytes32(amount / 2);
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

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(marketAddress);
        inputs[1] = TypeConversionLib.toBytes32(uint256(100));
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

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(marketAddress);
        inputs[1] = TypeConversionLib.toBytes32(uint256(100));
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

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(marketAddress);
        inputs[1] = TypeConversionLib.toBytes32(uint256(0));
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

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(marketAddress);
        inputs[1] = TypeConversionLib.toBytes32(uint256(0));
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

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(marketAddress);
        inputs[1] = TypeConversionLib.toBytes32(uint256(100)); // Amount > 0 but balance is 0
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

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(marketAddress);
        inputs[1] = TypeConversionLib.toBytes32(uint256(100)); // Amount > 0 but balance in vault is 0
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
        vaultMock.enterErc4626Supply(Erc4626SupplyFuseEnterData({vault: marketAddress, vaultAssetAmount: amount}));

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
        vaultMock.enterErc4626Supply(Erc4626SupplyFuseEnterData({vault: marketAddress, vaultAssetAmount: amount}));

        uint256 balanceBefore = ERC20(vault.asset()).balanceOf(address(vaultMock));
        uint256 balanceOnMarketBefore = vault.balanceOf(address(vaultMock));

        // when
        vaultMock.exitErc4626Supply(Erc4626SupplyFuseExitData({vault: marketAddress, vaultAssetAmount: amount / 2}));

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
        vaultMock.enterErc4626Supply(Erc4626SupplyFuseEnterData({vault: marketAddress, vaultAssetAmount: amount}));

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

    function _supplyTokensToMockVault(address asset, address to, uint256 amount) private {
        deal(asset, to, amount);
    }
}
