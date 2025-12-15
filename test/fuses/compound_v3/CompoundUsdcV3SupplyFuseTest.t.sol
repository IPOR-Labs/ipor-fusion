// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CompoundV3SupplyFuse, CompoundV3SupplyFuseEnterData, CompoundV3SupplyFuseExitData} from "../../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {IComet} from "../../../contracts/fuses/compound_v3/ext/IComet.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";

contract CompoundUsdcV3SupplyFuseTest is Test {
    address public constant COMET_V3_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    struct SupportedToken {
        address asset;
        string name;
    }

    SupportedToken private activeTokens;
    IComet private constant COMET = IComet(COMET_V3_USDC);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19538857);
    }

    function testShouldBeAbleToSupply() external iterateSupportedTokens {
        // given
        CompoundV3SupplyFuse fuse = new CompoundV3SupplyFuse(1, COMET_V3_USDC);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(vaultMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(vaultMock));
        uint256 balanceOnCometBefore = _getBalance(address(vaultMock), activeTokens.asset);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // when

        vaultMock.enterCompoundV3Supply(CompoundV3SupplyFuseEnterData({asset: activeTokens.asset, amount: amount}));

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(vaultMock));
        uint256 balanceOnCometAfter = _getBalance(address(vaultMock), activeTokens.asset);

        assertEq(balanceAfter + amount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(balanceOnCometAfter > balanceOnCometBefore, "collateral balance should be increased by amount");
    }

    function testShouldBeAbleToWithdraw() external iterateSupportedTokens {
        // given
        CompoundV3SupplyFuse fuse = new CompoundV3SupplyFuse(1, COMET_V3_USDC);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(vaultMock), 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        vaultMock.enterCompoundV3Supply(CompoundV3SupplyFuseEnterData({asset: activeTokens.asset, amount: amount}));

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(vaultMock));
        uint256 balanceOnCometBefore = _getBalance(address(vaultMock), activeTokens.asset);

        // when
        vaultMock.exitCompoundV3Supply(
            CompoundV3SupplyFuseExitData({asset: activeTokens.asset, amount: balanceOnCometBefore})
        );

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(vaultMock));
        uint256 balanceOnCometAfter = _getBalance(address(vaultMock), activeTokens.asset);

        assertTrue(balanceAfter > balanceBefore, "vault balance should be increased by amount");
        assertTrue(balanceOnCometAfter < balanceOnCometBefore, "collateral balance should be decreased by amount");
    }

    function testShouldBeAbleToSupplyTransient() external iterateSupportedTokens {
        // given
        CompoundV3SupplyFuse fuse = new CompoundV3SupplyFuse(1, COMET_V3_USDC);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(vaultMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(vaultMock));
        uint256 balanceOnCometBefore = _getBalance(address(vaultMock), activeTokens.asset);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(activeTokens.asset);
        inputs[1] = TypeConversionLib.toBytes32(amount);

        // when
        vaultMock.setInputs(address(fuse), inputs);
        vaultMock.enterCompoundV3SupplyTransient();

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(vaultMock));
        uint256 balanceOnCometAfter = _getBalance(address(vaultMock), activeTokens.asset);

        assertEq(balanceAfter + amount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(balanceOnCometAfter > balanceOnCometBefore, "collateral balance should be increased by amount");

        bytes32[] memory outputs = vaultMock.getOutputs(address(fuse));
        assertEq(outputs.length, 3, "outputs length should be 3");
        assertEq(TypeConversionLib.toAddress(outputs[0]), activeTokens.asset, "asset should match");
        assertEq(TypeConversionLib.toAddress(outputs[1]), COMET_V3_USDC, "market should match");
        assertEq(TypeConversionLib.toUint256(outputs[2]), amount, "amount should match");
    }

    function testShouldBeAbleToWithdrawTransient() external iterateSupportedTokens {
        // given
        CompoundV3SupplyFuse fuse = new CompoundV3SupplyFuse(1, COMET_V3_USDC);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(vaultMock), 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        vaultMock.enterCompoundV3Supply(CompoundV3SupplyFuseEnterData({asset: activeTokens.asset, amount: amount}));

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(vaultMock));
        uint256 balanceOnCometBefore = _getBalance(address(vaultMock), activeTokens.asset);

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(activeTokens.asset);
        inputs[1] = TypeConversionLib.toBytes32(balanceOnCometBefore);

        // when
        vaultMock.setInputs(address(fuse), inputs);
        vaultMock.exitCompoundV3SupplyTransient();

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(vaultMock));
        uint256 balanceOnCometAfter = _getBalance(address(vaultMock), activeTokens.asset);

        assertTrue(balanceAfter > balanceBefore, "vault balance should be increased by amount");
        assertTrue(balanceOnCometAfter < balanceOnCometBefore, "collateral balance should be decreased by amount");

        bytes32[] memory outputs = vaultMock.getOutputs(address(fuse));
        assertEq(outputs.length, 3, "outputs length should be 3");
        assertEq(TypeConversionLib.toAddress(outputs[0]), activeTokens.asset, "asset should match");
        assertEq(TypeConversionLib.toAddress(outputs[1]), COMET_V3_USDC, "market should match");
        assertTrue(TypeConversionLib.toUint256(outputs[2]) > 0, "amount should be positive");
    }

    function testShouldBeAbleToInstantWithdraw() external iterateSupportedTokens {
        // given
        CompoundV3SupplyFuse fuse = new CompoundV3SupplyFuse(1, COMET_V3_USDC);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(vaultMock), 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // Supply first
        vaultMock.enterCompoundV3Supply(CompoundV3SupplyFuseEnterData({asset: activeTokens.asset, amount: amount}));

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(vaultMock));
        uint256 balanceOnCometBefore = _getBalance(address(vaultMock), activeTokens.asset);

        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(amount); // amount
        params[1] = PlasmaVaultConfigLib.addressToBytes32(activeTokens.asset); // asset

        // when
        vaultMock.instantWithdraw(params);

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(vaultMock));
        uint256 balanceOnCometAfter = _getBalance(address(vaultMock), activeTokens.asset);

        assertTrue(balanceAfter > balanceBefore, "vault balance should be increased by amount");
        assertTrue(balanceOnCometAfter < balanceOnCometBefore, "collateral balance should be decreased by amount");
    }

    function testShouldFailSupplyUnsupportedAsset() external {
        // given
        CompoundV3SupplyFuse fuse = new CompoundV3SupplyFuse(1, COMET_V3_USDC);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        address unsupportedAsset = address(0x123);
        uint256 amount = 100;

        // when & then
        vm.expectRevert(
            abi.encodeWithSelector(
                CompoundV3SupplyFuse.CompoundV3SupplyFuseUnsupportedAsset.selector,
                "enter",
                unsupportedAsset
            )
        );
        vaultMock.enterCompoundV3Supply(CompoundV3SupplyFuseEnterData({asset: unsupportedAsset, amount: amount}));
    }

    function testShouldReturnWhenSupplyAmountIsZero() external {
        // given
        CompoundV3SupplyFuse fuse = new CompoundV3SupplyFuse(1, COMET_V3_USDC);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));
        address asset = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC

        // when
        vaultMock.enterCompoundV3Supply(CompoundV3SupplyFuseEnterData({asset: asset, amount: 0}));

        // then
        // No revert
    }

    function _getBalance(address user, address asset) private returns (uint256) {
        if (asset == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) {
            // USDC
            return COMET.balanceOf(user);
        } else {
            return COMET.collateralBalanceOf(user, asset);
        }
    }

    function _getSupportedAssets() private returns (SupportedToken[] memory supportedTokensTemp) {
        supportedTokensTemp = new SupportedToken[](5);

        supportedTokensTemp[0] = SupportedToken(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "USDC");
        supportedTokensTemp[1] = SupportedToken(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984, "UNI");
        supportedTokensTemp[2] = SupportedToken(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, "WETH");
        supportedTokensTemp[3] = SupportedToken(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599, "WBTC");
        supportedTokensTemp[4] = SupportedToken(0x514910771AF9Ca656af840dff83E8264EcF986CA, "LINK");

        return supportedTokensTemp;
    }

    function _supplyTokensToMockVault(address asset, address to, uint256 amount) private {
        if (asset == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) {
            // USDC
            vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9); // AmmTreasuryUsdcProxy
            ERC20(asset).transfer(to, amount);
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
}
