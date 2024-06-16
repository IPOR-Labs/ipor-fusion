// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ICurveStableswapNG} from "./../../../contracts/fuses/curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {CurveStableswapNGSupplyFuse, CurveStableswapNGSupplyFuseEnterData, CurveStableswapNGSupplyFuseExitData} from "./../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSupplyFuse.sol";
import {CurveStableswapNGSupplyFuseMock} from "./CurveStableswapNGSupplyFuseMock.t.sol";

contract CurveStableswapNGSupplyFuseTest is Test {
    struct SupportedToken {
        address asset;
        string name;
    }

    // Address USDC/USDM pool on Ethereum mainnet
    // 0x4bD135524897333bec344e50ddD85126554E58B4
    // index 0 - USDC
    // index 1 - USDM

    address public constant CURVE_STABLESWAP_NG_POOL = 0x4bD135524897333bec344e50ddD85126554E58B4;

    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant USDM = 0x59D9356E565Ab3A36dD77763Fc0d87fEaf85508C;
    address public constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;

    ICurveStableswapNG public constant CURVE_STABLESWAP_NG = ICurveStableswapNG(CURVE_STABLESWAP_NG_POOL);

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 202220653);
    }

    function testShouldBeAbleToSupplyOneCoinAtIndexOne() external {
        // given
        SupportedToken memory activeToken = SupportedToken({asset: USDM, name: "USDM"});

        CurveStableswapNGSupplyFuse fuse = new CurveStableswapNGSupplyFuse(1, address(CURVE_STABLESWAP_NG));
        CurveStableswapNGSupplyFuseMock fuseMock = new CurveStableswapNGSupplyFuseMock(address(fuse));

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();

        uint256 decimals = ERC20(activeToken.asset).decimals();

        _supplyTokensToMockVault(activeToken.asset, address(fuseMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(USDM).balanceOf(address(fuseMock));

        address[] memory assets = new address[](1);
        assets[0] = CURVE_STABLESWAP_NG_POOL;
        fuseMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // when
        fuseMock.enter(
            CurveStableswapNGSupplyFuseEnterData({amounts: amounts, minMintAmount: 0, receiver: address(fuseMock)})
        );

        // then
        uint256 balanceAfter = ERC20(USDM).balanceOf(address(fuseMock));
        uint256 lpTokenBalance = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));
        assertApproxEqAbs(balanceAfter + amounts[1], balanceBefore, 100, "vault balance should be decreased by amount");
        assertGt(lpTokenBalance, 0);
    }

    function testShouldBeAbleToSupplyOneCoinAtIndexZero() external {
        // given
        SupportedToken memory activeToken = SupportedToken({asset: USDC, name: "USDC"});

        CurveStableswapNGSupplyFuse fuse = new CurveStableswapNGSupplyFuse(1, address(CURVE_STABLESWAP_NG));
        CurveStableswapNGSupplyFuseMock fuseMock = new CurveStableswapNGSupplyFuseMock(address(fuse));

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100 * 10 ** ERC20(USDC).decimals();
        amounts[1] = 0;

        uint256 decimals = ERC20(activeToken.asset).decimals();

        _supplyTokensToMockVault(activeToken.asset, address(fuseMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(USDC).balanceOf(address(fuseMock));

        address[] memory assets = new address[](1);
        assets[0] = CURVE_STABLESWAP_NG_POOL;
        fuseMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // when
        fuseMock.enter(
            CurveStableswapNGSupplyFuseEnterData({amounts: amounts, minMintAmount: 0, receiver: address(fuseMock)})
        );

        // then
        uint256 balanceAfter = ERC20(USDC).balanceOf(address(fuseMock));
        uint256 lpTokenBalance = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));
        assertApproxEqAbs(balanceAfter + amounts[0], balanceBefore, 100, "vault balance should be decreased by amount");
        assertGt(lpTokenBalance, 0);
    }

    function testShouldBeAbleToSupplyCoins() external {
        // given
        SupportedToken memory token1 = SupportedToken({asset: USDC, name: "USDC"});
        SupportedToken memory token2 = SupportedToken({asset: USDM, name: "USDM"});
        SupportedToken[] memory activeTokens = new SupportedToken[](2);
        activeTokens[0] = token1;
        activeTokens[1] = token2;

        CurveStableswapNGSupplyFuse fuse = new CurveStableswapNGSupplyFuse(1, address(CURVE_STABLESWAP_NG));
        CurveStableswapNGSupplyFuseMock fuseMock = new CurveStableswapNGSupplyFuseMock(address(fuse));

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100 * 10 ** ERC20(USDC).decimals();
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();

        uint256 decimals1 = ERC20(token1.asset).decimals();
        uint256 decimals2 = ERC20(token2.asset).decimals();

        _supplyTokensToMockVault(token1.asset, address(fuseMock), 1_000 * 10 ** decimals1);
        _supplyTokensToMockVault(token2.asset, address(fuseMock), 1_000 * 10 ** decimals2);

        uint256 balanceBefore1 = ERC20(USDC).balanceOf(address(fuseMock));
        uint256 balanceBefore2 = ERC20(USDM).balanceOf(address(fuseMock));

        address[] memory assets = new address[](1);
        assets[0] = CURVE_STABLESWAP_NG_POOL;
        fuseMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // when
        fuseMock.enter(
            CurveStableswapNGSupplyFuseEnterData({amounts: amounts, minMintAmount: 0, receiver: address(fuseMock)})
        );

        // then
        uint256 balanceAfter1 = ERC20(USDC).balanceOf(address(fuseMock));
        uint256 balanceAfter2 = ERC20(USDM).balanceOf(address(fuseMock));
        uint256 lpTokenBalance = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));
        assertApproxEqAbs(
            balanceAfter1 + amounts[0],
            balanceBefore1,
            100,
            "vault balance should be decreased by amount"
        );
        assertApproxEqAbs(
            balanceAfter2 + amounts[1],
            balanceBefore2,
            100,
            "vault balance should be decreased by amount"
        );
        assertGt(lpTokenBalance, 0);
    }

    function testShouldBeAbleToWithdrawOneCoinAtIndexOne() external {
        // given
        SupportedToken memory activeToken = SupportedToken({asset: USDM, name: "USDM"});
        CurveStableswapNGSupplyFuse fuse = new CurveStableswapNGSupplyFuse(1, address(CURVE_STABLESWAP_NG));
        CurveStableswapNGSupplyFuseMock fuseMock = new CurveStableswapNGSupplyFuseMock(address(fuse));

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();

        uint256 decimals = ERC20(activeToken.asset).decimals();

        _supplyTokensToMockVault(activeToken.asset, address(fuseMock), 1_000 * 10 ** decimals);

        uint256 balanceBeforeEnter = ERC20(USDM).balanceOf(address(fuseMock));

        address[] memory assets = new address[](1);
        assets[0] = CURVE_STABLESWAP_NG_POOL;
        fuseMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        fuseMock.enter(
            CurveStableswapNGSupplyFuseEnterData({amounts: amounts, minMintAmount: 0, receiver: address(fuseMock)})
        );

        uint256 lpTokenBalanceBeforeExit = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));

        uint256 minReceived = CURVE_STABLESWAP_NG.calc_withdraw_one_coin(lpTokenBalanceBeforeExit, 1);

        // when
        fuseMock.exit(
            CurveStableswapNGSupplyFuseExitData({
                burnAmount: lpTokenBalanceBeforeExit,
                coinIndex: 1,
                minReceived: minReceived,
                receiver: address(fuseMock)
            })
        );

        // then
        uint256 balanceAfterExit = ERC20(USDM).balanceOf(address(fuseMock));
        uint256 lpTokenBalanceAfterExit = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));
        assertEq(
            balanceAfterExit + amounts[1] - minReceived,
            balanceBeforeEnter,
            "vault balance should be decreased by amount"
        );
        assertEq(lpTokenBalanceAfterExit, 0, "lpToken balance should be zero after full exit");
    }

    function testShouldBeAbleToWithdrawOneCoinAtIndexZero() external {
        // given
        SupportedToken memory activeToken = SupportedToken({asset: USDC, name: "USDC"});
        CurveStableswapNGSupplyFuse fuse = new CurveStableswapNGSupplyFuse(1, address(CURVE_STABLESWAP_NG));
        CurveStableswapNGSupplyFuseMock fuseMock = new CurveStableswapNGSupplyFuseMock(address(fuse));

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100 * 10 ** ERC20(USDC).decimals();
        amounts[1] = 0;

        uint256 decimals = ERC20(activeToken.asset).decimals();

        _supplyTokensToMockVault(activeToken.asset, address(fuseMock), 1_000 * 10 ** decimals);

        uint256 balanceBeforeEnter = ERC20(USDC).balanceOf(address(fuseMock));

        address[] memory assets = new address[](1);
        assets[0] = CURVE_STABLESWAP_NG_POOL;
        fuseMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        fuseMock.enter(
            CurveStableswapNGSupplyFuseEnterData({amounts: amounts, minMintAmount: 0, receiver: address(fuseMock)})
        );

        uint256 lpTokenBalanceBeforeExit = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));

        uint256 minReceived = CURVE_STABLESWAP_NG.calc_withdraw_one_coin(lpTokenBalanceBeforeExit, 0);

        // when
        fuseMock.exit(
            CurveStableswapNGSupplyFuseExitData({
                burnAmount: lpTokenBalanceBeforeExit,
                coinIndex: 0,
                minReceived: minReceived,
                receiver: address(fuseMock)
            })
        );

        // then
        uint256 balanceAfterExit = ERC20(USDC).balanceOf(address(fuseMock));
        uint256 lpTokenBalanceAfterExit = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));
        assertEq(
            balanceAfterExit + amounts[0] - minReceived,
            balanceBeforeEnter,
            "vault balance should be decreased by amount"
        );
        assertEq(lpTokenBalanceAfterExit, 0, "lpToken balance should be zero after full exit");
    }

    function testShouldFailToDepositMoreExpectedCoinsThanAvailable() external {
        // given
        SupportedToken memory token1 = SupportedToken({asset: USDC, name: "USDC"});
        SupportedToken memory token2 = SupportedToken({asset: USDM, name: "USDM"});
        SupportedToken memory token3 = SupportedToken({asset: DAI, name: "DAI"});
        SupportedToken[] memory activeTokens = new SupportedToken[](3);
        activeTokens[0] = token1;
        activeTokens[1] = token2;
        activeTokens[2] = token3;

        CurveStableswapNGSupplyFuse fuse = new CurveStableswapNGSupplyFuse(1, address(CURVE_STABLESWAP_NG));
        CurveStableswapNGSupplyFuseMock fuseMock = new CurveStableswapNGSupplyFuseMock(address(fuse));

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100 * 10 ** ERC20(USDC).decimals();
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();
        amounts[2] = 100 * 10 ** ERC20(DAI).decimals();

        for (uint256 i; i < 3; ++i) {
            uint256 decimals = ERC20(activeTokens[i].asset).decimals();
            _supplyTokensToMockVault(activeTokens[i].asset, address(fuseMock), 1_000 * 10 ** decimals);
        }

        address[] memory assets = new address[](1);
        assets[0] = CURVE_STABLESWAP_NG_POOL;
        fuseMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // when
        // then
        vm.expectRevert();
        fuseMock.enter(
            CurveStableswapNGSupplyFuseEnterData({amounts: amounts, minMintAmount: 0, receiver: address(fuseMock)})
        );
    }

    function _supplyTokensToMockVault(address asset, address to, uint256 amount) private {
        if (asset == USDC) {
            vm.prank(0x05e3a758FdD29d28435019ac453297eA37b61b62); // holder
            ERC20(asset).transfer(to, amount);
        } else if (asset == USDM) {
            vm.prank(0x426c4966fC76Bf782A663203c023578B744e4C5E); // holder
            ERC20(asset).transfer(to, amount);
        } else {
            deal(asset, to, amount);
        }
    }
}
