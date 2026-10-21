// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {CommandStatus, ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";

/// @title StaleCommandResolutionTest
/// @notice Regression cover for IL-7979: `_onRetryCommand` / `_onCancelCommand` used to act on any FAILED
///         record and advance `nextCommandSequence` without checking that the record still owns the lane's next
///         sequence. A RETRY / CANCEL packet retained by LayerZero (e.g. an under-funded dispatcher) can
///         outlive an `ABANDON_COMMAND_SEQUENCE_UNUSED` rescue followed by a replacement command that
///         resolves at the same sequence — after which the retained packet is stale: acting on it would
///         advance `nextCommandSequence` a second time (a permanent `SequenceGap` on every later command) and, for
///         a retry, re-execute a command the operator had already abandoned.
/// @dev Drives a REAL executor against a REAL dispatcher with hand-relayed payloads
///      (`StargateTwoSidedBase`), exactly like `CommandCancelRetryRaceTest` / `StuckCommandRecoveryTest`, so
///      the retained packet is modelled by genuinely not delivering a genuinely-produced message until
///      after the replacement has resolved.
contract StaleCommandResolutionTest is StargateTwoSidedBase {
    function setUp() public {
        _twoSidedSetUp();
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _abandon(ResolveOutcome outcome_) internal {
        bytes32 id = bytes32(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, outcome_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, id, outcome_);
    }

    /// @dev Bring both sides up and allowlist the remote vault (both epochs -> 2), WITHOUT bridging
    ///      capital yet, so a DEPOSIT command fails on the dispatcher for a transient reason (ZeroAmount:
    ///      trackedIdle == 0) rather than a permanent one (e.g. a config-epoch mismatch, which would make a
    ///      stale retry NACK instead of exercising the fixed path).
    function _readyWithoutCapital() internal {
        _bringUpBothSides();
        _allowRemoteVault();
    }

    /// @dev Send a DEPOSIT that the dispatcher fails (no tracked idle), leaving a FAILED record with
    ///      sequence `S` on both sides. Returns the command id and its sequence.
    function _failedDeposit(uint256 amountSD_) internal returns (bytes32 commandId, uint64 sequence) {
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(amountSD_));
        (,,,, commandId, sequence,) = executor.activeCommand(REMOTE_CHAIN);

        _relayAll(); // executor -> dispatcher : COMMAND (ZeroAmount, NACK queued) -> executor : NACK

        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "failed on the dispatcher");
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED), "failed on the executor");
    }

    /// @dev Deliver the message at `packetIndex_` while the dispatcher cannot fund the worst-case receipt,
    ///      proving it reverts (retained by LayerZero) rather than being consumed. Restores the dispatcher's
    ///      balance to its prior 100 ether afterwards so the rest of the test proceeds normally.
    ///      MUST read `endpoint.sentAt` and `endpoint.messagingFee` BEFORE `vm.expectRevert`: it applies
    ///      only to the very next external call, and both are external view calls on the endpoint.
    function _retainByStarvingBudget(uint256 packetIndex_) internal {
        MockLzEndpoint.SentMessage memory m = endpoint.sentAt(packetIndex_);
        uint256 fee = endpoint.messagingFee();
        vm.deal(address(dispatcher), 0);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InsufficientNativeBudget.selector, 0, fee));
        endpoint.deliverLz(
            address(dispatcher), LOCAL_EID, bytes32(uint256(uint160(address(dispatcher)))), m.guid, m.message
        );
        vm.deal(address(dispatcher), 100 ether);
    }

    event StaleCommandResolutionIgnored(bytes32 commandId, uint64 sequence, uint64 nextCommandSequence);

    // ---------------------------------------------------------------------
    // T1 — stale RETRY
    // ---------------------------------------------------------------------

    /// @notice The finding's PoC for the retry variant, end to end: a retained RETRY_COMMAND landing after
    ///         a replacement has already consumed the abandoned command's sequence must be ignored, not
    ///         acted on.
    function testShouldIgnoreAStaleRetryAfterAReplacementConsumedItsSequence() public {
        _readyWithoutCapital();
        (bytes32 c1, uint64 s1) = _failedDeposit(50e6);

        // The operator retries; the RETRY_COMMAND packet is retained (dispatcher out of native budget).
        vm.prank(manager);
        executor.retryCommand(REMOTE_CHAIN);
        uint256 packetIndex = _lastSentIndex();
        _retainByStarvingBudget(packetIndex);
        relayCursor = endpoint.sentCount();

        // The operator abandons the command as UNUSED (from their view, the dispatcher never ran it — true
        // at this moment, since the retained packet has not been consumed).
        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);

        // Capital arrives and a replacement command occupies the freed slot at the SAME sequence `s1`.
        _bridgeToDispatcher(100e6);
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(40e6));
        (,,,, bytes32 c2,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();

        assertEq(uint8(dispatcher.commandStatus(c2)), uint8(CommandStatus.SUCCEEDED), "replacement resolved");
        assertEq(
            dispatcher.nextCommandSequence(),
            executor.nextSequenceToSend(REMOTE_CHAIN),
            "sanity: both sides in lockstep before the retained packet lands"
        );
        uint256 remoteVaultBalanceBefore = remoteVault.balanceOf(address(dispatcher));

        // The retained RETRY_COMMAND for `c1` finally lands. It must be ignored: no state change, no
        // receipt, just the event.
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit StaleCommandResolutionIgnored(c1, s1, dispatcher.nextCommandSequence());
        _relayAt(packetIndex);

        assertEq(
            dispatcher.nextCommandSequence(),
            executor.nextSequenceToSend(REMOTE_CHAIN),
            "the stale retry must not advance nextCommandSequence a second time"
        );
        assertEq(uint8(dispatcher.commandStatus(c1)), uint8(CommandStatus.FAILED), "the abandoned record is untouched");
        assertEq(dispatcher.trackedIdle(), 60e6, "the abandoned 50e6 deposit must not have run");
        assertEq(
            remoteVault.balanceOf(address(dispatcher)),
            remoteVaultBalanceBefore,
            "no remote value moved by the stale packet"
        );

        // The lane is alive afterwards: a fresh command at the (unmoved) current sequence resolves normally.
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(10e6));
        (,,,, bytes32 c3,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();
        assertEq(
            uint8(dispatcher.commandStatus(c3)), uint8(CommandStatus.SUCCEEDED), "lane alive after the stale packet"
        );
    }

    // ---------------------------------------------------------------------
    // T2 — stale CANCEL
    // ---------------------------------------------------------------------

    /// @notice Same story for CANCEL_COMMAND, which — unlike a retry — closes unconditionally (no business
    ///         action, no epoch check) once it passes the status guard, so it is the more dangerous of the
    ///         two if the sequence check is missing.
    function testShouldIgnoreAStaleCancelAfterAReplacementConsumedItsSequence() public {
        _readyWithoutCapital();
        (bytes32 c1, uint64 s1) = _failedDeposit(50e6);

        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        uint256 packetIndex = _lastSentIndex();
        _retainByStarvingBudget(packetIndex);
        relayCursor = endpoint.sentCount();

        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);

        _bridgeToDispatcher(100e6);
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(40e6));
        (,,,, bytes32 c2,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();

        assertEq(uint8(dispatcher.commandStatus(c2)), uint8(CommandStatus.SUCCEEDED), "replacement resolved");
        assertEq(
            dispatcher.nextCommandSequence(),
            executor.nextSequenceToSend(REMOTE_CHAIN),
            "sanity: both sides in lockstep before the retained packet lands"
        );

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit StaleCommandResolutionIgnored(c1, s1, dispatcher.nextCommandSequence());
        _relayAt(packetIndex);

        assertEq(
            dispatcher.nextCommandSequence(),
            executor.nextSequenceToSend(REMOTE_CHAIN),
            "the stale cancel must not advance nextCommandSequence a second time"
        );
        assertEq(
            uint8(dispatcher.commandStatus(c1)),
            uint8(CommandStatus.FAILED),
            "the abandoned record is untouched, not CANCELLED"
        );

        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(10e6));
        (,,,, bytes32 c3,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();
        assertEq(
            uint8(dispatcher.commandStatus(c3)), uint8(CommandStatus.SUCCEEDED), "lane alive after the stale packet"
        );
    }

    // ---------------------------------------------------------------------
    // T3 — the stale check runs BEFORE the receipt budget quote
    // ---------------------------------------------------------------------

    /// @notice A stale packet must be consumable even with an EMPTY native budget: the whole point of
    ///         checking staleness before `_ensureReceiptBudget` is that the ignore path sends no receipt,
    ///         so it needs no budget. Proves the ordering, not just the outcome.
    function testShouldConsumeAStaleRetryWithoutAReceiptBudget() public {
        _readyWithoutCapital();
        (bytes32 c1, uint64 s1) = _failedDeposit(50e6);

        vm.prank(manager);
        executor.retryCommand(REMOTE_CHAIN);
        uint256 packetIndex = _lastSentIndex();
        _retainByStarvingBudget(packetIndex);
        relayCursor = endpoint.sentCount();

        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);
        _bridgeToDispatcher(100e6);
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(40e6));
        _relayAll();

        MockLzEndpoint.SentMessage memory m = endpoint.sentAt(packetIndex);
        vm.deal(address(dispatcher), 0); // empty native budget: a receipt would be unfundable
        bool ok;
        try this._deliverStaleRetry(m.guid, m.message) {
            ok = true;
        } catch {
            ok = false;
        }

        assertTrue(ok, "a stale packet must be consumable with zero native balance (no receipt needed)");
        assertEq(
            dispatcher.nextCommandSequence(),
            executor.nextSequenceToSend(REMOTE_CHAIN),
            "counters stay in lockstep: the stale packet was ignored, not acted on"
        );
        assertEq(uint8(dispatcher.commandStatus(c1)), uint8(CommandStatus.FAILED), "abandoned record untouched");
    }

    // ---------------------------------------------------------------------
    // T4 — guard: retry/cancel at the CURRENT sequence are unaffected (passes before AND after the fix;
    // NOT regression evidence — see NatSpec).
    // ---------------------------------------------------------------------

    /// @notice Guard test, not a regression test: `_ignoreIfStale` is a pass-through whenever the stored
    ///         sequence still equals `nextCommandSequence`, so every ordinary retry/cancel at the current sequence
    ///         must behave exactly as before the fix. This test passes on the unfixed contract too; it
    ///         exists to catch an over-broad guard, not to prove the fix does anything.
    function testShouldStillRetryAndCancelAtTheCurrentSequence() public {
        _readyWithoutCapital();

        // Retry at the current sequence: fund capital first so the retry actually succeeds.
        (bytes32 c1,) = _failedDeposit(50e6);
        _bridgeToDispatcher(100e6);
        vm.prank(manager);
        executor.retryCommand(REMOTE_CHAIN);
        _relayAll();

        assertEq(
            uint8(dispatcher.commandStatus(c1)),
            uint8(CommandStatus.SUCCEEDED),
            "retry at current sequence still succeeds"
        );
        assertEq(
            dispatcher.nextCommandSequence(),
            executor.nextSequenceToSend(REMOTE_CHAIN),
            "counters advance together"
        );

        // Cancel at the current sequence: a second command that fails, then gets cancelled.
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, _singleVault(address(0xBEEF))); // fails destination validation
        (,,,, bytes32 c2,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();
        assertEq(uint8(dispatcher.commandStatus(c2)), uint8(CommandStatus.FAILED), "config update failed");

        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayAll();

        assertEq(
            uint8(dispatcher.commandStatus(c2)),
            uint8(CommandStatus.CANCELLED),
            "cancel at current sequence still resolves"
        );
        assertEq(
            dispatcher.nextCommandSequence(),
            executor.nextSequenceToSend(REMOTE_CHAIN),
            "counters advance together"
        );
    }

    function _singleVault(address v_) internal pure returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = v_;
    }

    /// @dev `external` so `try this._deliverStaleRetry(...)` can catch the `InsufficientNativeBudget`
    ///      revert without letting it bubble out of the test.
    function _deliverStaleRetry(bytes32 guid_, bytes calldata message_) external {
        endpoint.deliverLz(
            address(dispatcher), LOCAL_EID, bytes32(uint256(uint160(address(dispatcher)))), guid_, message_
        );
    }
}
