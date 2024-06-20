// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ICurveStableswapNG} from "./../../../contracts/fuses/curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {CurveStableswapNGSingleSideSupplyFuse, CurveStableswapNGSingleSideSupplyFuseEnterData, CurveStableswapNGSingleSideSupplyFuseExitData} from "./../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideSupplyFuse.sol";
import {CurveStableswapNGSingleSideSupplyFuseMock} from "./CurveStableswapNGSingleSideSupplyFuseMock.t.sol";
import {Errors} from "./../../../contracts/libraries/errors/Errors.sol";

contract CurveStableswapNGSingleSideSupplyFuseTest is Test {
    struct SupportedToken {
        address asset;
        string name;
    }

    // Address USDC/USDM pool on Arbitrum: 0x4bD135524897333bec344e50ddD85126554E58B4
    // index 0 - USDC
    // index 1 - USDM

    address public constant CURVE_STABLESWAP_NG_POOL = 0x4bD135524897333bec344e50ddD85126554E58B4;

    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant USDM = 0x59D9356E565Ab3A36dD77763Fc0d87fEaf85508C;
    address public constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;

    ICurveStableswapNG public constant CURVE_STABLESWAP_NG = ICurveStableswapNG(CURVE_STABLESWAP_NG_POOL);

    event CurveSupplyStableswapNGSingleSideSupplyEnterFuse(
        address indexed version,
        address indexed asset,
        uint256[] amounts,
        uint256 minMintAmount
    );

    event CurveSupplyStableswapNGSingleSideSupplyExitFuse(
        address indexed version,
        uint256 burnAmount,
        address asset,
        uint256 minReceived
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 202220653);
    }

    // ENTER TESTS

    function testShouldBeAbleToSupplyOneTokenSupportedByThePool() external {
        // given
        SupportedToken memory activeToken = SupportedToken({asset: USDM, name: "USDM"});

        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(
            1,
            address(CURVE_STABLESWAP_NG)
        );
        CurveStableswapNGSingleSideSupplyFuseMock fuseMock = new CurveStableswapNGSingleSideSupplyFuseMock(
            address(fuse)
        );

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();

        _supplyTokensToMockVault(
            activeToken.asset,
            address(fuseMock),
            1_000 * 10 ** ERC20(activeToken.asset).decimals()
        );

        _grantAssetsToMarket(fuse, fuseMock, CURVE_STABLESWAP_NG_POOL);

        uint256 balanceBeforeEnter = ERC20(activeToken.asset).balanceOf(address(fuseMock));

        uint256 expectedLpTokenAmount = CURVE_STABLESWAP_NG.calc_token_amount(amounts, true);

        vm.expectEmit(true, true, true, true);
        emit CurveSupplyStableswapNGSingleSideSupplyEnterFuse(address(fuse), activeToken.asset, amounts, 0);

        // when
        vm.prank(address(fuseMock));
        fuseMock.enter(
            CurveStableswapNGSingleSideSupplyFuseEnterData({asset: USDM, amounts: amounts, minMintAmount: 0})
        );

        // then
        uint256 balanceAfterEnter = ERC20(activeToken.asset).balanceOf(address(fuseMock));
        uint256 lpTokenBalance = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));
        assertApproxEqAbs(
            balanceAfterEnter + amounts[1],
            balanceBeforeEnter,
            100,
            "vault balance should be decreased by amount"
        );
        assertEq(lpTokenBalance, expectedLpTokenAmount);
    }

    function testShouldRevertWhenEnterWithUnsupportedAsset() external {
        // given
        SupportedToken memory activeToken = SupportedToken({asset: DAI, name: "DAI"});

        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(
            1,
            address(CURVE_STABLESWAP_NG)
        );
        CurveStableswapNGSingleSideSupplyFuseMock fuseMock = new CurveStableswapNGSingleSideSupplyFuseMock(
            address(fuse)
        );

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();

        _supplyTokensToMockVault(
            activeToken.asset,
            address(fuseMock),
            1_000 * 10 ** ERC20(activeToken.asset).decimals()
        );

        bytes memory error = abi.encodeWithSignature(
            "CurveStableswapNGSingleSideSupplyFuseUnsupportedAsset(address,string)",
            address(CURVE_STABLESWAP_NG),
            Errors.UNSUPPORTED_ASSET
        );

        uint256 balanceBeforeEnter = ERC20(activeToken.asset).balanceOf(address(fuseMock));

        // when
        vm.expectRevert(error);
        vm.prank(address(fuseMock));
        fuseMock.enter(
            CurveStableswapNGSingleSideSupplyFuseEnterData({asset: USDM, amounts: amounts, minMintAmount: 0})
        );

        // then
        uint256 balanceAfterEnter = ERC20(activeToken.asset).balanceOf(address(fuseMock));
        uint256 lpTokenBalance = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));
        assertEq(balanceAfterEnter, balanceBeforeEnter, "vault balance should not be decreased");
        assertEq(lpTokenBalance, 0);
    }

    function testShouldRevertWhenEnterWithUnsupportedPoolAsset() external {
        // given
        SupportedToken memory activeToken = SupportedToken({asset: DAI, name: "DAI"});

        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(
            1,
            address(CURVE_STABLESWAP_NG)
        );
        CurveStableswapNGSingleSideSupplyFuseMock fuseMock = new CurveStableswapNGSingleSideSupplyFuseMock(
            address(fuse)
        );

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(DAI).decimals();

        _supplyTokensToMockVault(
            activeToken.asset,
            address(fuseMock),
            1_000 * 10 ** ERC20(activeToken.asset).decimals()
        );

        _grantAssetsToMarket(fuse, fuseMock, CURVE_STABLESWAP_NG_POOL);

        bytes memory error = abi.encodeWithSignature(
            "CurveStableswapNGSingleSideSupplyFuseUnsupportedPoolAsset(address,string)",
            address(activeToken.asset),
            Errors.UNSUPPORTED_ASSET
        );

        uint256 balanceBeforeEnter = ERC20(activeToken.asset).balanceOf(address(fuseMock));

        // when
        vm.expectRevert(error);
        vm.prank(address(fuseMock));
        fuseMock.enter(
            CurveStableswapNGSingleSideSupplyFuseEnterData({asset: DAI, amounts: amounts, minMintAmount: 0})
        );

        // then
        uint256 balanceAfterEnter = ERC20(activeToken.asset).balanceOf(address(fuseMock));
        uint256 lpTokenBalance = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));
        assertEq(balanceAfterEnter, balanceBeforeEnter, "vault balance should not be decreased");
        assertEq(lpTokenBalance, 0);
    }

    function testShouldRevertWhenUnexpectedNumberOfTokens() external {
        // given
        SupportedToken memory activeToken = SupportedToken({asset: USDM, name: "USDM"});

        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(
            1,
            address(CURVE_STABLESWAP_NG)
        );
        CurveStableswapNGSingleSideSupplyFuseMock fuseMock = new CurveStableswapNGSingleSideSupplyFuseMock(
            address(fuse)
        );

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();
        amounts[2] = 0;

        _supplyTokensToMockVault(
            activeToken.asset,
            address(fuseMock),
            1_000 * 10 ** ERC20(activeToken.asset).decimals()
        );

        _grantAssetsToMarket(fuse, fuseMock, CURVE_STABLESWAP_NG_POOL);

        bytes memory error = abi.encodeWithSignature("CurveStableswapNGSingleSideSupplyFuseUnexpectedNumberOfTokens()");

        uint256 balanceBeforeEnter = ERC20(activeToken.asset).balanceOf(address(fuseMock));

        // when
        vm.expectRevert(error);
        vm.prank(address(fuseMock));
        fuseMock.enter(
            CurveStableswapNGSingleSideSupplyFuseEnterData({asset: USDM, amounts: amounts, minMintAmount: 0})
        );

        // then
        uint256 balanceAfterEnter = ERC20(activeToken.asset).balanceOf(address(fuseMock));
        uint256 lpTokenBalance = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));
        assertEq(balanceAfterEnter, balanceBeforeEnter, "vault balance should not be decreased");
        assertEq(lpTokenBalance, 0);
    }

    function testShouldRevertWhenMinMintAmountRequestedIsNotMet() external {
        // given
        SupportedToken memory activeToken = SupportedToken({asset: USDM, name: "USDM"});

        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(
            1,
            address(CURVE_STABLESWAP_NG)
        );
        CurveStableswapNGSingleSideSupplyFuseMock fuseMock = new CurveStableswapNGSingleSideSupplyFuseMock(
            address(fuse)
        );

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();

        _supplyTokensToMockVault(
            activeToken.asset,
            address(fuseMock),
            1_000 * 10 ** ERC20(activeToken.asset).decimals()
        );

        _grantAssetsToMarket(fuse, fuseMock, CURVE_STABLESWAP_NG_POOL);

        uint256 balanceBeforeEnter = ERC20(activeToken.asset).balanceOf(address(fuseMock));

        uint256 expectedLpTokenAmount = CURVE_STABLESWAP_NG.calc_token_amount(amounts, true);

        uint256 minMintAmount = expectedLpTokenAmount + 1;

        bytes memory error = abi.encodeWithSignature(
            "CurveStableswapNGSingleSideSupplyFuseUnableToMeetMinMintAmount(uint256,uint256)",
            expectedLpTokenAmount,
            minMintAmount
        );

        // when
        vm.expectRevert(error);
        vm.prank(address(fuseMock));
        fuseMock.enter(
            CurveStableswapNGSingleSideSupplyFuseEnterData({
                asset: USDM,
                amounts: amounts,
                minMintAmount: minMintAmount
            })
        );

        // then
        uint256 balanceAfterEnter = ERC20(activeToken.asset).balanceOf(address(fuseMock));
        uint256 lpTokenBalance = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));
        assertEq(balanceAfterEnter, balanceBeforeEnter, "vault balance should not be decreased");
        assertEq(lpTokenBalance, 0);
    }

    function testShouldRevertWhenEnterWithAllZeroAmounts() external {
        // given
        SupportedToken memory activeToken = SupportedToken({asset: USDM, name: "USDM"});

        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(
            1,
            address(CURVE_STABLESWAP_NG)
        );
        CurveStableswapNGSingleSideSupplyFuseMock fuseMock = new CurveStableswapNGSingleSideSupplyFuseMock(
            address(fuse)
        );

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 0;

        _supplyTokensToMockVault(
            activeToken.asset,
            address(fuseMock),
            1_000 * 10 ** ERC20(activeToken.asset).decimals()
        );

        _grantAssetsToMarket(fuse, fuseMock, CURVE_STABLESWAP_NG_POOL);

        uint256 balanceBeforeEnter = ERC20(activeToken.asset).balanceOf(address(fuseMock));

        bytes memory error = abi.encodeWithSignature("CurveStableswapNGSingleSideSupplyFuseAllZeroAmounts()");

        // when
        vm.expectRevert(error);
        vm.prank(address(fuseMock));
        fuseMock.enter(
            CurveStableswapNGSingleSideSupplyFuseEnterData({asset: USDM, amounts: amounts, minMintAmount: 0})
        );

        // then
        uint256 balanceAfterEnter = ERC20(activeToken.asset).balanceOf(address(fuseMock));
        uint256 lpTokenBalance = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));
        assertEq(balanceAfterEnter, balanceBeforeEnter, "vault balance should not be decreased");
        assertEq(lpTokenBalance, 0);
    }

    // EXIT TESTS

    function testShouldBeAbleToExit() external {
        // given
        SupportedToken memory activeToken = SupportedToken({asset: USDM, name: "USDM"});

        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(
            1,
            address(CURVE_STABLESWAP_NG)
        );
        CurveStableswapNGSingleSideSupplyFuseMock fuseMock = new CurveStableswapNGSingleSideSupplyFuseMock(
            address(fuse)
        );

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();

        _supplyTokensToMockVault(
            activeToken.asset,
            address(fuseMock),
            1_000 * 10 ** ERC20(activeToken.asset).decimals()
        );

        _grantAssetsToMarket(fuse, fuseMock, CURVE_STABLESWAP_NG_POOL);

        uint256 balanceBeforeEnter = ERC20(activeToken.asset).balanceOf(address(fuseMock));

        vm.expectEmit(true, true, true, true);
        emit CurveSupplyStableswapNGSingleSideSupplyEnterFuse(address(fuse), activeToken.asset, amounts, 0);

        vm.prank(address(fuseMock));
        fuseMock.enter(
            CurveStableswapNGSingleSideSupplyFuseEnterData({
                asset: activeToken.asset,
                amounts: amounts,
                minMintAmount: 0
            })
        );

        uint256 balanceBeforeExit = ERC20(activeToken.asset).balanceOf(address(fuseMock));

        uint256 lpTokenBalanceBeforeExit = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));

        uint256 minReceived = CURVE_STABLESWAP_NG.calc_withdraw_one_coin(lpTokenBalanceBeforeExit, 1);

        vm.expectEmit(true, true, true, true);
        emit CurveSupplyStableswapNGSingleSideSupplyExitFuse(
            address(fuse),
            lpTokenBalanceBeforeExit,
            activeToken.asset,
            minReceived
        );

        // when
        vm.prank(address(fuseMock));
        fuseMock.exit(
            CurveStableswapNGSingleSideSupplyFuseExitData({
                asset: activeToken.asset,
                burnAmount: lpTokenBalanceBeforeExit,
                minReceived: minReceived
            })
        );

        // then
        uint256 balanceAfterExit = ERC20(activeToken.asset).balanceOf(address(fuseMock));
        uint256 lpTokenBalanceAfterExit = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));
        assertApproxEqAbs(
            balanceAfterExit + amounts[1] - minReceived,
            balanceBeforeEnter,
            100,
            "vault balance should be increased by amount"
        );
        assertApproxEqAbs(
            balanceBeforeExit,
            balanceBeforeEnter - amounts[1],
            100,
            "Balance before exit should be decreased by deposit amount"
        );
        assertEq(lpTokenBalanceAfterExit, 0, "LP token balance should be burnt to zero");
    }

    function testShouldRevertOnExitWithUnsupportedPoolAsset() external {
        // given
        SupportedToken memory enterToken = SupportedToken({asset: USDM, name: "USDM"});
        SupportedToken memory exitToken = SupportedToken({asset: DAI, name: "DAI"});

        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(
            1,
            address(CURVE_STABLESWAP_NG)
        );
        CurveStableswapNGSingleSideSupplyFuseMock fuseMock = new CurveStableswapNGSingleSideSupplyFuseMock(
            address(fuse)
        );

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();

        _supplyTokensToMockVault(enterToken.asset, address(fuseMock), 1_000 * 10 ** ERC20(enterToken.asset).decimals());

        _grantAssetsToMarket(fuse, fuseMock, CURVE_STABLESWAP_NG_POOL);

        uint256 expectedLpTokenAmount = CURVE_STABLESWAP_NG.calc_token_amount(amounts, true);

        vm.expectEmit(true, true, true, true);
        emit CurveSupplyStableswapNGSingleSideSupplyEnterFuse(address(fuse), enterToken.asset, amounts, 0);

        vm.prank(address(fuseMock));
        fuseMock.enter(
            CurveStableswapNGSingleSideSupplyFuseEnterData({
                asset: enterToken.asset,
                amounts: amounts,
                minMintAmount: 0
            })
        );

        uint256 balanceEnterTokenBeforeExit = ERC20(enterToken.asset).balanceOf(address(fuseMock));

        uint256 lpTokenBalanceBeforeExit = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));

        uint256 minReceived = CURVE_STABLESWAP_NG.calc_withdraw_one_coin(lpTokenBalanceBeforeExit, 1);

        bytes memory error = abi.encodeWithSignature(
            "CurveStableswapNGSingleSideSupplyFuseUnsupportedPoolAsset(address,string)",
            address(exitToken.asset),
            Errors.UNSUPPORTED_ASSET
        );

        // when
        vm.expectRevert(error);
        vm.prank(address(fuseMock));
        fuseMock.exit(
            CurveStableswapNGSingleSideSupplyFuseExitData({
                asset: exitToken.asset,
                burnAmount: expectedLpTokenAmount,
                minReceived: minReceived
            })
        );

        // then
        uint256 balanceEnterTokenAfterExit = ERC20(enterToken.asset).balanceOf(address(fuseMock));
        uint256 lpTokenBalanceAfterExit = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));
        assertEq(balanceEnterTokenAfterExit, balanceEnterTokenBeforeExit, "vault balance should not be decreased");
        assertEq(lpTokenBalanceAfterExit, lpTokenBalanceBeforeExit, "LP token balance should not be decreased");
    }

    function testShouldRevertWhenBurnAmountExitExceedsLPBalance() external {
        // given
        SupportedToken memory activeToken = SupportedToken({asset: USDM, name: "USDM"});

        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(
            1,
            address(CURVE_STABLESWAP_NG)
        );
        CurveStableswapNGSingleSideSupplyFuseMock fuseMock = new CurveStableswapNGSingleSideSupplyFuseMock(
            address(fuse)
        );

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();

        _supplyTokensToMockVault(
            activeToken.asset,
            address(fuseMock),
            1_000 * 10 ** ERC20(activeToken.asset).decimals()
        );

        _grantAssetsToMarket(fuse, fuseMock, CURVE_STABLESWAP_NG_POOL);

        vm.prank(address(fuseMock));
        fuseMock.enter(
            CurveStableswapNGSingleSideSupplyFuseEnterData({
                asset: activeToken.asset,
                amounts: amounts,
                minMintAmount: 0
            })
        );

        uint256 balanceAfterEnter = ERC20(activeToken.asset).balanceOf(address(fuseMock));

        uint256 lpTokenBalance = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));

        uint256 burnAmount = lpTokenBalance + 1;

        vm.expectRevert();
        vm.prank(address(fuseMock));
        fuseMock.exit(
            CurveStableswapNGSingleSideSupplyFuseExitData({
                burnAmount: burnAmount,
                asset: activeToken.asset,
                minReceived: 0
            })
        );

        // then
        uint256 balanceAfterExitAttempt = ERC20(activeToken.asset).balanceOf(address(fuseMock));
        uint256 lpTokenBalanceAfterExitAttempt = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));
        assertEq(balanceAfterEnter, balanceAfterExitAttempt, "vault balance should not be decreased");
        assertEq(lpTokenBalance, lpTokenBalanceAfterExitAttempt, "LP token balance should not be decreased");
    }

    function testShouldRevertWhenMinReceivedIsNotMet() external {
        // given
        SupportedToken memory activeToken = SupportedToken({asset: USDM, name: "USDM"});

        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(
            1,
            address(CURVE_STABLESWAP_NG)
        );
        CurveStableswapNGSingleSideSupplyFuseMock fuseMock = new CurveStableswapNGSingleSideSupplyFuseMock(
            address(fuse)
        );

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();

        _supplyTokensToMockVault(
            activeToken.asset,
            address(fuseMock),
            1_000 * 10 ** ERC20(activeToken.asset).decimals()
        );

        _grantAssetsToMarket(fuse, fuseMock, CURVE_STABLESWAP_NG_POOL);

        vm.prank(address(fuseMock));
        fuseMock.enter(
            CurveStableswapNGSingleSideSupplyFuseEnterData({
                asset: activeToken.asset,
                amounts: amounts,
                minMintAmount: 0
            })
        );

        uint256 balanceAfterEnter = ERC20(activeToken.asset).balanceOf(address(fuseMock));

        uint256 lpTokenBalance = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));

        uint256 minReceived = CURVE_STABLESWAP_NG.calc_withdraw_one_coin(lpTokenBalance, 1) + 1;

        bytes memory error = abi.encodeWithSignature(
            "CurveStableswapNGSingleSideSupplyFuseUnableToMeetMinReceivedAmount(uint256,uint256)",
            CURVE_STABLESWAP_NG.calc_withdraw_one_coin(lpTokenBalance, 1),
            minReceived
        );

        // when
        vm.expectRevert(error);
        vm.prank(address(fuseMock));
        fuseMock.exit(
            CurveStableswapNGSingleSideSupplyFuseExitData({
                burnAmount: lpTokenBalance,
                asset: activeToken.asset,
                minReceived: minReceived
            })
        );

        // then
        uint256 balanceAfterExitAttempt = ERC20(activeToken.asset).balanceOf(address(fuseMock));
        uint256 lpTokenBalanceAfterExitAttempt = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));
        assertEq(balanceAfterEnter, balanceAfterExitAttempt, "vault balance should not be decreased");
        assertEq(lpTokenBalance, lpTokenBalanceAfterExitAttempt, "LP token balance should not be decreased");
    }

    // TODO test when burn amount is set to zero
    function testShouldRevertWhenBurnAmountIsZero() external {
        // given
        SupportedToken memory activeToken = SupportedToken({asset: USDM, name: "USDM"});

        CurveStableswapNGSingleSideSupplyFuse fuse = new CurveStableswapNGSingleSideSupplyFuse(
            1,
            address(CURVE_STABLESWAP_NG)
        );
        CurveStableswapNGSingleSideSupplyFuseMock fuseMock = new CurveStableswapNGSingleSideSupplyFuseMock(
            address(fuse)
        );

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 100 * 10 ** ERC20(USDM).decimals();

        _supplyTokensToMockVault(
            activeToken.asset,
            address(fuseMock),
            1_000 * 10 ** ERC20(activeToken.asset).decimals()
        );

        _grantAssetsToMarket(fuse, fuseMock, CURVE_STABLESWAP_NG_POOL);

        vm.prank(address(fuseMock));
        fuseMock.enter(
            CurveStableswapNGSingleSideSupplyFuseEnterData({
                asset: activeToken.asset,
                amounts: amounts,
                minMintAmount: 0
            })
        );

        uint256 balanceAfterEnter = ERC20(activeToken.asset).balanceOf(address(fuseMock));

        uint256 lpTokenBalance = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));

        bytes memory error = abi.encodeWithSignature("CurveStableswapNGSingleSideSupplyFuseZeroBurnAmount()");

        // when
        vm.expectRevert(error);
        vm.prank(address(fuseMock));
        fuseMock.exit(
            CurveStableswapNGSingleSideSupplyFuseExitData({burnAmount: 0, asset: activeToken.asset, minReceived: 0})
        );

        // then
        uint256 balanceAfterExitAttempt = ERC20(activeToken.asset).balanceOf(address(fuseMock));
        uint256 lpTokenBalanceAfterExitAttempt = ERC20(CURVE_STABLESWAP_NG_POOL).balanceOf(address(fuseMock));
        assertEq(balanceAfterEnter, balanceAfterExitAttempt, "vault balance should not be decreased");
        assertEq(lpTokenBalance, lpTokenBalanceAfterExitAttempt, "LP token balance should not be decreased");
    }

    // TODO Refactor common code into helper functions

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

    function _grantAssetsToMarket(
        CurveStableswapNGSingleSideSupplyFuse fuse,
        CurveStableswapNGSingleSideSupplyFuseMock fuseMock,
        address asset
    ) private {
        address[] memory assets = new address[](1);
        assets[0] = CURVE_STABLESWAP_NG_POOL;
        fuseMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);
    }
}
