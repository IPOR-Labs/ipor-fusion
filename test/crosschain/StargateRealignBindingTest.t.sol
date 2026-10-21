// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {StargateCommandLaneRealignTest} from "./StargateCommandLaneRealignTest.t.sol";

/// @title StargateRealignBindingTest
/// @notice IL-8652 (twin of CCIP IL-8586): `REALIGN_COMMAND_LANE` is bound to the mirrors it was armed against, so
///         an authenticated ACK that advances the lane during the timelock makes the stale rescue revert
///         `RealignStateMoved` instead of rolling the sequence backwards.
/// @dev Reuses the two-sided fixture (real dispatcher, hand-relayed payloads) of `StargateCommandLaneRealignTest`
///      by inheriting it; the inherited tests are simply re-run under this contract name.
contract StargateRealignBindingTest is StargateCommandLaneRealignTest {
    /// @dev Executor behind the dispatcher by one: the deposit ran remotely, its ACK is stuck unrelayed and the
    ///      operator abandoned the command without consuming the sequence.
    function _executorBehindWithQueuedAck() internal returns (uint256 ackIndex) {
        _readyWithCapital();
        (, ackIndex) = _commandWithUndeliveredAck();
        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN) + 1, dispatcher.nextCommandSequence(), "executor behind");
    }

    function _schedule(bytes32 id_) internal returns (uint256 rescueId) {
        vm.prank(admin);
        rescueId = executor.scheduleForceResolveTransfer(id_, ResolveOutcome.REALIGN_COMMAND_LANE);
    }

    function _execute(uint256 rescueId_, bytes32 id_) internal {
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId_, id_, ResolveOutcome.REALIGN_COMMAND_LANE);
    }

    /// @notice The finding: the rescue snapshot (sequence S) is armed, then the late ACK moves the mirror to S + 1.
    ///         Without the binding the rescue would write S back over the newer sequence.
    function testShouldRevertRealignWhenAckAdvancedTheLaneDuringDelay() public {
        uint256 ackIndex = _executorBehindWithQueuedAck();
        uint64 epoch = executor.chainConfigEpoch(REMOTE_CHAIN);
        uint64 staleSequence = executor.nextSequenceToSend(REMOTE_CHAIN);
        bytes32 id = _realignId(REMOTE_CHAIN, epoch, staleSequence); // armed against (epoch, staleSequence)

        uint256 rescueId = _schedule(id);
        _relayAt(ackIndex); // the late ACK lands during the delay and advances the mirror
        uint64 advanced = executor.nextSequenceToSend(REMOTE_CHAIN);
        assertEq(advanced, staleSequence + 1, "the ACK advanced the sequence mirror");
        assertFalse(_commandSlotActive(), "and the slot is free, so the old check passes");

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RealignStateMoved.selector,
                REMOTE_CHAIN,
                staleSequence,
                advanced,
                epoch,
                epoch
            )
        );
        _execute(rescueId, id);

        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), advanced, "the lane was not rolled backwards");
    }

    function testShouldRealignWhenStateUnchangedDuringDelay() public {
        _executorBehindWithQueuedAck();
        uint64 epoch = executor.chainConfigEpoch(REMOTE_CHAIN);
        uint64 sequence = executor.nextSequenceToSend(REMOTE_CHAIN);
        bytes32 id = _realignIdFrom(REMOTE_CHAIN, epoch, sequence, epoch + 2, sequence + 5);

        uint256 rescueId = _schedule(id);
        vm.warp(block.timestamp + RESCUE_DELAY);
        _execute(rescueId, id);

        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), sequence + 5, "sequence realigned");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), epoch + 2, "epoch realigned");
    }

    function testShouldRescheduleRealignFromNewStateAfterRevert() public {
        uint256 ackIndex = _executorBehindWithQueuedAck();
        uint64 epoch = executor.chainConfigEpoch(REMOTE_CHAIN);
        bytes32 stale = _realignId(REMOTE_CHAIN, epoch, executor.nextSequenceToSend(REMOTE_CHAIN));
        uint256 staleId = _schedule(stale);
        _relayAt(ackIndex);
        vm.warp(block.timestamp + RESCUE_DELAY);
        uint64 advanced = executor.nextSequenceToSend(REMOTE_CHAIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RealignStateMoved.selector,
                REMOTE_CHAIN,
                advanced - 1,
                advanced,
                epoch,
                epoch
            )
        );
        _execute(staleId, stale);

        // Reschedule from the new state: expected pair = what the ACK left behind.
        bytes32 fresh = _realignId(REMOTE_CHAIN, epoch, advanced + 3);
        uint256 freshId = _schedule(fresh);
        vm.warp(block.timestamp + RESCUE_DELAY);
        _execute(freshId, fresh);

        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), advanced + 3, "realigned from the new state");
    }

    function testShouldRealignAfterConsumedAbandonInSameBatch() public {
        _readyWithCapital();
        _commandWithUndeliveredAck();
        uint64 epoch = executor.chainConfigEpoch(REMOTE_CHAIN);
        uint64 sequence = executor.nextSequenceToSend(REMOTE_CHAIN);
        _abandonThenRealign(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED, epoch + 1, sequence + 4);

        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), sequence + 4, "sequence realigned after abandon");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), epoch + 1, "epoch realigned after abandon");
    }

    function testShouldRevertRealignWhenConsumedAbandonPlusOneIsOmitted() public {
        _readyWithCapital();
        _commandWithUndeliveredAck();
        uint64 epoch = executor.chainConfigEpoch(REMOTE_CHAIN);
        uint64 sequence = executor.nextSequenceToSend(REMOTE_CHAIN);
        // Admin passes the pre-abandon sequence: the consumed abandon moves the mirror to sequence + 1 first.
        bytes32 abandonId = bytes32(REMOTE_CHAIN);
        bytes32 realignId = _realignIdFrom(REMOTE_CHAIN, epoch, sequence, epoch, sequence + 4);
        vm.startPrank(admin);
        uint256 abandonRescue = executor.scheduleForceResolveTransfer(
            abandonId,
            ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED
        );
        uint256 realignRescue = executor.scheduleForceResolveTransfer(realignId, ResolveOutcome.REALIGN_COMMAND_LANE);
        vm.stopPrank();
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.startPrank(admin);
        executor.executeForceResolveTransfer(
            abandonRescue,
            abandonId,
            ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RealignStateMoved.selector,
                REMOTE_CHAIN,
                sequence,
                sequence + 1,
                epoch,
                epoch
            )
        );
        executor.executeForceResolveTransfer(realignRescue, realignId, ResolveOutcome.REALIGN_COMMAND_LANE);
        vm.stopPrank();
    }

    /// @dev Case (b): the first UPDATE_VAULTS was never delivered and the admin wrongly abandons it as CONSUMED.
    ///      The mirror is (sequence 1, epoch 0) while the dispatcher is still (0, 0); only a realign can lower it.
    function testShouldRealignFromAZeroEpochMirrorAfterAWrongConsumedAbandon() public {
        _registerRemote();
        address[] memory empty = new address[](0);
        vm.prank(manager);
        executor.createDispatcher(REMOTE_CHAIN, empty);
        factory.ackDispatcher(address(executor), 1, REMOTE_CHAIN);
        // The auto-sent initial UPDATE_VAULTS is NOT delivered.
        assertEq(dispatcher.nextCommandSequence(), 0, "dispatcher never ran it");
        assertEq(dispatcher.commandConfigEpoch(), 0, "dispatcher epoch untouched");

        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), 1, "mirror sequence raised by the wrong abandon");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 0, "epoch mirror still zero");

        bytes32 id = _realignIdFrom(
            REMOTE_CHAIN, 0, 1, dispatcher.commandConfigEpoch(), dispatcher.nextCommandSequence()
        );
        uint256 rescueId = _schedule(id); // a zero expected epoch is accepted
        vm.warp(block.timestamp + RESCUE_DELAY);
        _execute(rescueId, id);

        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), 0, "sequence mirror realigned to 0");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 0, "epoch mirror realigned to 0");

        // The lane works again: a fresh UPDATE_VAULTS is sent, run by the dispatcher and ACKed.
        address[] memory vaults = new address[](1);
        vaults[0] = address(remoteVault);
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, vaults);
        _relayAll();
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 1, "executor epoch advanced");
        assertEq(dispatcher.commandConfigEpoch(), 1, "dispatcher epoch advanced");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), dispatcher.nextCommandSequence(), "lanes aligned");
        assertFalse(_commandSlotActive(), "slot free");
    }

    /// @dev Case (a): the first UPDATE_VAULTS ran remotely but its receipt was lost and the admin abandons it as
    ///      UNUSED. The mirror is (0, 0) while the dispatcher is (1, 1).
    function testShouldRealignFromAZeroEpochMirrorAfterALostFirstReceipt() public {
        _registerRemote();
        address[] memory empty = new address[](0);
        vm.prank(manager);
        executor.createDispatcher(REMOTE_CHAIN, empty);
        factory.ackDispatcher(address(executor), 1, REMOTE_CHAIN);
        _relayAt(_lastSentIndex()); // the dispatcher runs it; its receipt is never relayed
        relayCursor = endpoint.sentCount();
        assertEq(dispatcher.commandConfigEpoch(), 1, "dispatcher ran it");

        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), 0, "mirror sequence zero");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 0, "epoch mirror zero");

        bytes32 id = _realignIdFrom(
            REMOTE_CHAIN, 0, 0, dispatcher.commandConfigEpoch(), dispatcher.nextCommandSequence()
        );
        uint256 rescueId = _schedule(id);
        vm.warp(block.timestamp + RESCUE_DELAY);
        _execute(rescueId, id);

        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), 1, "sequence mirror realigned");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 1, "epoch mirror realigned");
        _assertMirrorsMatchDispatcher("after realign from zero epoch");
    }

    function testShouldRefuseRealignScheduleForPreBindingChainIdPacking() public {
        _executorBehindWithQueuedAck();
        // Old layout: chain id at bit 128 decodes to chain 0 under the new one.
        bytes32 legacy = bytes32((REMOTE_CHAIN << 128) | (uint256(1) << 64) | uint256(3));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DispatcherNotReady.selector, uint256(0)));
        executor.scheduleForceResolveTransfer(legacy, ResolveOutcome.REALIGN_COMMAND_LANE);
    }
}
