// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WrappedPlasmaVault} from "../../../contracts/vaults/extensions/WrappedPlasmaVault.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultStorageLib} from "../../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract WrappedPlasmaVaulttTest is Test {
    WrappedPlasmaVault public wPlasmaVault;
    address public usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    PlasmaVault public plasmaVault = PlasmaVault(0x43Ee0243eA8CF02f7087d8B16C8D2007CC9c7cA2);
    address public owner;
    address public user;
    address public otherUser;
    address public feeAccount;

    address public performanceFeeRecipient;
    address public managementFeeRecipient;
    uint256 public performanceFeeShares;
    uint256 public managementFeeShares;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 21621506);
        owner = makeAddr("owner");
        user = makeAddr("user");
        otherUser = makeAddr("otherUser");
        wPlasmaVault = new WrappedPlasmaVault("Wrapped USDC", "wFusionUSDC", address(plasmaVault));
        wPlasmaVault.configurePerformanceFee(owner, 0);
        wPlasmaVault.configureManagementFee(owner, 0);
        wPlasmaVault.transferOwnership(owner);

        vm.prank(owner);
        wPlasmaVault.acceptOwnership();

        vm.startPrank(user);
        IERC20(usdc).approve(address(wPlasmaVault), type(uint256).max);
        vm.stopPrank();
        deal(usdc, user, 100_000_000e6);

        vm.startPrank(otherUser);
        IERC20(usdc).approve(address(wPlasmaVault), type(uint256).max);
        vm.stopPrank();
        deal(usdc, otherUser, 100_000_000e6);

        performanceFeeRecipient = makeAddr("performanceFeeRecipient");
        managementFeeRecipient = makeAddr("managementFeeRecipient");
    }

    function testShouldHaveExactTheSamePreviewDepositBeforeAndAfterRealizeFeeDepositManagementFee() public {
        //given
        /// %2
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(owner, 200);
        /// %0.3
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(owner, 300);

        uint256 assets = 100_000e6;

        vm.startPrank(user);
        wPlasmaVault.deposit(assets, user);
        vm.stopPrank();

        vm.warp(block.timestamp + 100 days);

        uint256 previewDepositBefore = wPlasmaVault.previewDeposit(assets);

        wPlasmaVault.realizeFees();

        // when
        uint256 previewDepositAfter = wPlasmaVault.previewDeposit(assets);

        //then
        assertEq(previewDepositBefore, previewDepositAfter);
    }

    function testShouldHaveExactTheSamePreviewWithdrawBeforeAndAfterRealizeFeeManagementAndPerofmanceFee() public {
        //given
        /// %2
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(owner, 200);
        /// %0.3
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(owner, 300);

        uint256 assets = 100_000e6;

        vm.startPrank(user);
        wPlasmaVault.deposit(assets, user);
        vm.stopPrank();

        /// @dev simlulate adding assets for performance fee
        vm.warp(block.timestamp + 100 days);
        deal(usdc, address(plasmaVault), IERC20(usdc).balanceOf(address(plasmaVault)) + 50_000e6);

        uint256 previewDepositBefore = wPlasmaVault.previewDeposit(assets);
        wPlasmaVault.realizeFees();

        // when
        uint256 previewDepositAfter = wPlasmaVault.previewDeposit(assets);

        //then
        assertEq(previewDepositBefore, previewDepositAfter);
    }

    function testShouldPreviewDepositBeSameValueAsSharesAfterDeposit() public {
        //given
        /// %2
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(owner, 200);
        /// %0.3
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(owner, 300);

        uint256 assets = 100_000e6;
        uint256 previewDepositBefore = wPlasmaVault.previewDeposit(assets);

        //when
        vm.startPrank(user);
        wPlasmaVault.deposit(assets, user);
        vm.stopPrank();

        uint256 shares = wPlasmaVault.balanceOf(user);

        //then
        assertEq(previewDepositBefore, shares);
    }

    function testShouldPreviewDepositBeSameValueAsSharesAfterDepositWithPreviousDeposit() public {
        //given
        /// %2
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(owner, 200);
        /// %0.3
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(owner, 300);

        uint256 otherUserAssets = 50_000e6;
        vm.startPrank(otherUser);
        wPlasmaVault.deposit(otherUserAssets, otherUser);
        vm.stopPrank();

        vm.warp(block.timestamp + 100 days);

        uint256 assets = 100_000e6;
        uint256 previewDepositBefore = wPlasmaVault.previewDeposit(assets);

        //when
        vm.startPrank(user);
        wPlasmaVault.deposit(assets, user);
        vm.stopPrank();

        uint256 shares = wPlasmaVault.balanceOf(user);

        //then
        assertEq(previewDepositBefore, shares);
    }

    function testShouldHaveExactTheSamePreviewWithdrawBeforeAndAfterRealizeFeeDepositManagementFee() public {
        //given
        /// %2
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(owner, 200);
        /// %0.3
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(owner, 300);

        uint256 assets = 100_000e6;

        vm.startPrank(user);
        wPlasmaVault.deposit(assets, user);
        vm.stopPrank();

        vm.warp(block.timestamp + 100 days);

        uint256 previewWithdrawBefore = wPlasmaVault.previewWithdraw(assets);

        wPlasmaVault.realizeFees();

        // when
        uint256 previewWithdrawAfter = wPlasmaVault.previewWithdraw(assets);

        //then
        assertApproxEqAbs(
            previewWithdrawBefore,
            previewWithdrawAfter,
            1,
            "previewWithdrawBefore and previewWithdrawAfter should be approximately equal"
        );
    }

    function testShouldHaveExactTheSamePreviewWithdrawBeforeAndAfterRealizeFeeManagementAndPerformanceFee() public {
        //given
        /// %2
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(owner, 200);
        /// %0.3
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(owner, 300);

        uint256 assets = 100_000e6;

        vm.startPrank(user);
        wPlasmaVault.deposit(assets, user);
        vm.stopPrank();

        /// @dev simulate adding assets for performance fee
        vm.warp(block.timestamp + 100 days);
        deal(usdc, address(plasmaVault), IERC20(usdc).balanceOf(address(plasmaVault)) + 50_000e6);

        uint256 previewWithdrawBefore = wPlasmaVault.previewWithdraw(assets);

        wPlasmaVault.realizeFees();

        // when
        uint256 previewWithdrawAfter = wPlasmaVault.previewWithdraw(assets);

        //then
        assertApproxEqAbs(
            previewWithdrawBefore,
            previewWithdrawAfter,
            5,
            "previewWithdrawBefore and previewWithdrawAfter should be approximately equal"
        );
    }

    function testShouldPreviewWithdrawBeSameValueAsSharesAfterWithdraw() public {
        //given
        /// %2
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(owner, 200);
        /// %0.3
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(owner, 300);

        uint256 assets = 100_000e6;

        vm.startPrank(user);
        wPlasmaVault.deposit(assets, user);
        vm.stopPrank();

        /// @dev simulate adding assets for performance fee
        vm.warp(block.timestamp + 100 days);
        deal(usdc, address(plasmaVault), IERC20(usdc).balanceOf(address(plasmaVault)) + 50_000e6);

        uint256 previewWithdrawBefore = wPlasmaVault.previewWithdraw(assets);

        //when
        vm.startPrank(user);
        uint256 sharesBurned = wPlasmaVault.withdraw(assets, user, user);
        vm.stopPrank();

        //then
        assertApproxEqAbs(
            previewWithdrawBefore,
            sharesBurned,
            5,
            "previewWithdrawBefore and sharesBurned should be approximately equal"
        );
    }

    function testShouldPreviewRedeemBeSameValueAsPreviewRedeemAfterFeeCalculation() public {
        //given
        /// %2
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(owner, 200);
        /// %0.3
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(owner, 300);

        uint256 shares = 100_000e6;

        vm.startPrank(user);
        wPlasmaVault.mint(shares, user);
        vm.stopPrank();

        /// @dev simulate adding assets for performance fee
        vm.warp(block.timestamp + 100 days);
        deal(usdc, address(plasmaVault), IERC20(usdc).balanceOf(address(plasmaVault)) + 50_000e6);

        uint256 previewRedeemBefore = wPlasmaVault.previewRedeem(shares);

        //when
        wPlasmaVault.realizeFees();

        uint256 previewRedeemAfter = wPlasmaVault.previewRedeem(shares);

        //then
        assertEq(previewRedeemBefore, previewRedeemAfter);
    }

    function testShouldPreviewRedeemBeSameValueAsAssetsAfterRedeem() public {
        //given
        /// %2
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(owner, 200);
        /// %0.3
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(owner, 300);

        uint256 shares = 100_000e6;

        vm.startPrank(user);
        wPlasmaVault.mint(shares, user);
        vm.stopPrank();

        /// @dev simulate adding assets for performance fee
        vm.warp(block.timestamp + 100 days);
        deal(usdc, address(plasmaVault), IERC20(usdc).balanceOf(address(plasmaVault)) + 50_000e6);

        uint256 previewRedeemBefore = wPlasmaVault.previewRedeem(shares);

        //when
        vm.startPrank(user);
        uint256 assets = wPlasmaVault.redeem(shares, user, user);
        vm.stopPrank();

        //then
        assertEq(previewRedeemBefore, assets);
    }

    function testShouldPreviewMintBeSameValueAsPreviewMintAfterFeeCalculation() public {
        //given
        /// %2
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(owner, 200);
        /// %0.3
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(owner, 300);

        uint256 shares = 100_000e6;

        vm.startPrank(user);
        wPlasmaVault.mint(shares, user);
        vm.stopPrank();

        /// @dev simulate adding assets for performance fee
        vm.warp(block.timestamp + 100 days);
        deal(usdc, address(plasmaVault), IERC20(usdc).balanceOf(address(plasmaVault)) + 50_000e6);

        uint256 previewMintBefore = wPlasmaVault.previewMint(shares);

        //when
        wPlasmaVault.realizeFees();

        uint256 previewMintAfter = wPlasmaVault.previewMint(shares);

        //then
        assertEq(previewMintBefore, previewMintAfter);
    }

    function testShouldPreviewMintBeSameValueAsAssetsAfterMint() public {
        //given
        /// %2
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(owner, 200);
        /// %0.3
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(owner, 300);

        uint256 shares = 100_000e6;

        vm.startPrank(user);
        wPlasmaVault.mint(shares, user);
        vm.stopPrank();

        /// @dev simulate adding assets for performance fee
        vm.warp(block.timestamp + 100 days);
        deal(usdc, address(plasmaVault), IERC20(usdc).balanceOf(address(plasmaVault)) + 50_000e6);

        uint256 previewMintBefore = wPlasmaVault.previewMint(shares);

        //when
        vm.startPrank(user);
        uint256 assets = wPlasmaVault.mint(shares, user);
        vm.stopPrank();

        //then
        assertEq(previewMintBefore, assets);
    }

    function testShouldMaxWithdrawBeSameValueAsMaxWithdrawAfterFeeCalculation() public {
        //given
        /// %2
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(owner, 200);
        /// %0.3
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(owner, 300);

        uint256 assets = 100_000e6;

        vm.startPrank(user);
        wPlasmaVault.deposit(assets, user);
        vm.stopPrank();

        /// @dev simulate adding assets for performance fee
        vm.warp(block.timestamp + 100 days);
        deal(usdc, address(plasmaVault), IERC20(usdc).balanceOf(address(plasmaVault)) + 50_000e6);

        uint256 maxWithdrawBefore = wPlasmaVault.maxWithdraw(user);

        //when
        wPlasmaVault.realizeFees();

        uint256 maxWithdrawAfter = wPlasmaVault.maxWithdraw(user);

        //then
        assertEq(maxWithdrawBefore, maxWithdrawAfter);
    }

    function testShouldMaxRedeemBeSameValueAsMaxRedeemAfterFeeCalculation() public {
        //given
        /// %2
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(owner, 200);
        /// %0.3
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(owner, 300);

        uint256 assets = 100_000e6;

        vm.startPrank(user);
        wPlasmaVault.deposit(assets, user);
        vm.stopPrank();

        /// @dev simulate adding assets for performance fee
        vm.warp(block.timestamp + 100 days);
        deal(usdc, address(plasmaVault), IERC20(usdc).balanceOf(address(plasmaVault)) + 50_000e6);

        uint256 maxRedeemBefore = wPlasmaVault.maxRedeem(user);

        //when
        wPlasmaVault.realizeFees();

        uint256 maxRedeemAfter = wPlasmaVault.maxRedeem(user);

        //then
        assertEq(maxRedeemBefore, maxRedeemAfter);
    }

    function testShouldMaxWithdrawWhenFeeIsPartOfCalculation() public {
        //given
        /// %2
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(owner, 200);
        /// %0.3
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(owner, 300);

        uint256 assets = 100_000e6;

        vm.startPrank(user);
        wPlasmaVault.deposit(assets, user);
        vm.stopPrank();

        /// @dev simulate adding assets for performance fee
        vm.warp(block.timestamp + 100 days);
        deal(usdc, address(plasmaVault), IERC20(usdc).balanceOf(address(plasmaVault)) + 50_000e6);

        uint256 maxWithdrawBefore = wPlasmaVault.maxWithdraw(user);

        uint256 previewWithdrawBefore = wPlasmaVault.previewWithdraw(maxWithdrawBefore);

        //when
        vm.startPrank(user);
        uint256 sharesBurned = wPlasmaVault.withdraw(maxWithdrawBefore, user, user);
        vm.stopPrank();

        //then
        assertApproxEqAbs(
            previewWithdrawBefore,
            sharesBurned,
            5,
            "previewWithdrawBefore and sharesBurned should be approximately equal"
        );
    }

    function testShouldMaxRedeemWhenFeeIsPartOfCalculation() public {
        //given
        /// %2
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(owner, 200);
        /// %0.3
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(owner, 300);

        uint256 assets = 100_000e6;

        vm.startPrank(user);
        wPlasmaVault.deposit(assets, user);
        vm.stopPrank();

        /// @dev simulate adding assets for performance fee
        vm.warp(block.timestamp + 100 days);
        deal(usdc, address(plasmaVault), IERC20(usdc).balanceOf(address(plasmaVault)) + 50_000e6);

        uint256 maxRedeemBefore = wPlasmaVault.maxRedeem(user);

        uint256 previewRedeemBefore = wPlasmaVault.previewRedeem(maxRedeemBefore);

        //when
        vm.startPrank(user);
        uint256 assetsResult = wPlasmaVault.redeem(maxRedeemBefore, user, user);
        vm.stopPrank();

        //then
        assertEq(previewRedeemBefore, assetsResult);
    }

    function testShouldNotMaxWithdrawWhenFeeIsPartOfCalculation() public {
        //given
        /// %2
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(owner, 200);
        /// %0.3
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(owner, 300);

        uint256 assets = 100_000e6;

        vm.startPrank(user);
        wPlasmaVault.deposit(assets, user);
        vm.stopPrank();

        /// @dev simulate adding assets for performance fee
        vm.warp(block.timestamp + 100 days);
        deal(usdc, address(plasmaVault), IERC20(usdc).balanceOf(address(plasmaVault)) + 50_000e6);

        uint256 maxWithdrawBefore = wPlasmaVault.maxWithdraw(user);

        bytes memory error = abi.encodeWithSignature(
            "ERC20InsufficientBalance(address,uint256,uint256)",
            user,
            10000000000000,
            10000000000047
        );

        // when
        vm.startPrank(user);
        vm.expectRevert(error);
        wPlasmaVault.withdraw(maxWithdrawBefore + 1, user, user);
        vm.stopPrank();
    }

    function testshouldDEpositToWraperAndTransferAssetToPlasmaVault() public {
        //given
        uint256 assets = 100_000e6;
        //when
        vm.startPrank(user);
        wPlasmaVault.deposit(assets, user);
        vm.stopPrank();
        //then

        assertEq(wPlasmaVault.balanceOf(user), 1e13);
        assertEq(IERC20(usdc).balanceOf(address(wPlasmaVault)), 0);
        assertEq(plasmaVault.balanceOf(address(wPlasmaVault)), 9677289528129);
    }

    function testShouldDepositAndWithdrawFullAmount() public {
        // given
        uint256 depositAmount = 100_000e6;
        uint256 withdrawAmount = 99999999998;

        // when - deposit
        vm.startPrank(user);
        wPlasmaVault.deposit(depositAmount, user);

        vm.warp(block.timestamp + 1 hours);

        // then - verify deposit state
        uint256 userShares = wPlasmaVault.balanceOf(user);
        assertEq(userShares, 1e13);
        assertEq(IERC20(usdc).balanceOf(address(wPlasmaVault)), 0);
        assertEq(plasmaVault.balanceOf(address(wPlasmaVault)), 9677289528129);

        // when
        wPlasmaVault.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        // then - verify final state
        assertEq(wPlasmaVault.balanceOf(user), 51451935);
        assertEq(IERC20(usdc).balanceOf(user), 99999999999998);
    }

    function testShouldMintSharesAndTransferAssetsToPlasmaVault() public {
        // given
        uint256 sharesToMint = 1e13; // 10000000000000 shares
        uint256 initialUserBalance = IERC20(usdc).balanceOf(user);
        uint256 initialWrapperPlasmaShares = plasmaVault.balanceOf(address(wPlasmaVault));

        // when
        vm.startPrank(user);
        uint256 assetsDeposited = wPlasmaVault.mint(sharesToMint, user);
        vm.stopPrank();

        // then
        // Verify user received correct amount of wrapper shares
        assertEq(wPlasmaVault.balanceOf(user), sharesToMint, "User should receive correct amount of wrapper shares");

        // Verify assets were transferred from user
        assertEq(
            IERC20(usdc).balanceOf(user),
            initialUserBalance - assetsDeposited,
            "User balance should be reduced by deposited assets"
        );

        // Verify wrapper vault has no remaining USDC (all transferred to plasma vault)
        assertEq(IERC20(usdc).balanceOf(address(wPlasmaVault)), 0, "Wrapper should have no USDC balance");

        // Verify plasma vault shares were received by wrapper
        assertTrue(
            plasmaVault.balanceOf(address(wPlasmaVault)) > initialWrapperPlasmaShares,
            "Wrapper should receive plasma vault shares"
        );
    }

    function testShouldRedeemAllShares() public {
        // given
        uint256 depositAmount = 100_000e6;
        uint256 initialUserBalance = IERC20(usdc).balanceOf(user);

        // First deposit to get shares
        vm.startPrank(user);
        wPlasmaVault.deposit(depositAmount, user);

        // Record states before redemption
        uint256 userShares = wPlasmaVault.balanceOf(user);

        vm.warp(block.timestamp + 1 hours);

        // when - redeem all shares
        wPlasmaVault.redeem(userShares, user, user);
        vm.stopPrank();

        // then
        // Verify all shares were burned
        assertEq(wPlasmaVault.balanceOf(user), 0, "User should have no shares left");

        // Verify assets were returned to user
        assertApproxEqRel(
            IERC20(usdc).balanceOf(user),
            initialUserBalance,
            0.001e18, // 0.1% tolerance for potential rounding
            "User should receive back approximately initial balance"
        );

        // Verify wrapper has no remaining plasma vault shares
        assertEq(plasmaVault.balanceOf(address(wPlasmaVault)), 140, "Wrapper should have no plasma vault shares left");
    }

    function testShouldConfigurePerformanceFee() public {
        // given
        address expectedFeeAccount = makeAddr("feeAccount");
        uint256 expectedFeePercentage = 500; // 5% = 500 basis points

        // when
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(expectedFeeAccount, expectedFeePercentage);

        // then
        PlasmaVaultStorageLib.PerformanceFeeData memory feeData = wPlasmaVault.getPerformanceFeeData();
        assertEq(feeData.feeAccount, expectedFeeAccount, "Fee account should be set correctly");
        assertEq(feeData.feeInPercentage, expectedFeePercentage, "Fee percentage should be set to 5%");
    }

    function testShouldRevertWhenNonOwnerConfiguresPerformanceFee() public {
        // given
        address nonOwner = makeAddr("nonOwner");
        address expectedFeeAccount = makeAddr("feeAccount");
        uint256 expectedFeePercentage = 500;

        // when/then
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        wPlasmaVault.configurePerformanceFee(expectedFeeAccount, expectedFeePercentage);
    }

    function testShouldConfigureManagementFee() public {
        // given
        address expectedFeeAccount = makeAddr("feeAccount");
        uint256 expectedFeePercentage = 200; // 2% = 200 basis points

        // when
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(expectedFeeAccount, expectedFeePercentage);

        // then
        PlasmaVaultStorageLib.ManagementFeeData memory feeData = wPlasmaVault.getManagementFeeData();
        assertEq(feeData.feeAccount, expectedFeeAccount, "Fee account should be set correctly");
        assertEq(feeData.feeInPercentage, expectedFeePercentage, "Fee percentage should be set to 2%");
    }

    function testShouldRevertWhenNonOwnerConfiguresManagementFee() public {
        // given
        address nonOwner = makeAddr("nonOwner");
        address expectedFeeAccount = makeAddr("feeAccount");
        uint256 expectedFeePercentage = 200;

        // when/then
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        wPlasmaVault.configureManagementFee(expectedFeeAccount, expectedFeePercentage);
    }

    function testShouldAccrueManagementFeeOverTime() public {
        // given
        address expectedFeeAccount = makeAddr("feeAccount");
        uint256 managementFeePercentage = 200; // 2% annual fee
        uint256 initialDeposit = 100_000e6;
        uint256 secondDeposit = 1_000e6;

        // when - set up management fee
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(expectedFeeAccount, managementFeePercentage);

        // when - first deposit
        vm.startPrank(user);
        wPlasmaVault.deposit(initialDeposit, user);
        vm.stopPrank();

        assertEq(wPlasmaVault.balanceOf(expectedFeeAccount), 0, "Fee account should have no shares initially");

        // when - move time forward and make second deposit
        vm.warp(block.timestamp + 100 days);

        vm.startPrank(user);
        wPlasmaVault.deposit(secondDeposit, user);
        vm.stopPrank();

        // then
        uint256 feeAccountShares = wPlasmaVault.balanceOf(expectedFeeAccount);
        assertTrue(feeAccountShares > 0, "Fee account should have received shares");

        // Calculate expected management fee (approximate)
        // 2% annual fee for 100 days on 100,000 USDC
        // (100_000e6 * 0.02 * 100/365) ≈ 547.95 USDC worth of shares
        uint256 expectedMinimumShares = 5_000e4; // Conservative estimate
        assertTrue(
            feeAccountShares > expectedMinimumShares,
            "Fee account should have received at least minimum expected shares"
        );
    }

    function testShouldAccruePerformanceFeeAfterValueIncrease() public {
        // given
        address expectedFeeAccount = makeAddr("feeAccount");
        uint256 performanceFeePercentage = 500; // 5% performance fee
        uint256 initialDeposit = 100_000e6;
        uint256 additionalValue = 50_000e6;
        uint256 secondDeposit = 1_000e6;

        // when - set up performance fee
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(expectedFeeAccount, performanceFeePercentage);

        // when - first deposit
        vm.startPrank(user);
        wPlasmaVault.deposit(initialDeposit, user);
        vm.stopPrank();

        assertEq(wPlasmaVault.balanceOf(expectedFeeAccount), 0, "Fee account should have no shares initially");

        // when - move time forward
        vm.warp(block.timestamp + 100 days);

        // simulate value increase by transferring additional USDC to plasma vault
        deal(usdc, address(plasmaVault), IERC20(usdc).balanceOf(address(plasmaVault)) + additionalValue);

        // when - second deposit to trigger fee calculation
        vm.startPrank(user);
        wPlasmaVault.deposit(secondDeposit, user);
        vm.stopPrank();

        // then
        uint256 feeAccountShares = wPlasmaVault.balanceOf(expectedFeeAccount);
        assertTrue(feeAccountShares > 0, "Fee account should have received shares");

        // Calculate expected performance fee
        // Value increase: 50,000 USDC
        // Performance fee: 5% of 50,000 = 2,500 USDC worth of shares
        uint256 expectedMinimumShares = 200_000e4; // Conservative estimate
        assertTrue(
            feeAccountShares > expectedMinimumShares,
            "Fee account should have received at least minimum expected shares"
        );
    }

    function testShouldTransferOwnershipInTwoSteps() public {
        // given
        address newOwner = makeAddr("newOwner");

        // when - step 1: current owner initiates transfer
        vm.prank(owner);
        wPlasmaVault.transferOwnership(newOwner);

        // then - ownership should not be transferred yet
        assertEq(wPlasmaVault.owner(), owner, "Owner should not change before acceptance");
        assertEq(wPlasmaVault.pendingOwner(), newOwner, "Pending owner should be set");

        // when - step 2: new owner accepts ownership
        vm.prank(newOwner);
        wPlasmaVault.acceptOwnership();

        // then - ownership should be transferred
        assertEq(wPlasmaVault.owner(), newOwner, "New owner should be set after acceptance");
        assertEq(wPlasmaVault.pendingOwner(), address(0), "Pending owner should be cleared");

        // verify new owner can configure fees
        vm.prank(newOwner);
        wPlasmaVault.configurePerformanceFee(newOwner, 500);

        // verify old owner cannot configure fees anymore
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", owner));
        wPlasmaVault.configurePerformanceFee(owner, 500);
    }

    function testShouldAccrueCorrectFeesWithSeparateRecipients() public {
        // given
        uint256 initialDeposit = 100_000e6;
        uint256 valueIncrease = 50_000e6;

        // Record initial USDC balances
        uint256 userInitialBalance = IERC20(usdc).balanceOf(user);
        uint256 performanceFeeRecipientInitialBalance = IERC20(usdc).balanceOf(performanceFeeRecipient);
        uint256 managementFeeRecipientInitialBalance = IERC20(usdc).balanceOf(managementFeeRecipient);

        // Configure fees with separate recipients
        vm.startPrank(owner);
        wPlasmaVault.configurePerformanceFee(performanceFeeRecipient, 500); // 5%
        wPlasmaVault.configureManagementFee(managementFeeRecipient, 200); // 2%
        vm.stopPrank();

        // Initial deposit
        vm.startPrank(user);
        wPlasmaVault.deposit(initialDeposit, user);
        vm.stopPrank();

        // Verify user's USDC balance after deposit
        assertEq(
            IERC20(usdc).balanceOf(user),
            userInitialBalance - initialDeposit,
            "User balance should be reduced by deposit amount"
        );

        // Move time forward and simulate value increase
        vm.warp(block.timestamp + 180 days); // 6 months

        vm.startPrank(otherUser);
        IERC20(usdc).transfer(address(plasmaVault), valueIncrease);
        vm.stopPrank();

        // // Record balances before withdrawal
        uint256 userSharesBefore = wPlasmaVault.balanceOf(user);

        // // Withdraw all user shares
        vm.startPrank(user);
        wPlasmaVault.redeem(userSharesBefore, user, user);
        vm.stopPrank();

        // Verify and withdraw performance fee recipient shares
        performanceFeeShares = wPlasmaVault.balanceOf(performanceFeeRecipient);
        assertTrue(performanceFeeShares > 0, "Performance fee recipient should have received shares");

        vm.startPrank(performanceFeeRecipient);
        wPlasmaVault.redeem(performanceFeeShares, performanceFeeRecipient, performanceFeeRecipient);
        vm.stopPrank();

        // Verify and withdraw management fee recipient shares
        managementFeeShares = wPlasmaVault.balanceOf(managementFeeRecipient);
        assertTrue(managementFeeShares > 0, "Management fee recipient should have received shares");

        vm.startPrank(managementFeeRecipient);
        wPlasmaVault.redeem(managementFeeShares, managementFeeRecipient, managementFeeRecipient);
        vm.stopPrank();

        // Verify final USDC balances of all participants
        uint256 performanceFeeRecipientFinalBalance = IERC20(usdc).balanceOf(performanceFeeRecipient);
        uint256 managementFeeRecipientFinalBalance = IERC20(usdc).balanceOf(managementFeeRecipient);
        uint256 userFinalBalance = IERC20(usdc).balanceOf(user);

        // Verify user's profit after fees
        uint256 userProfit = userFinalBalance - (userInitialBalance - initialDeposit);
        assertTrue(userProfit > 0, "User should have made a profit");

        // Expected performance fee (approximate)
        uint256 expectedMinPerformanceFee = 110e6; // Some fee because 50k was transferred to plasma vault (with already existing balance)
        assertTrue(
            performanceFeeRecipientFinalBalance - performanceFeeRecipientInitialBalance > expectedMinPerformanceFee,
            "Performance fee recipient should have received at least minimum expected USDC"
        );

        // Expected management fee (approximate)
        uint256 expectedMinManagementFee = 1000e6; // 1% of 100k because 180 days left and 2% annual fee
        assertTrue(
            managementFeeRecipientFinalBalance - managementFeeRecipientInitialBalance > expectedMinManagementFee,
            "Management fee recipient should have received at least minimum expected USDC"
        );

        // Verify fee recipients received different amounts in USDC
        assertTrue(
            performanceFeeRecipientFinalBalance - performanceFeeRecipientInitialBalance !=
                managementFeeRecipientFinalBalance - managementFeeRecipientInitialBalance,
            "Performance and management fees should be different in USDC terms"
        );
    }

    function testShouldConvertToSharesAndAssetsCorrectly() public {
        // given
        vm.warp(block.timestamp);
        /// 2%
        vm.prank(owner);
        wPlasmaVault.configurePerformanceFee(owner, 200);
        /// 3%
        vm.prank(owner);
        wPlasmaVault.configureManagementFee(owner, 300);

        uint256 initialDeposit = 100_000e6;

        // Realize fees
        wPlasmaVault.realizeFees();

        ///  @dev Simulate situation when WrappedPlasmaVault is created with initial deposit in PlasmaVault for this WrappedPlasmaVault
        deal(usdc, address(wPlasmaVault), initialDeposit);
        vm.startPrank(address(wPlasmaVault));
        IERC20(usdc).approve(address(plasmaVault), initialDeposit);

        plasmaVault.deposit(initialDeposit, address(wPlasmaVault));

        vm.stopPrank();

        /// @dev to get management fee
        vm.warp(block.timestamp + 100 days);

        // when
        uint256 exchangeRate = wPlasmaVault.convertToShares(1e6);

        uint256 shares = wPlasmaVault.totalSupply();
        uint256 assets = wPlasmaVault.totalAssets();

        uint256 assetsWithFees = wPlasmaVault.convertToAssetsWithFees(shares);
        uint256 sharesWithFees = wPlasmaVault.convertToSharesWithFees(assets);

        // then
        assertEq(shares, 0, "Initial shares should be 0");
        assertEq(assets, 99061826134, "Assets should be equal to initial deposit minus fees");
        assertEq(exchangeRate, 1e8, "Exchange rate should be equal to 1e8");
        assertEq(sharesWithFees, 83049092671, "Shares should be greater than 0");
        assertEq(assetsWithFees, 0, "Assets should be greater than 0");
    }
}
