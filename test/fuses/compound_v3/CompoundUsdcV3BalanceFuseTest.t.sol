// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CompoundConstants} from "../../../contracts/fuses/compound_v3/CompoundConstants.sol";
import {CompoundV3SupplyFuse} from "../../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {IComet} from "../../../contracts/fuses/compound_v3/IComet.sol";

import {CompoundV3SupplyFuseMock} from "./CompoundV3SupplyFuseMock.sol";
import {CompoundV3BalanceFuseMock} from "./CompoundV3BalanceFuseMock.sol";

contract CompoundUsdcV3BalanceFuseTest is Test {
    struct SupportedToken {
        address asset;
        string name;
    }

    SupportedToken private activeTokens;
    IComet private constant COMET = IComet(CompoundConstants.COMET_V3_USDC);
    CompoundV3BalanceFuseMock private marketBalance;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        marketBalance = new CompoundV3BalanceFuseMock(CompoundConstants.COMET_V3_USDC, 1);
    }

    function testShouldBeAbleToSupply() external iterateSupportedTokens {
        // given
        CompoundV3SupplyFuse fuse = new CompoundV3SupplyFuse(CompoundConstants.COMET_V3_USDC, 1);
        CompoundV3SupplyFuseMock fuseMock = new CompoundV3SupplyFuseMock(address(fuse));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(fuseMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(fuseMock));
        uint256 balanceOnCometBefore = _getBalance(address(fuseMock), activeTokens.asset);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        fuseMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);
        marketBalance.updateMarketConfiguration(assets);

        uint256 balanceMarketBefore = marketBalance.balanceOf(address(fuseMock));

        // when

        fuseMock.enter(CompoundV3SupplyFuse.CompoundV3SupplyFuseEnterData({asset: activeTokens.asset, amount: amount}));

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(fuseMock));
        uint256 balanceOnCometAfter = _getBalance(address(fuseMock), activeTokens.asset);

        uint256 balanceMarketAfter = marketBalance.balanceOf(address(fuseMock));

        assertTrue(balanceMarketBefore < balanceMarketAfter, "market balance should be increased by amount");
        assertEq(balanceAfter + amount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(balanceOnCometAfter > balanceOnCometBefore, "collateral balance should be increased by amount");
    }

    function testShouldBeAbleToWithdraw() external iterateSupportedTokens {
        // given
        CompoundV3SupplyFuse fuse = new CompoundV3SupplyFuse(CompoundConstants.COMET_V3_USDC, 1);
        CompoundV3SupplyFuseMock fuseMock = new CompoundV3SupplyFuseMock(address(fuse));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(fuseMock), 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        fuseMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);
        marketBalance.updateMarketConfiguration(assets);

        fuseMock.enter(CompoundV3SupplyFuse.CompoundV3SupplyFuseEnterData({asset: activeTokens.asset, amount: amount}));

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(fuseMock));
        uint256 balanceOnCometBefore = _getBalance(address(fuseMock), activeTokens.asset);
        uint256 balanceMarketBefore = marketBalance.balanceOf(address(fuseMock));

        // when
        fuseMock.exit(
            CompoundV3SupplyFuse.CompoundV3SupplyFuseExitData({asset: activeTokens.asset, amount: balanceOnCometBefore})
        );

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(fuseMock));
        uint256 balanceOnCometAfter = _getBalance(address(fuseMock), activeTokens.asset);
        uint256 balanceMarketAfter = marketBalance.balanceOf(address(fuseMock));

        assertTrue(balanceMarketBefore > balanceMarketAfter, "market balance should be decreased by amount");

        assertTrue(balanceAfter > balanceBefore, "vault balance should be increased by amount");
        assertTrue(balanceOnCometAfter < balanceOnCometBefore, "collateral balance should be decreased by amount");
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

        supportedTokensTemp[1] = SupportedToken(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "USDC");
        supportedTokensTemp[0] = SupportedToken(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984, "UNI");
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