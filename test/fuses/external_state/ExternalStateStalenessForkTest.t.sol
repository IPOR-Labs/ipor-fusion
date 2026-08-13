// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ExternalStateForkTestBase} from "./ExternalStateForkTestBase.t.sol";
import {ExternalStateErrors} from "../../../contracts/fuses/external_state/errors/ExternalStateErrors.sol";

/// @title ExternalStateStalenessForkTest
/// @notice Fork coverage for the staleness pre-hook gate on a REAL `PlasmaVault`: once a balance
///         account has been updated and then goes longer than `stalenessMax` without a refresh,
///         user-facing operations (here: `deposit`) revert; a fresh custodian confirm clears the
///         gate. The pre-hook is registered via `setPreHookImplementations` — production wiring.
contract ExternalStateStalenessForkTest is ExternalStateForkTestBase {
    function test_fork_stalenessBlocksDepositAfterThreshold() public {
        _createExecutor();
        _registerPausePreHook();

        // Confirm one account so oldest > 0.
        _custodianConfirm(balanceAccountA, 100e6);
        uint256 lastUpdated = block.timestamp;

        // Warp well past STALENESS_MAX_S.
        vm.warp(block.timestamp + STALENESS_MAX_S + 1);

        vm.expectRevert(
            abi.encodeWithSelector(ExternalStateErrors.ExternalStatePreHookStale.selector, lastUpdated, block.timestamp, STALENESS_MAX_S)
        );
        vm.prank(user);
        vault.deposit(1e6, user);
    }

    function test_fork_stalenessClearsWhenCustodianUpdates() public {
        _createExecutor();
        _registerPausePreHook();

        _custodianConfirm(balanceAccountA, 100e6);
        vm.warp(block.timestamp + STALENESS_MAX_S + 10);

        // Confirm a fresh update (rate limiter satisfied by the warp above).
        _custodianConfirm(balanceAccountA, 110e6);

        // Pre-hook passes again — a real user deposit goes through.
        _userDeposit(1e6);
    }

    /// @notice When no balance account has been confirmed yet (`oldest == 0`), the pre-hook
    ///         should NOT block even far beyond `stalenessMax` — the staleness gate only activates
    ///         after the first confirmed update.
    function test_fork_stalenessExemptWhenNoAccountHasBeenUpdated() public {
        _createExecutor();
        _registerPausePreHook();

        vm.warp(block.timestamp + STALENESS_MAX_S + 10_000);

        // No revert — oldest == 0 means "no data yet", so the gate is exempt.
        _userDeposit(1e6);
    }

    /// @notice With multiple balance accounts confirmed at different times, the gate should use
    ///         the oldest `lastUpdated` timestamp — the freshest one is irrelevant.
    function test_fork_stalenessUsesOldestOfMultipleAccounts() public {
        _createExecutor();
        _registerPausePreHook();

        // Confirm accountA at t0, advance past the rate-limit, then confirm accountB.
        _custodianConfirm(balanceAccountA, 100e6);
        uint256 tA = block.timestamp;
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL_S + 1);
        _custodianConfirm(balanceAccountB, 50e6);

        // Now warp so that accountA is stale but accountB is fresh.
        vm.warp(tA + STALENESS_MAX_S + 1);

        // The pre-hook must use oldest (accountA) and revert.
        vm.expectRevert(
            abi.encodeWithSelector(ExternalStateErrors.ExternalStatePreHookStale.selector, tA, block.timestamp, STALENESS_MAX_S)
        );
        vm.prank(user);
        vault.deposit(1e6, user);
    }

    // ============================================================
    // Helpers
    // ============================================================

    /// @dev Fund `user` with USDC and deposit into the real vault (goes through the pre-hook).
    function _userDeposit(uint256 amount_) internal {
        deal(USDC, user, amount_);
        vm.startPrank(user);
        IERC20(USDC).approve(address(vault), amount_);
        vault.deposit(amount_, user);
        vm.stopPrank();
    }
}
