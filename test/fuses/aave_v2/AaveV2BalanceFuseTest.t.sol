// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAavePriceOracle} from "../../../contracts/fuses/aave_v3/ext/IAavePriceOracle.sol";
import {AaveLendingPoolV2} from "../../../contracts/fuses/aave_v2/ext/AaveLendingPoolV2.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {AaveV2BalanceFuse} from "../../../contracts/fuses/aave_v2/AaveV2BalanceFuse.sol";

contract AaveV2BalanceFuseTest is Test {
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

        AaveV2BalanceFuse aaveV2Balances = new AaveV2BalanceFuse(1);

        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(0x0), address(aaveV2Balances));

        uint256 decimals = ERC20(activeTokens.token).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.token, address(vaultMock), 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.token;

        vaultMock.updateMarketConfiguration(1, assets);

        uint256 balanceBefore = vaultMock.balanceOf();

        // when

        vm.prank(address(vaultMock));
        ERC20(activeTokens.token).forceApprove(address(AAVE_POOL), amount);
        vm.prank(address(vaultMock));
        AAVE_POOL.deposit(activeTokens.token, amount, address(vaultMock), 0);

        uint256 balanceAfter = vaultMock.balanceOf();

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
        if (asset == 0xdAC17F958D2ee523a2206206994597C13D831ec7) {
            // USDT - non-standard ERC20, deal() doesn't work
            vm.prank(0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503); // Binance
            (bool success, ) = asset.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
            require(success, "USDT transfer failed");
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
