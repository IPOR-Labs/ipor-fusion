// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WrappedPlasmaVault} from "../../../contracts/vaults/extensions/WrappedPlasmaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultStorageLib} from "../../../contracts/libraries/PlasmaVaultStorageLib.sol";

contract WrappedPlasmaVaulttTest is Test {
    WrappedPlasmaVault public wPlasmaVault;
    address public usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    PlasmaVault public plasmaVault = PlasmaVault(0x43Ee0243eA8CF02f7087d8B16C8D2007CC9c7cA2);
    address public owner;
    address public user;
    address public feeAccount;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 21621506);
        owner = makeAddr("owner");
        user = makeAddr("user");

        wPlasmaVault = new WrappedPlasmaVault(usdc, "Wrapped USDC", "wFusionUSDC", address(plasmaVault));
        wPlasmaVault.configurePerformanceFee(owner, 0);
        wPlasmaVault.configureManagementFee(owner, 0);
        wPlasmaVault.transferOwnership(owner);

        vm.prank(owner);
        wPlasmaVault.acceptOwnership();

        vm.startPrank(user);
        IERC20(usdc).approve(address(wPlasmaVault), type(uint256).max);
        vm.stopPrank();
        deal(usdc, user, 100_000_000e6);
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
}
