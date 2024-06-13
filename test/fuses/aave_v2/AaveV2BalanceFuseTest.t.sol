// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAavePriceOracle} from "../../../contracts/fuses/aave_v3/ext/IAavePriceOracle.sol";
import {AaveV2BalanceFuseMock} from "./AaveV2BalanceFuseMock.sol";
import {AaveLendingPoolV2} from "../../../contracts/fuses/aave_v2/ext/AaveLendingPoolV2.sol";

contract AaveV3BalanceFuseTest is Test {
    struct SupportedToken {
        address token;
        string name;
    }

    using SafeERC20 for ERC20;

    AaveLendingPoolV2 public constant AAVE_POOL = AaveLendingPoolV2(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IAavePriceOracle public constant AAVE_PRICE_ORACLE = IAavePriceOracle(0x54586bE62E3c3580375aE3723C145253060Ca0C2);

    SupportedToken private activeTokens;

    function testShouldCalculateBalanceWhenSupply() external iterateSupportedTokens {
        // given
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19508857);

        AaveV2BalanceFuseMock aaveV2Balances = new AaveV2BalanceFuseMock(1);
        address user = vm.rememberKey(123);
        uint256 decimals = ERC20(activeTokens.token).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.token, user, 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.token;

        aaveV2Balances.updateMarketConfiguration(assets);

        uint256 balanceBefore = aaveV2Balances.balanceOf(user);

        // when

        vm.prank(user);
        ERC20(activeTokens.token).forceApprove(address(AAVE_POOL), amount);
        vm.prank(user);
        AAVE_POOL.deposit(activeTokens.token, amount, user, 0);

        uint256 balanceAfter = aaveV2Balances.balanceOf(user);

        // then
        assertTrue(balanceAfter > balanceBefore, "Balance should be greater after supply");
        assertEq(balanceBefore, 0, "Balance before should be 0");
    }

    function _getSupportedAssets() private pure returns (SupportedToken[] memory supportedTokensTemp) {
        supportedTokensTemp = new SupportedToken[](2);

        supportedTokensTemp[0] = SupportedToken(0x6B175474E89094C44Da98b954EedeAC495271d0F, "DAI");
        supportedTokensTemp[1] = SupportedToken(0xdAC17F958D2ee523a2206206994597C13D831ec7, "USDT");
    }

    function _supplyTokensToMockVault(address asset, address to, uint256 amount) private {
        deal(asset, to, amount);
    }

    modifier iterateSupportedTokens() {
        SupportedToken[] memory supportedTokens = _getSupportedAssets();
        for (uint256 i; i < supportedTokens.length; ++i) {
            activeTokens = supportedTokens[i];
            _;
        }
    }
}
