// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CompoundV3SupplyFuse, CompoundV3SupplyFuseEnterData, CompoundV3SupplyFuseExitData} from "../../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {IComet} from "../../../contracts/fuses/compound_v3/ext/IComet.sol";

import {CompoundV3SupplyFuseMock} from "./CompoundV3SupplyFuseMock.sol";

contract CompoundUsdcV3SupplyArbitrumFuseTest is Test {
    struct SupportedToken {
        address asset;
        string name;
    }

    SupportedToken private activeTokens;
    IComet private constant COMET = IComet(0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf);

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 202220653);
    }

    function testShouldBeAbleToSupply() external iterateSupportedTokens {
        // given
        CompoundV3SupplyFuse fuse = new CompoundV3SupplyFuse(1, address(COMET));
        CompoundV3SupplyFuseMock fuseMock = new CompoundV3SupplyFuseMock(address(fuse));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(fuseMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(fuseMock));
        uint256 balanceOnCometBefore = _getBalance(address(fuseMock), activeTokens.asset);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        fuseMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // when

        fuseMock.enter(CompoundV3SupplyFuseEnterData({asset: activeTokens.asset, amount: amount}));

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(fuseMock));
        uint256 balanceOnCometAfter = _getBalance(address(fuseMock), activeTokens.asset);

        assertEq(balanceAfter + amount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(balanceOnCometAfter > balanceOnCometBefore, "collateral balance should be increased by amount");
    }

    function testShouldBeAbleToWithdraw() external iterateSupportedTokens {
        // given
        CompoundV3SupplyFuse fuse = new CompoundV3SupplyFuse(1, address(COMET));
        CompoundV3SupplyFuseMock fuseMock = new CompoundV3SupplyFuseMock(address(fuse));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(fuseMock), 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        fuseMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        fuseMock.enter(CompoundV3SupplyFuseEnterData({asset: activeTokens.asset, amount: amount}));

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(fuseMock));
        uint256 balanceOnCometBefore = _getBalance(address(fuseMock), activeTokens.asset);

        // when
        fuseMock.exit(CompoundV3SupplyFuseExitData({asset: activeTokens.asset, amount: balanceOnCometBefore}));

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(fuseMock));
        uint256 balanceOnCometAfter = _getBalance(address(fuseMock), activeTokens.asset);

        assertTrue(balanceAfter > balanceBefore, "vault balance should be increased by amount");
        assertTrue(balanceOnCometAfter < balanceOnCometBefore, "collateral balance should be decreased by amount");
    }

    function _getBalance(address user, address asset) private returns (uint256) {
        if (asset == 0xaf88d065e77c8cC2239327C5EDb3A432268e5831) {
            // USDC
            return COMET.balanceOf(user);
        } else {
            return COMET.collateralBalanceOf(user, asset);
        }
    }

    function _getSupportedAssets() private returns (SupportedToken[] memory supportedTokensTemp) {
        supportedTokensTemp = new SupportedToken[](3);

        supportedTokensTemp[0] = SupportedToken(0xaf88d065e77c8cC2239327C5EDb3A432268e5831, "USDC");
        supportedTokensTemp[1] = SupportedToken(0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f, "WBTC");
        supportedTokensTemp[2] = SupportedToken(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1, "WETH");

        return supportedTokensTemp;
    }

    function _supplyTokensToMockVault(address asset, address to, uint256 amount) private {
        if (asset == 0xaf88d065e77c8cC2239327C5EDb3A432268e5831) {
            // USDC
            vm.prank(0x47c031236e19d024b42f8AE6780E44A573170703); // AmmTreasuryUsdcProxy
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
