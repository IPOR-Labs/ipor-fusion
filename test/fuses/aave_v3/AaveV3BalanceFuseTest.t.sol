// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPool} from "../../../contracts/fuses/aave_v3/ext/IPool.sol";
import {IAavePriceOracle} from "../../../contracts/fuses/aave_v3/ext/IAavePriceOracle.sol";
import {IAavePoolDataProvider} from "../../../contracts/fuses/aave_v3/ext/IAavePoolDataProvider.sol";
import {AaveV3BalanceFuse} from "../../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

//https://mirror.xyz/unfrigginbelievable.eth/fzvIBwJZQKOP4sNpkrVZGOJEk5cDr6tarimQHTw6C84
contract AaveV3BalanceFuseTest is Test {
    struct SupportedToken {
        address token;
        string name;
    }

    using SafeERC20 for ERC20;

    IPool public constant AAVE_POOL = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IAavePriceOracle public constant AAVE_PRICE_ORACLE = IAavePriceOracle(0x54586bE62E3c3580375aE3723C145253060Ca0C2);
    IAavePoolDataProvider public constant AAVE_POOL_DATA_PROVIDER =
        IAavePoolDataProvider(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);
    address public constant ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    SupportedToken private activeTokens;

    function testShouldCalculateBalanceWhenSupply() external iterateSupportedTokens {
        // given
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19508857);

        AaveV3BalanceFuse aaveV3Balances = new AaveV3BalanceFuse(1, ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);

        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(0x0), address(aaveV3Balances));

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
        AAVE_POOL.supply(activeTokens.token, amount, address(vaultMock), 0);

        uint256 balanceAfter = vaultMock.balanceOf();

        // then
        assertTrue(balanceAfter > balanceBefore, "Balance should be greater after supply");
        assertEq(balanceBefore, 0, "Balance before should be 0");
    }

    function testShouldDecreaseBalanceWhenBorrowVariable() external iterateSupportedTokens {
        // given
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19508857);
        AaveV3BalanceFuse aaveV3Balances = new AaveV3BalanceFuse(1, ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);

        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(0x0), address(aaveV3Balances));

        uint256 decimals = ERC20(activeTokens.token).decimals();
        uint256 amount = 100 * 10 ** decimals;
        uint256 borrowAmount = 20 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.token, address(vaultMock), 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.token;
        vaultMock.updateMarketConfiguration(1, assets);

        vm.prank(address(vaultMock));
        ERC20(activeTokens.token).forceApprove(address(AAVE_POOL), amount);
        vm.prank(address(vaultMock));
        AAVE_POOL.supply(activeTokens.token, amount, address(vaultMock), 0);

        uint256 balanceBefore = vaultMock.balanceOf();

        // when
        vm.prank(address(vaultMock));
        AAVE_POOL.borrow(activeTokens.token, borrowAmount, uint256(2), 0, address(vaultMock));

        uint256 balanceAfter = vaultMock.balanceOf();

        // then
        assertTrue(balanceAfter < balanceBefore, "Balance should be greater after supply");
    }

    function _getSupportedAssets() private returns (SupportedToken[] memory supportedTokensTemp) {
        supportedTokensTemp = new SupportedToken[](8);

        supportedTokensTemp[0] = SupportedToken(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, "WETH");
        supportedTokensTemp[1] = SupportedToken(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, "WSTETH");
        supportedTokensTemp[2] = SupportedToken(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599, "WBTC");
        supportedTokensTemp[3] = SupportedToken(0x6B175474E89094C44Da98b954EedeAC495271d0F, "DAI");
        supportedTokensTemp[4] = SupportedToken(0x514910771AF9Ca656af840dff83E8264EcF986CA, "LINK");
        supportedTokensTemp[5] = SupportedToken(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704, "cbETH");
        supportedTokensTemp[6] = SupportedToken(0xdAC17F958D2ee523a2206206994597C13D831ec7, "USDT");
        supportedTokensTemp[7] = SupportedToken(0xae78736Cd615f374D3085123A210448E74Fc6393, "rETH");
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
