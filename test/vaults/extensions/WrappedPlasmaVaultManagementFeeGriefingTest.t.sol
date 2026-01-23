// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {WrappedPlasmaVault} from "../../../contracts/vaults/extensions/WrappedPlasmaVault.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultLib} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "../../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title WrappedPlasmaVaultManagementFeeGriefingTest
/// @notice Unit tests for management fee griefing attack fix in WrappedPlasmaVaultBase (IL-6751)
/// @dev Tests verify that timestamp is not updated when fee rounds to zero in wrapped vault context
contract WrappedPlasmaVaultManagementFeeGriefingTest is Test {
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    PlasmaVault public constant PLASMA_VAULT = PlasmaVault(0x43Ee0243eA8CF02f7087d8B16C8D2007CC9c7cA2);

    WrappedPlasmaVault public wPlasmaVault;
    address public owner;
    address public user;
    address public managementFeeRecipient;

    uint256 public constant MANAGEMENT_FEE_IN_PERCENTAGE = 30; // 0.3% annual

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 21621506);

        owner = makeAddr("owner");
        user = makeAddr("user");
        managementFeeRecipient = makeAddr("managementFeeRecipient");

        // Deploy WrappedPlasmaVault with correct parameter order:
        // name, symbol, plasmaVault, owner, managementFeeAccount, managementFee%, performanceFeeAccount, performanceFee%
        // Note: Both fee accounts must be non-zero addresses (validation requirement)
        wPlasmaVault = new WrappedPlasmaVault(
            "Wrapped Fusion USDC",
            "wfUSDC",
            address(PLASMA_VAULT),
            owner,                              // wrappedPlasmaVaultOwner
            managementFeeRecipient,             // managementFeeAccount
            MANAGEMENT_FEE_IN_PERCENTAGE,       // managementFeePercentage (0.3%)
            owner,                              // performanceFeeAccount (use owner, fee is 0%)
            0                                   // performanceFeePercentage (0%)
        );

        // Setup user
        deal(USDC, user, 100_000_000e6);
        vm.prank(user);
        IERC20(USDC).approve(address(wPlasmaVault), type(uint256).max);
    }

    // ============ Core Griefing Prevention Tests ============

    /// @notice Verifies that timestamp is NOT updated when fee rounds to zero
    function test_wrappedVault_timestampNotUpdatedWhenFeeRoundsToZero() public {
        // given - Small TVL that causes fee to round to zero
        uint256 smallDeposit = 100e6; // 100 USDC

        vm.prank(user);
        wPlasmaVault.deposit(smallDeposit, user);

        // Get timestamp after initial deposit
        uint256 timestampBefore = wPlasmaVault.getManagementFeeData().lastUpdateTimestamp;

        // Advance time by 1 second (fee will be negligible)
        vm.warp(block.timestamp + 1);

        // when - Trigger fee realization via realizeFees
        wPlasmaVault.realizeFees();

        // then - Timestamp should NOT be updated because shares rounded to zero
        uint256 timestampAfter = wPlasmaVault.getManagementFeeData().lastUpdateTimestamp;

        assertEq(timestampAfter, timestampBefore, "Timestamp should not be updated when shares == 0");
    }

    /// @notice Verifies fees accumulate correctly in wrapped vault
    function test_wrappedVault_feeAccumulatesCorrectly() public {
        // given - Medium TVL
        uint256 deposit = 10_000e6; // 10K USDC

        vm.prank(user);
        wPlasmaVault.deposit(deposit, user);

        uint256 recipientSharesBefore = wPlasmaVault.balanceOf(managementFeeRecipient);

        // when - Multiple calls with small time intervals (some may round to zero)
        for (uint256 i; i < 20; ) {
            vm.warp(block.timestamp + 1);
            wPlasmaVault.realizeFees();
            unchecked {
                ++i;
            }
        }

        // Advance time significantly
        vm.warp(block.timestamp + 10 days);
        wPlasmaVault.realizeFees();

        // then - Accumulated fee should be paid
        uint256 recipientSharesAfter = wPlasmaVault.balanceOf(managementFeeRecipient);
        assertGt(recipientSharesAfter, recipientSharesBefore, "Fee should accumulate and be paid");
    }

    /// @notice Simulates griefing attack on wrapped vault
    function test_wrappedVault_griefingAttackPrevented() public {
        // given - Realistic TVL
        uint256 deposit = 50_000e6; // 50K USDC

        vm.prank(user);
        wPlasmaVault.deposit(deposit, user);

        uint256 recipientSharesBefore = wPlasmaVault.balanceOf(managementFeeRecipient);
        uint256 timestampStart = wPlasmaVault.getManagementFeeData().lastUpdateTimestamp;

        // when - Attacker calls realizeFees repeatedly (simulating griefing)
        uint256 iterations = 100;
        for (uint256 i; i < iterations; ) {
            vm.warp(block.timestamp + 10); // 10 seconds per call
            wPlasmaVault.realizeFees();
            unchecked {
                ++i;
            }
        }

        // then - Fee should still accumulate (attack prevented)
        uint256 recipientSharesAfter = wPlasmaVault.balanceOf(managementFeeRecipient);
        uint256 timestampEnd = wPlasmaVault.getManagementFeeData().lastUpdateTimestamp;

        // Timestamp should have advanced (some mints succeeded)
        assertGt(timestampEnd, timestampStart, "Timestamp should advance as fees accumulate");

        // Some fees should be collected
        assertGt(recipientSharesAfter, recipientSharesBefore, "Fee should be collected despite griefing attempts");
    }

    /// @notice Verifies large TVL wrapped vaults behave normally
    function test_wrappedVault_normalOperationForLargeTVL() public {
        // given - Large TVL
        uint256 largeDeposit = 5_000_000e6; // 5M USDC

        vm.prank(user);
        wPlasmaVault.deposit(largeDeposit, user);

        uint256 recipientSharesBefore = wPlasmaVault.balanceOf(managementFeeRecipient);

        // when - Advance time and realize fees
        vm.warp(block.timestamp + 30 days);
        wPlasmaVault.realizeFees();

        // then - Fee should be collected normally
        uint256 recipientSharesAfter = wPlasmaVault.balanceOf(managementFeeRecipient);
        assertGt(recipientSharesAfter, recipientSharesBefore, "Large TVL should generate fees normally");

        // Verify timestamp is current
        assertEq(wPlasmaVault.getManagementFeeData().lastUpdateTimestamp, block.timestamp, "Timestamp should be current");
    }

    /// @notice Verifies timestamp update only when shares > 0
    function test_wrappedVault_timestampUpdatedOnlyWhenMintSucceeds() public {
        // given - Large TVL
        uint256 largeDeposit = 1_000_000e6; // 1M USDC

        vm.prank(user);
        wPlasmaVault.deposit(largeDeposit, user);

        // Advance time significantly
        vm.warp(block.timestamp + 7 days);

        uint256 timestampBefore = wPlasmaVault.getManagementFeeData().lastUpdateTimestamp;

        // when - Call realizeFees (should mint shares)
        wPlasmaVault.realizeFees();

        // then - Timestamp should be updated
        uint256 timestampAfter = wPlasmaVault.getManagementFeeData().lastUpdateTimestamp;

        assertGt(timestampAfter, timestampBefore, "Timestamp should be updated when shares > 0");
        assertEq(timestampAfter, block.timestamp, "Timestamp should be current block timestamp");
    }

    // ============ Edge Case Tests ============

    /// @notice Verifies zero TVL scenario
    function test_wrappedVault_edgeCaseZeroTVL() public {
        // given - No deposits
        vm.warp(block.timestamp + 1 days);

        // when/then - Should not revert
        wPlasmaVault.realizeFees();
    }

    /// @notice Verifies no time elapsed scenario
    function test_wrappedVault_edgeCaseNoTimeElapsed() public {
        // given - Deposit
        uint256 deposit = 1_000_000e6;

        vm.prank(user);
        wPlasmaVault.deposit(deposit, user);

        // when - Call realizeFees immediately (same timestamp)
        wPlasmaVault.realizeFees();

        // then - Should return early (no fees collected)
        uint256 recipientShares = wPlasmaVault.balanceOf(managementFeeRecipient);
        assertEq(recipientShares, 0, "No fees when no time elapsed");
    }

    /// @notice Verifies behavior with zero management fee percentage
    function test_wrappedVault_edgeCaseZeroFeePercentage() public {
        // given - Deploy vault with zero management fee
        // Note: Both fee accounts must be non-zero addresses (validation requirement)
        WrappedPlasmaVault zeroFeeVault = new WrappedPlasmaVault(
            "Zero Fee Vault",
            "zfUSDC",
            address(PLASMA_VAULT),
            owner,                      // wrappedPlasmaVaultOwner
            managementFeeRecipient,     // managementFeeAccount (required non-zero)
            0,                          // managementFeePercentage (0%)
            owner,                      // performanceFeeAccount (required non-zero)
            0                           // performanceFeePercentage (0%)
        );

        deal(USDC, user, 1_000_000e6);
        vm.prank(user);
        IERC20(USDC).approve(address(zeroFeeVault), type(uint256).max);

        vm.prank(user);
        zeroFeeVault.deposit(1_000_000e6, user);

        vm.warp(block.timestamp + 30 days);

        // when - Call realizeFees
        zeroFeeVault.realizeFees();

        // then - No fees should be collected
        uint256 recipientShares = zeroFeeVault.balanceOf(managementFeeRecipient);
        assertEq(recipientShares, 0, "No fees with zero fee percentage");
    }

    /// @notice Verifies multiple deposits don't affect fee accumulation
    function test_wrappedVault_multipleDepositsPreserveFeeAccrual() public {
        // given - Initial deposit
        vm.prank(user);
        wPlasmaVault.deposit(10_000e6, user);

        vm.warp(block.timestamp + 5 days);

        // Additional deposits
        vm.prank(user);
        wPlasmaVault.deposit(10_000e6, user);

        vm.warp(block.timestamp + 5 days);

        // when - Realize fees
        wPlasmaVault.realizeFees();

        // then - Fee should reflect full 10 day period
        uint256 recipientShares = wPlasmaVault.balanceOf(managementFeeRecipient);
        assertGt(recipientShares, 0, "Fee should accumulate across multiple deposits");
    }
}
