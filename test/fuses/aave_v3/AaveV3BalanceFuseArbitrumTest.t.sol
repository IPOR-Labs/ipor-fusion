// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPool} from "../../../contracts/vaults/interfaces/IPool.sol";
import {IAavePriceOracle} from "../../../contracts/fuses/aave_v3/IAavePriceOracle.sol";
import {IAavePoolDataProvider} from "../../../contracts/fuses/aave_v3/IAavePoolDataProvider.sol";
import {IApproveERC20} from "../../../contracts/fuses/IApproveERC20.sol";
import {AaveV3BalanceFuseMock} from "./AaveV3BalanceFuseMock.sol";

//https://mirror.xyz/unfrigginbelievable.eth/fzvIBwJZQKOP4sNpkrVZGOJEk5cDr6tarimQHTw6C84
contract AaveV3BalanceFuseArbitrumTest is Test {
    struct SupportedToken {
        address token;
        string name;
    }

    IPool public constant AAVE_POOL = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    IAavePriceOracle public constant AAVE_PRICE_ORACLE = IAavePriceOracle(0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7);
    IAavePoolDataProvider public constant AAVE_POOL_DATA_PROVIDER =
        IAavePoolDataProvider(0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654);
    address public constant ARBITRUM_AAVE_POOL_DATA_PROVIDER_V3 = 0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654;

    SupportedToken private activeTokens;

    function testShouldCalculateBalanceWhenSupply() external iterateSupportedTokens {
        // given
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 202220653);

        AaveV3BalanceFuseMock aaveV3Balances = new AaveV3BalanceFuseMock(
            1,
            address(AAVE_PRICE_ORACLE),
            ARBITRUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        address user = vm.rememberKey(123);
        uint256 decimals = ERC20(activeTokens.token).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.token, user, 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.token;

        aaveV3Balances.updateMarketConfiguration(assets);

        uint256 balanceBefore = aaveV3Balances.balanceOf(user);

        // when

        vm.prank(user);
        IApproveERC20(activeTokens.token).approve(address(AAVE_POOL), amount);
        vm.prank(user);
        AAVE_POOL.supply(activeTokens.token, amount, user, 0);

        uint256 balanceAfter = aaveV3Balances.balanceOf(user);

        // then
        assertTrue(balanceAfter > balanceBefore, "Balance should be greater after supply");
        assertEq(balanceBefore, 0, "Balance before should be 0");
    }

    function testShouldDecreaseBalanceWhenBorrowVariable() external iterateSupportedTokens {
        // given
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"));
        AaveV3BalanceFuseMock aaveV3Balances = new AaveV3BalanceFuseMock(
            1,
            address(AAVE_PRICE_ORACLE),
            ARBITRUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        address user = vm.rememberKey(123);
        uint256 decimals = ERC20(activeTokens.token).decimals();
        uint256 amount = 100 * 10 ** decimals;
        uint256 borrowAmount = 20 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.token, user, 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.token;
        aaveV3Balances.updateMarketConfiguration(assets);

        vm.prank(user);
        IApproveERC20(activeTokens.token).approve(address(AAVE_POOL), amount);
        vm.prank(user);
        AAVE_POOL.supply(activeTokens.token, amount, user, 0);

        uint256 balanceBefore = aaveV3Balances.balanceOf(user);

        // when
        vm.prank(user);
        AAVE_POOL.borrow(activeTokens.token, borrowAmount, uint256(2), 0, user);

        uint256 balanceAfter = aaveV3Balances.balanceOf(user);

        // then
        assertTrue(balanceAfter < balanceBefore, "Balance should be greater after supply");
    }

    function _getSupportedAssets() private pure returns (SupportedToken[] memory supportedTokensTemp) {
        supportedTokensTemp = new SupportedToken[](1);

        supportedTokensTemp[0] = SupportedToken(0xaf88d065e77c8cC2239327C5EDb3A432268e5831, "USDC");
    }

    function _supplyTokensToMockVault(address asset, address to, uint256 amount) private {
        if (asset == 0xaf88d065e77c8cC2239327C5EDb3A432268e5831) {
            // USDC
            vm.prank(0x05e3a758FdD29d28435019ac453297eA37b61b62); // holder
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