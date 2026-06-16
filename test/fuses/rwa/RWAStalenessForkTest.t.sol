// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {RWAForkTestBase} from "./RWAForkTestBase.t.sol";
import {RWAErrors} from "../../../contracts/fuses/rwa/errors/RWAErrors.sol";

/// @title RWAStalenessForkTest
/// @notice Fork coverage for the staleness pre-hook gate: once a balance account has been
///         updated and then goes longer than `stalenessMax` without a refresh, user-facing
///         operations revert; a fresh custodian confirm clears the gate.
contract RWAStalenessForkTest is RWAForkTestBase {
    function test_fork_stalenessBlocksDepositAfterThreshold() public {
        _createExecutor();

        // Confirm one account so oldest > 0.
        _custodianConfirm(balanceAccountA, 100e6);
        uint256 lastUpdated = block.timestamp;

        // Warp well past STALENESS_MAX_S.
        vm.warp(block.timestamp + STALENESS_MAX_S + 1);

        vm.expectRevert(
            abi.encodeWithSelector(RWAErrors.RWAPreHookStale.selector, lastUpdated, block.timestamp, STALENESS_MAX_S)
        );
        vault.delegateExecute(
            address(preHook), abi.encodeCall(preHook.run, (bytes4(keccak256("deposit(uint256,address)"))))
        );
    }

    function test_fork_stalenessClearsWhenCustodianUpdates() public {
        _createExecutor();

        _custodianConfirm(balanceAccountA, 100e6);
        vm.warp(block.timestamp + STALENESS_MAX_S + 10);

        // Confirm a fresh update (rate limiter satisfied by the warp above).
        _custodianConfirm(balanceAccountA, 110e6);

        // Pre-hook passes again.
        vault.delegateExecute(
            address(preHook), abi.encodeCall(preHook.run, (bytes4(keccak256("deposit(uint256,address)"))))
        );
    }

    /// @notice When no balance account has been confirmed yet (`oldest == 0`), the pre-hook
    ///         should NOT block even far beyond `stalenessMax` — the staleness gate only activates
    ///         after the first confirmed update.
    function test_fork_stalenessExemptWhenNoAccountHasBeenUpdated() public {
        _createExecutor();

        vm.warp(block.timestamp + STALENESS_MAX_S + 10_000);

        // No revert — oldest == 0 means "no data yet", so the gate is exempt.
        vault.delegateExecute(
            address(preHook), abi.encodeCall(preHook.run, (bytes4(keccak256("deposit(uint256,address)"))))
        );
    }

    /// @notice With multiple balance accounts confirmed at different times, the gate should use
    ///         the oldest `lastUpdated` timestamp — the freshest one is irrelevant.
    function test_fork_stalenessUsesOldestOfMultipleAccounts() public {
        _createExecutor();

        // Confirm accountA at t0, advance past the rate-limit, then confirm accountB.
        _custodianConfirm(balanceAccountA, 100e6);
        uint256 tA = block.timestamp;
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL_S + 1);
        _custodianConfirm(balanceAccountB, 50e6);

        // Now warp so that accountA is stale but accountB is fresh.
        vm.warp(tA + STALENESS_MAX_S + 1);

        // The pre-hook must use oldest (accountA) and revert.
        vm.expectRevert(
            abi.encodeWithSelector(RWAErrors.RWAPreHookStale.selector, tA, block.timestamp, STALENESS_MAX_S)
        );
        vault.delegateExecute(
            address(preHook), abi.encodeCall(preHook.run, (bytes4(keccak256("deposit(uint256,address)"))))
        );
    }
}
