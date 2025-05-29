// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CompoundV3SupplyFuse, CompoundV3SupplyFuseEnterData, CompoundV3SupplyFuseExitData} from "../../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {IComet} from "../../../contracts/fuses/compound_v3/ext/IComet.sol";

import {CompoundV3BalanceFuse} from "../../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

contract CompoundWethV3BalanceFuseTest is Test {
    address public constant COMET_V3_WETH = 0xA17581A9E3356d9A858b789D68B4d866e593aE94;

    struct SupportedToken {
        address asset;
        string name;
    }

    SupportedToken private activeTokens;
    IComet private constant COMET = IComet(COMET_V3_WETH);
    CompoundV3BalanceFuse private balanceFuse;

    function testShouldBeAbleToSupply() external iterateSupportedTokens {
        // given
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        balanceFuse = new CompoundV3BalanceFuse(1, COMET_V3_WETH);
        CompoundV3SupplyFuse fuse = new CompoundV3SupplyFuse(1, COMET_V3_WETH);

        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(vaultMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(vaultMock));
        uint256 balanceOnCometBefore = _getBalance(address(vaultMock), activeTokens.asset);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);
        vaultMock.updateMarketConfiguration(fuse.MARKET_ID(), assets);

        uint256 balanceMarketBefore = vaultMock.balanceOf();

        // when
        vaultMock.enterCompoundV3Supply(CompoundV3SupplyFuseEnterData({asset: activeTokens.asset, amount: amount}));

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(vaultMock));
        uint256 balanceOnCometAfter = _getBalance(address(vaultMock), activeTokens.asset);
        uint256 balanceMarketAfter = vaultMock.balanceOf();

        assertTrue(balanceMarketBefore < balanceMarketAfter, "market balance should be increased by amount");
        assertEq(balanceAfter + amount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(balanceOnCometAfter > balanceOnCometBefore, "collateral balance should be increased by amount");
    }

    function testShouldBeAbleToWithdraw() external iterateSupportedTokens {
        // given
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"));
        balanceFuse = new CompoundV3BalanceFuse(1, COMET_V3_WETH);
        CompoundV3SupplyFuse fuse = new CompoundV3SupplyFuse(1, COMET_V3_WETH);

        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(vaultMock), 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);
        vaultMock.updateMarketConfiguration(fuse.MARKET_ID(), assets);

        vaultMock.enterCompoundV3Supply(CompoundV3SupplyFuseEnterData({asset: activeTokens.asset, amount: amount}));

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(vaultMock));
        uint256 balanceOnCometBefore = _getBalance(address(vaultMock), activeTokens.asset);

        uint256 balanceMarketBefore = vaultMock.balanceOf();

        // when
        vaultMock.exitCompoundV3Supply(
            CompoundV3SupplyFuseExitData({asset: activeTokens.asset, amount: balanceOnCometBefore})
        );

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(vaultMock));
        uint256 balanceOnCometAfter = _getBalance(address(vaultMock), activeTokens.asset);
        uint256 balanceMarketAfter = vaultMock.balanceOf();

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
