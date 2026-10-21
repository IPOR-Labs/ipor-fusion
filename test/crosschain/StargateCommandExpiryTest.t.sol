// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {
    CommandStatus,
    CrosschainConstants,
    ResolveOutcome
} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";

/// @title StargateCommandExpiryTest
/// @notice IL-8255 (R-05), Stargate half: a COMMAND / UPDATE_VAULTS packet LayerZero retained across an
///         `ABANDON_COMMAND_*` rescue used to stay executable. Once the lane reached its sequence — the very
///         sequence a replacement reuses after an UNUSED abandon, or a sequence ahead of the lane after a
///         realign down — anyone could execute it, run the abandoned business action, and have its ACK
///         supersede the live replacement on the executor. Command ids now carry a deadline: the dispatcher
///         NACKs expired work without moving its sequence, and the abandon is refused until the command has
///         expired on both chains.
/// @dev Two-sided against a REAL dispatcher with hand-relayed payloads (`StargateTwoSidedBase`), so a
///      retained packet is a genuinely produced message that is genuinely not delivered until later.
contract StargateCommandExpiryTest is StargateTwoSidedBase {
    event CommandFailed(bytes32 commandId, uint64 sequence);

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

    function _realign(uint64 epoch_, uint64 sequence_) internal {
        // IL-8652 packing, armed against the executor's current mirrors.
        bytes32 id = bytes32(
            (REMOTE_CHAIN << 192) | (uint256(executor.chainConfigEpoch(REMOTE_CHAIN)) << 144)
                | (uint256(executor.nextSequenceToSend(REMOTE_CHAIN)) << 96) | (uint256(epoch_) << 48)
                | uint256(sequence_)
        );
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, ResolveOutcome.REALIGN_COMMAND_LANE);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, id, ResolveOutcome.REALIGN_COMMAND_LANE);
    }

    function _readyWithCapital() internal {
        _bringUpBothSides();
        _allowRemoteVault();
        _bridgeToDispatcher(100e6);
    }

    function _sendDeposit(uint256 amountSD_) internal returns (bytes32 commandId, uint256 packetIndex) {
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(amountSD_));
        (,,,, commandId,,) = executor.activeCommand(REMOTE_CHAIN);
        packetIndex = _lastSentIndex();
    }

    /// @dev Deliver the packet at `packetIndex_` while the dispatcher cannot fund the worst-case receipt:
    ///      it reverts before storing anything, so LayerZero retains it. Reads the packet and the fee BEFORE
    ///      arming `vm.expectRevert`, which applies to the very next external call.
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

    function _expectSequenceGapOnDelivery(uint256 packetIndex_, uint64 expected_, uint64 received_) internal {
        MockLzEndpoint.SentMessage memory m = endpoint.sentAt(packetIndex_);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.SequenceGap.selector, expected_, received_));
        endpoint.deliverLz(
            address(dispatcher), LOCAL_EID, bytes32(uint256(uint160(address(dispatcher)))), m.guid, m.message
        );
    }

    function _assertMirrorsMatchDispatcher(string memory label_) internal view {
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), dispatcher.nextCommandSequence(), label_);
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), dispatcher.commandConfigEpoch(), label_);
    }

    // ---------------------------------------------------------------------
    // E1 — the retained command at the sequence its replacement reuses
    // ---------------------------------------------------------------------

    /// @notice The finding's main path, reached without any wrong declaration: a DEPOSIT is retained by an
    ///         unfunded dispatcher, the operator abandons it — correctly — as UNUSED and sends a replacement
    ///         at the same sequence, and the retained DEPOSIT is then executed first. It must NACK: no
    ///         capital moves, the sequence stays put, and the replacement is neither superseded on the
    ///         executor nor stranded on the dispatcher.
    function testShouldNackARetainedCommandInsteadOfSupersedingItsReplacement() public {
        _readyWithCapital();
        (bytes32 abandoned, uint256 abandonedPacket) = _sendDeposit(50e6);
        _retainByStarvingBudget(abandonedPacket);
        relayCursor = endpoint.sentCount();

        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);
        uint64 sequence = dispatcher.nextCommandSequence();
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), sequence, "mirror parked on the abandoned sequence");

        (bytes32 replacement,) = _sendDeposit(10e6);
        uint256 idleBefore = dispatcher.trackedIdle();

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit CommandFailed(abandoned, sequence);
        _relayAt(abandonedPacket); // anyone may execute the retained packet — and does so first

        assertEq(uint8(dispatcher.commandStatus(abandoned)), uint8(CommandStatus.FAILED), "expired work NACKed");
        assertEq(dispatcher.nextCommandSequence(), sequence, "the sequence did not move");
        assertEq(dispatcher.trackedIdle(), idleBefore, "the abandoned 50e6 deposit did not run");
        assertEq(remoteVault.balanceOf(address(dispatcher)), 0, "no position opened by the abandoned intent");

        _relayAll(); // the replacement, then the NACK and the replacement's ACK back to the executor

        assertEq(uint8(dispatcher.commandStatus(replacement)), uint8(CommandStatus.SUCCEEDED), "replacement ran");
        assertEq(dispatcher.trackedIdle(), idleBefore - 10e6, "only the replacement's deposit moved capital");
        assertFalse(_commandSlotActive(), "the replacement's own receipt resolved it");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    // ---------------------------------------------------------------------
    // E2 — the retained command ahead of the lane (the ticket's scenario)
    // ---------------------------------------------------------------------

    /// @notice A wrong CONSUMED declaration puts the mirror ahead, so the next command is retained on
    ///         `SequenceGap`. After ABANDON + REALIGN down, a command at the lower sequence brings the lane up
    ///         to the retained packet's sequence. Executing that packet must NACK rather than run the
    ///         abandoned deposit and supersede the live command that owns the same sequence.
    function testShouldNackACommandRetainedAheadOfTheLaneAfterARealignDown() public {
        _readyWithCapital();

        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(10e6));
        relayCursor = endpoint.sentCount(); // never delivered
        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED); // the wrong declaration
        uint64 n = dispatcher.nextCommandSequence();

        (bytes32 ahead, uint256 aheadPacket) = _sendDeposit(50e6); // stamped n + 1
        relayCursor = endpoint.sentCount();
        _expectSequenceGapOnDelivery(aheadPacket, n, n + 1);

        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);
        _realign(dispatcher.commandConfigEpoch(), n);

        (bytes32 atN,) = _sendDeposit(5e6);
        _relayAll();
        assertEq(uint8(dispatcher.commandStatus(atN)), uint8(CommandStatus.SUCCEEDED), "command at n ran");
        assertEq(dispatcher.nextCommandSequence(), n + 1, "the lane reached the retained packet's sequence");

        (bytes32 live,) = _sendDeposit(7e6); // the live command at n + 1, not delivered yet
        uint256 idleBefore = dispatcher.trackedIdle();

        _relayAt(aheadPacket);

        assertEq(uint8(dispatcher.commandStatus(ahead)), uint8(CommandStatus.FAILED), "expired work NACKed");
        assertEq(dispatcher.trackedIdle(), idleBefore, "the abandoned 50e6 deposit did not run");
        assertEq(dispatcher.nextCommandSequence(), n + 1, "the sequence did not move");

        _relayAll();
        assertEq(uint8(dispatcher.commandStatus(live)), uint8(CommandStatus.SUCCEEDED), "the live command ran");
        assertEq(dispatcher.trackedIdle(), idleBefore - 7e6, "and only it moved capital");
        assertFalse(_commandSlotActive(), "resolved by its own receipt, not superseded");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    // ---------------------------------------------------------------------
    // E3 — a retained UPDATE_VAULTS
    // ---------------------------------------------------------------------

    /// @notice An UPDATE_VAULTS retained across an abandon must not rewrite the allowlist either. This is also
    ///         why the interim runbook "send UPDATE_VAULTS first after an abandon" was not sufficient: the
    ///         retained config update itself competes for the reused sequence and its `epoch + 1`.
    function testShouldNackARetainedUpdateVaultsInsteadOfApplyingTheAbandonedAllowlist() public {
        _bringUpBothSides();
        address[] memory allow = new address[](1);
        allow[0] = address(remoteVault);
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, allow);
        bytes32 abandoned = _activeCommandId();
        uint256 abandonedPacket = _lastSentIndex();
        _retainByStarvingBudget(abandonedPacket);
        relayCursor = endpoint.sentCount();

        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);

        // The operator changed their mind: the replacement keeps the allowlist empty.
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, new address[](0));
        bytes32 replacement = _activeCommandId();
        uint64 epochBefore = dispatcher.commandConfigEpoch();

        _relayAt(abandonedPacket);

        assertEq(uint8(dispatcher.commandStatus(abandoned)), uint8(CommandStatus.FAILED), "expired update NACKed");
        assertFalse(dispatcher.isAllowedVault(address(remoteVault)), "the abandoned allowlist was not applied");
        assertEq(dispatcher.commandConfigEpoch(), epochBefore, "the epoch did not move");

        _relayAll();
        assertEq(uint8(dispatcher.commandStatus(replacement)), uint8(CommandStatus.SUCCEEDED), "replacement ran");
        assertFalse(dispatcher.isAllowedVault(address(remoteVault)), "the replacement's allowlist holds");
        assertFalse(_commandSlotActive(), "resolved by its own receipt");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    // ---------------------------------------------------------------------
    // E4 — the TTL on the live lane
    // ---------------------------------------------------------------------

    /// @notice The deadline is stamped at build time for both sequenced message types.
    function testShouldStampTheDeadlineIntoEveryCommandId() public {
        _bringUpBothSides();
        uint256 builtAt = block.timestamp;
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, new address[](0));
        assertEq(
            CrosschainMessages.commandDeadline(_activeCommandId()),
            builtAt + CrosschainConstants.COMMAND_TTL,
            "UPDATE_VAULTS deadline"
        );
        _relayAll();

        vm.warp(block.timestamp + 5 hours);
        (bytes32 commandId,) = _sendDeposit(1e6);
        assertEq(
            CrosschainMessages.commandDeadline(commandId),
            block.timestamp + CrosschainConstants.COMMAND_TTL,
            "COMMAND deadline"
        );
    }

    /// @notice The deadline itself is still inside the window (`block.timestamp > deadline` expires).
    function testShouldExecuteACommandDeliveredExactlyAtItsDeadline() public {
        _readyWithCapital();
        (bytes32 commandId,) = _sendDeposit(10e6);
        vm.warp(CrosschainMessages.commandDeadline(commandId));
        _relayAll();
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "ran at the deadline");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    /// @notice A live command delivered after its deadline is NACKed like any business failure; a retry
    ///         cannot revive it (the executor refuses to send one), and the manager's CANCEL is answered with an `EXPIRED` receipt that
    ///         frees the lane without consuming the sequence (IL-8594): the next command reuses it.
    function testShouldNackALateCommandAndLetTheOperatorCancelIt() public {
        _readyWithCapital();
        (bytes32 commandId,) = _sendDeposit(10e6);
        uint256 idleBefore = dispatcher.trackedIdle();
        uint64 sequence = dispatcher.nextCommandSequence();

        vm.warp(CrosschainMessages.commandDeadline(commandId) + 1);
        _relayAll();
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "late command NACKed");
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED), "the executor saw the NACK");
        assertEq(dispatcher.nextCommandSequence(), sequence, "the sequence did not move");

        // IL-8625: a retry cannot revive it either, and the executor refuses to send one (it could only NACK again).
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandExpired.selector, commandId));
        executor.retryCommand(REMOTE_CHAIN);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "still FAILED");
        assertEq(dispatcher.trackedIdle(), idleBefore, "nothing ran");

        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayAll();
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.CANCELLED), "closed");
        assertEq(dispatcher.nextCommandSequence(), sequence, "the expired cancel did not move the lane");
        assertFalse(_commandSlotActive(), "slot freed by the EXPIRED receipt");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    // ---------------------------------------------------------------------
    // E5 — the abandon waits for the deadline on both chains
    // ---------------------------------------------------------------------

    /// @notice Both declarations are refused up to and including `deadline + COMMAND_EXPIRY_MARGIN` and
    ///         accepted one second later. The rescue is scheduled before the command exists so the timelock
    ///         alone cannot carry the execution past the deadline.
    function testShouldRejectAnAbandonUntilTheCommandExpiredOnBothChains() public {
        _readyWithCapital();
        bytes32 id = bytes32(REMOTE_CHAIN);
        vm.startPrank(admin);
        uint256 unusedRescue = executor.scheduleForceResolveTransfer(id, ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);
        uint256 consumedRescue =
            executor.scheduleForceResolveTransfer(id, ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);
        vm.stopPrank();
        vm.warp(block.timestamp + RESCUE_DELAY);

        (bytes32 commandId,) = _sendDeposit(10e6);
        relayCursor = endpoint.sentCount(); // stuck in flight
        uint256 abandonableAt =
            CrosschainMessages.commandDeadline(commandId) + CrosschainConstants.COMMAND_EXPIRY_MARGIN;
        bytes memory notExpired =
            abi.encodeWithSelector(CrosschainErrors.CommandNotExpired.selector, commandId, abandonableAt);

        vm.prank(admin);
        vm.expectRevert(notExpired);
        executor.executeForceResolveTransfer(unusedRescue, id, ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);

        vm.warp(abandonableAt);
        vm.prank(admin);
        vm.expectRevert(notExpired);
        executor.executeForceResolveTransfer(consumedRescue, id, ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);
        vm.prank(admin);
        vm.expectRevert(notExpired);
        executor.executeForceResolveTransfer(unusedRescue, id, ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);
        assertTrue(_commandSlotActive(), "the slot is still held");

        vm.warp(abandonableAt + 1);
        vm.prank(admin);
        executor.executeForceResolveTransfer(unusedRescue, id, ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);
        assertFalse(_commandSlotActive(), "abandoned once expired on both chains");
    }
}
