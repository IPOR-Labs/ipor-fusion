// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {CommandStatus, ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

/// @title StuckCommandRecoveryTest
/// @notice Regression cover for `no_recovery_path_for_stuck_pending_command_bricks_command_lane`.
/// @dev The executor holds exactly ONE command slot per chain and, before the fix, every way out of it
///      needed a receipt that might never arrive: `sendCommandToDispatcher`/`updatePlasmaVaults` refuse
///      while the slot is occupied, `retryCommand`/`cancelCommand` require the NACK-driven FAILED state,
///      and the only `delete self.activeCommand[...]` lived in the ACK handler. Nothing in the rescue
///      surface touched the slot.
///
///      What makes this reachable rather than theoretical is a receipt that is permanently lost (or
///      permanently unexecutable): the chain's whole business-command lane, including the REDEEM path
///      back out of the remote ERC-4626 vaults, then stays dead on non-upgradeable contracts. (Before
///      IL-8257 the documented `ADVANCE_STATE_FRONTIER` repair for a lost message made this certain by
///      classifying a late receipt as a duplicate; a receipt now carries no frontier version, so that
///      repair can no longer swallow one.)
///
///      Tests use a REAL executor against a REAL dispatcher with hand-relayed payloads, so "the receipt
///      never arrives" is modelled by genuinely not delivering a genuinely-produced message.
contract StuckCommandRecoveryTest is StargateTwoSidedBase {
    function setUp() public {
        _twoSidedSetUp();
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Bring both sides up, allowlist the remote vault and fund the dispatcher with 100 USDC of
    ///      tracked idle, so a DEPOSIT command has something real to deploy.
    function _readyWithCapital() internal {
        _bringUpBothSides();
        _allowRemoteVault(); // epochs -> 2
        _bridgeToDispatcher(100e6);
    }

    /// @dev Send a DEPOSIT, run it through the REAL dispatcher, and leave its ACK sitting undelivered.
    ///      Returns the command id and the index of the queued ACK.
    function _commandWithUndeliveredAck() internal returns (bytes32 commandId, uint256 ackIndex) {
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(50e6));
        (,,,, commandId,,) = executor.activeCommand(REMOTE_CHAIN);

        _relayAt(_lastSentIndex()); // executor -> dispatcher : COMMAND (applied, ACK queued)
        ackIndex = _lastSentIndex();
        relayCursor = endpoint.sentCount();

        assertEq(
            uint8(dispatcher.commandStatus(commandId)),
            uint8(CommandStatus.SUCCEEDED),
            "dispatcher really ran the command"
        );
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.PENDING), "executor still waiting on the receipt");
    }

    function _abandon(ResolveOutcome outcome_) internal {
        bytes32 id = bytes32(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, outcome_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, id, outcome_);
    }

    /// @dev Assert that every ordinary exit from the command slot is refused — i.e. the lane is bricked.
    function _assertLaneBricked() internal {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandNotFailed.selector, REMOTE_CHAIN));
        executor.retryCommand(REMOTE_CHAIN);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandNotFailed.selector, REMOTE_CHAIN));
        executor.cancelCommand(REMOTE_CHAIN);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ActiveCommandExists.selector, REMOTE_CHAIN));
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(10e6));

        address[] memory vaults = new address[](1);
        vaults[0] = address(remoteVault);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ActiveCommandExists.selector, REMOTE_CHAIN));
        executor.updatePlasmaVaults(REMOTE_CHAIN, vaults);
    }

    // ---------------------------------------------------------------------
    // The regression itself
    // ---------------------------------------------------------------------

    /// @notice The finding's PoC, end to end: a command whose receipt is lost used to leave the slot PENDING
    ///         forever. The rescue must free it and the lane must go back to carrying real commands
    ///         afterwards.
    function testShouldRecoverTheCommandLaneAfterAReceiptIsPermanentlyLost() public {
        _readyWithCapital();
        (bytes32 commandId,) = _commandWithUndeliveredAck();

        // The receipt is permanently lost: it is never delivered.
        assertTrue(_commandSlotActive(), "the lost receipt could not free the slot");
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.PENDING), "and it is stuck PENDING");
        _assertLaneBricked();

        // The timelocked rescue is the terminal exit. The dispatcher DID resolve this command, so its
        // sequence advanced and the mirror must follow.
        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);

        assertFalse(_commandSlotActive(), "rescue freed the command slot");

        // The real test of recovery: a fresh command must be accepted by the REAL dispatcher, which
        // validates both the sequence and the config epoch the executor stamps.
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(25e6));
        (,,,, bytes32 nextId,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();

        assertEq(
            uint8(dispatcher.commandStatus(nextId)),
            uint8(CommandStatus.SUCCEEDED),
            "dispatcher accepted the post-rescue command"
        );
        assertFalse(_commandSlotActive(), "and its receipt resolved the slot normally");
        assertGt(remoteVault.balanceOf(address(dispatcher)), 0, "capital is deployable again");
        assertTrue(commandId != nextId, "sanity: a genuinely new command");
    }

    /// @notice Freeing the slot must not strand the version frontier. The abandoned command's receipt can
    ///         still be delivered afterwards. A command receipt is value-neutral (IL-8257): it carries the
    ///         current version as evidence only, so the late receipt must leave the frontier exactly where
    ///         it was, and the NEXT versioned message on the lane must still apply with no gap.
    function testShouldNotMoveTheFrontierOnAnAbandonedCommandsLateReceipt() public {
        _readyWithCapital();
        (, uint256 ackIndex) = _commandWithUndeliveredAck();

        uint64 frontierBefore = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);

        // The receipt turns up after all (an LZ retry that finally executes).
        _relayAt(ackIndex);
        relayCursor = endpoint.sentCount();

        assertEq(
            executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN),
            frontierBefore,
            "a late command receipt is value-neutral: the frontier does not move"
        );

        // Proof that it matters: the NEXT message on the lane must still apply.
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(25e6));
        (,,,, bytes32 nextId,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();

        assertEq(
            uint8(dispatcher.commandStatus(nextId)), uint8(CommandStatus.SUCCEEDED), "dispatcher ran the next command"
        );
        assertFalse(_commandSlotActive(), "its receipt applied: the frontier was never stranded");
    }

    /// @notice A late receipt must not resolve a REPLACEMENT command. It names the abandoned command, so
    ///         it must leave the new slot alone.
    function testShouldNotLetAnAbandonedCommandsReceiptResolveItsReplacement() public {
        _readyWithCapital();
        (bytes32 abandonedId, uint256 ackIndex) = _commandWithUndeliveredAck();

        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);

        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(25e6));
        (,,,, bytes32 replacementId,,) = executor.activeCommand(REMOTE_CHAIN);

        // The stale receipt lands before the replacement's own receipt does.
        _relayAt(ackIndex);

        assertTrue(_commandSlotActive(), "the replacement is still outstanding");
        (,,,, bytes32 slotId,,) = executor.activeCommand(REMOTE_CHAIN);
        assertEq(slotId, replacementId, "the stale receipt did not resolve the replacement");
        assertTrue(abandonedId != replacementId, "sanity: distinct commands");
    }

    /// @notice The dispatcher advances its sequence on BOTH a success and a cancel, so the mirror must
    ///         follow when the command was resolved — the real dispatcher rejects anything else.
    function testShouldKeepTheSequenceInLockstepWhenTheDispatcherConsumedTheCommand() public {
        _readyWithCapital();
        uint64 sequenceBefore = executor.nextSequenceToSend(REMOTE_CHAIN);
        _commandWithUndeliveredAck();

        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);

        assertEq(
            executor.nextSequenceToSend(REMOTE_CHAIN), sequenceBefore + 1, "mirror followed the dispatcher's advance"
        );
    }

    /// @notice The other declaration: a command the dispatcher never received leaves its sequence
    ///         untouched, so the executor must reuse it. Verified against the real dispatcher, which
    ///         NACKs a command whose sequence does not match what it expects next.
    function testShouldReuseTheSequenceWhenTheDispatcherNeverReceivedTheCommand() public {
        _readyWithCapital();
        uint64 sequenceBefore = executor.nextSequenceToSend(REMOTE_CHAIN);

        // Send a command and never deliver it — the dispatcher's sequence is untouched.
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(50e6));
        relayCursor = endpoint.sentCount(); // drop the COMMAND on the floor
        assertTrue(_commandSlotActive(), "slot occupied by a command that will never be answered");

        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), sequenceBefore, "sequence reused, not skipped");

        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(50e6));
        (,,,, bytes32 nextId,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();

        assertEq(
            uint8(dispatcher.commandStatus(nextId)),
            uint8(CommandStatus.SUCCEEDED),
            "dispatcher accepted the reused sequence"
        );
        assertFalse(_commandSlotActive(), "lane alive");
    }

    /// @notice The rescue is a terminal exit, not a manager tool: timelocked and admin-only.
    function testShouldTimelockAndGateTheAbandonRescue() public {
        _readyWithCapital();
        _commandWithUndeliveredAck();
        bytes32 id = bytes32(REMOTE_CHAIN);

        vm.prank(manager);
        vm.expectRevert();
        executor.scheduleForceResolveTransfer(id, ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);

        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);

        vm.prank(admin);
        vm.expectRevert();
        executor.executeForceResolveTransfer(rescueId, id, ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);

        assertTrue(_commandSlotActive(), "slot untouched before the delay elapses");

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, id, ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);
        assertFalse(_commandSlotActive(), "freed after the delay");
    }

    /// @notice Nothing to abandon when the slot is free — the rescue must not silently advance a sequence.
    function testShouldRejectAbandonWhenTheCommandSlotIsFree() public {
        _readyWithCapital();
        bytes32 id = bytes32(REMOTE_CHAIN);

        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);
        vm.warp(block.timestamp + RESCUE_DELAY);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NoStuckCommand.selector, REMOTE_CHAIN));
        executor.executeForceResolveTransfer(rescueId, id, ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);
    }

    /// @notice The ordinary lifecycle must be untouched: a normally-ACKed command still frees its own slot
    ///         and advances the sequence exactly once, with no rescue involved.
    function testShouldResolveCommandsNormallyWithoutAnyRescue() public {
        _readyWithCapital();
        uint64 sequenceBefore = executor.nextSequenceToSend(REMOTE_CHAIN);

        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(50e6));
        (,,,, bytes32 commandId,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();

        assertFalse(_commandSlotActive(), "slot freed by the receipt");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), sequenceBefore + 1, "sequence advanced exactly once");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "command succeeded");
        assertGt(remoteVault.balanceOf(address(dispatcher)), 0, "capital deployed");
    }
}
