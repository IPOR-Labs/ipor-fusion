// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CompoundConstants} from "../../../contracts/fuses/compound_v3/CompoundConstants.sol";
import {CompoundV3SupplyFuse, CompoundV3SupplyFuseEnterData, CompoundV3SupplyFuseExitData} from "../../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {IComet} from "../../../contracts/fuses/compound_v3/ext/IComet.sol";

import {CompoundV3SupplyFuseMock} from "./CompoundV3SupplyFuseMock.sol";
import {CompoundV3BalanceFuseMock} from "./CompoundV3BalanceFuseMock.sol";

contract CompoundWethV3BalanceFuseTest is Test {
    struct SupportedToken {
        address asset;
        string name;
    }

    SupportedToken private activeTokens;
    IComet private constant COMET = IComet(CompoundConstants.COMET_V3_WETH);
    CompoundV3BalanceFuseMock private marketBalance;

    function testShouldBeAbleToSupply() external iterateSupportedTokens {
        // given
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        marketBalance = new CompoundV3BalanceFuseMock(1, CompoundConstants.COMET_V3_WETH);
        CompoundV3SupplyFuse fuse = new CompoundV3SupplyFuse(1, CompoundConstants.COMET_V3_WETH);
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

        fuseMock.enter(CompoundV3SupplyFuseEnterData({asset: activeTokens.asset, amount: amount}));

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
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"));
        marketBalance = new CompoundV3BalanceFuseMock(1, CompoundConstants.COMET_V3_WETH);
        CompoundV3SupplyFuse fuse = new CompoundV3SupplyFuse(1, CompoundConstants.COMET_V3_WETH);
        CompoundV3SupplyFuseMock fuseMock = new CompoundV3SupplyFuseMock(address(fuse));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(fuseMock), 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        fuseMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);
        marketBalance.updateMarketConfiguration(assets);

        fuseMock.enter(CompoundV3SupplyFuseEnterData({asset: activeTokens.asset, amount: amount}));

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(fuseMock));
        uint256 balanceOnCometBefore = _getBalance(address(fuseMock), activeTokens.asset);

        uint256 balanceMarketBefore = marketBalance.balanceOf(address(fuseMock));

        // when
        fuseMock.exit(CompoundV3SupplyFuseExitData({asset: activeTokens.asset, amount: balanceOnCometBefore}));

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(fuseMock));
        uint256 balanceOnCometAfter = _getBalance(address(fuseMock), activeTokens.asset);
        uint256 balanceMarketAfter = marketBalance.balanceOf(address(fuseMock));

        assertTrue(balanceMarketBefore > balanceMarketAfter, "market balance should be decreased by amount");
        assertTrue(balanceAfter > balanceBefore, "vault balance should be increased by amount");
        assertTrue(balanceOnCometAfter < balanceOnCometBefore, "collateral balance should be decreased by amount");
    }

    function _getBalance(address user, address asset) private returns (uint256) {
        if (asset == 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2) {
            // wETH
            return COMET.balanceOf(user);
        } else {
            return COMET.collateralBalanceOf(user, asset);
        }
    }

    function _getSupportedAssets() private returns (SupportedToken[] memory supportedTokensTemp) {
        supportedTokensTemp = new SupportedToken[](4);

        supportedTokensTemp[0] = SupportedToken(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, "wstETH");
        supportedTokensTemp[1] = SupportedToken(0xae78736Cd615f374D3085123A210448E74Fc6393, "rETH");
        supportedTokensTemp[2] = SupportedToken(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, "WETH");
        supportedTokensTemp[3] = SupportedToken(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704, "cbETH");

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
