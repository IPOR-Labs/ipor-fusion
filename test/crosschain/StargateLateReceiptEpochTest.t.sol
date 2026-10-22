// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {CommandStatus, ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {StargateExecutorAccountingLib} from "../../contracts/crosschain/stargate/lib/StargateExecutorAccountingLib.sol";
import {CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";

/// @title StargateLateReceiptEpochTest
/// @notice IL-8632, Stargate half, two-sided against a REAL dispatcher: a correctly declared
///         `ABANDON_COMMAND_SEQUENCE_CONSUMED` of an UPDATE_VAULTS that succeeded remotely advances the sequence
///         mirror but not the config epoch mirror. The delayed receipt for exactly `nextSequenceToSend - 1` now
///         refreshes the epoch mirror whether or not a later command owns the slot; every other late receipt stays
///         ignored.
contract StargateLateReceiptEpochTest is StargateTwoSidedBase {
    function setUp() public {
        _twoSidedSetUp();
        _bringUpBothSides();
        _allowRemoteVault();
        _bridgeToDispatcher(100e6);
    }

    function _abandonConsumed() internal {
        bytes32 id = bytes32(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, id, ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);
    }

    /// @dev UPDATE_VAULTS that the dispatcher runs while its receipt stays undelivered.
    function _updateVaultsWithUndeliveredAck() internal returns (uint256 ackIndex) {
        address[] memory vaults = new address[](1);
        vaults[0] = address(remoteVault);
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, vaults);
        _relayAt(_lastSentIndex());
        ackIndex = _lastSentIndex();
        relayCursor = endpoint.sentCount();
        assertEq(dispatcher.commandConfigEpoch(), executor.chainConfigEpoch(REMOTE_CHAIN) + 1, "dispatcher advanced");
    }

    function testShouldAdoptTheEpochOfTheReceiptOfACorrectlyAbandonedUpdateVaults() public {
        uint64 epochBefore = executor.chainConfigEpoch(REMOTE_CHAIN);
        uint64 sequence = executor.nextSequenceToSend(REMOTE_CHAIN);
        uint256 ackIndex = _updateVaultsWithUndeliveredAck();

        _abandonConsumed();
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), dispatcher.nextCommandSequence(), "sequence followed");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), epochBefore, "abandon cannot carry the epoch");

        vm.expectEmit(false, false, false, true, address(executor));
        emit StargateExecutorAccountingLib.LateReceiptEpochAdopted(
            REMOTE_CHAIN, sequence, epochBefore, epochBefore + 1
        );
        _relayAt(ackIndex);
        relayCursor = endpoint.sentCount();

        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), epochBefore + 1, "epoch mirror refreshed");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), dispatcher.commandConfigEpoch(), "matches the dispatcher");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), sequence + 1, "sequence untouched");
        assertFalse(_commandSlotActive(), "slot free");

        // Consumer: the next command is stamped with the refreshed epoch and runs.
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(40e6));
        (,,,, bytes32 fresh,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();
        assertEq(uint8(dispatcher.commandStatus(fresh)), uint8(CommandStatus.SUCCEEDED), "next command accepted");
    }

    function testShouldAdoptTheEpochWhileANewCommandOwnsTheSlot() public {
        uint64 epochBefore = executor.chainConfigEpoch(REMOTE_CHAIN);
        uint64 sequence = executor.nextSequenceToSend(REMOTE_CHAIN);
        uint256 ackIndex = _updateVaultsWithUndeliveredAck();
        _abandonConsumed();

        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(40e6));
        uint256 cmdIndex = _lastSentIndex();
        (,,,, bytes32 replacement,,) = executor.activeCommand(REMOTE_CHAIN);
        relayCursor = endpoint.sentCount(); // the replacement stays undelivered for now

        vm.expectEmit(false, false, false, true, address(executor));
        emit StargateExecutorAccountingLib.LateReceiptEpochAdopted(REMOTE_CHAIN, sequence, epochBefore, epochBefore + 1);
        _relayAt(ackIndex);

        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), epochBefore + 1, "busy slot: epoch adopted all the same");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), sequence + 1, "sequence untouched");
        (bool active,,,, bytes32 stillActive,,) = executor.activeCommand(REMOTE_CHAIN);
        assertTrue(active, "replacement untouched");
        assertEq(stillActive, replacement, "replacement untouched");

        // The replacement carries the old epoch: NACK, then CANCEL; the next command runs.
        _relayAt(cmdIndex); // dispatcher: ConfigEpochMismatch -> NACK
        _relayAt(_lastSentIndex()); // NACK -> executor
        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayAt(_lastSentIndex()); // CANCEL -> dispatcher -> CANCELLED ACK
        _relayAt(_lastSentIndex()); // ACK -> executor
        relayCursor = endpoint.sentCount();
        assertFalse(_commandSlotActive(), "slot free after cancel");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), dispatcher.commandConfigEpoch(), "epoch matches");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), dispatcher.nextCommandSequence(), "sequence matches");
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(40e6));
        (,,,, bytes32 fresh,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();
        assertEq(uint8(dispatcher.commandStatus(fresh)), uint8(CommandStatus.SUCCEEDED), "lane usable again");
    }

    function testShouldKeepTheAdoptedEpochWhenTheStaleCommandIsCancelledPastItsDeadline() public {
        uint256 ackIndex = _updateVaultsWithUndeliveredAck();
        _abandonConsumed();
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(40e6));
        uint256 cmdIndex = _lastSentIndex();
        (,,,, bytes32 stale,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAt(ackIndex); // adopted while the slot is busy
        _relayAt(cmdIndex); // NACK
        _relayAt(_lastSentIndex());
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), dispatcher.commandConfigEpoch(), "epoch adopted");

        // Cancelled only after its deadline: EXPIRED frees the slot without touching the epoch, which is
        // already right, so no second round is needed.
        vm.warp(CrosschainMessages.commandDeadline(stale) + 1);
        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayAt(_lastSentIndex()); // CANCEL -> dispatcher (expired) -> EXPIRED receipt
        _relayAt(_lastSentIndex()); // EXPIRED -> executor
        relayCursor = endpoint.sentCount();
        assertFalse(_commandSlotActive(), "EXPIRED freed the slot");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), dispatcher.commandConfigEpoch(), "epoch matches");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), dispatcher.nextCommandSequence(), "sequence matches");
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(40e6));
        (,,,, bytes32 fresh,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();
        assertEq(uint8(dispatcher.commandStatus(fresh)), uint8(CommandStatus.SUCCEEDED), "lane usable again");
    }

    function testShouldIgnoreTheLateReceiptOlderThanNextSequenceMinusOne() public {
        uint64 epochBefore = executor.chainConfigEpoch(REMOTE_CHAIN);
        uint64 sequence = executor.nextSequenceToSend(REMOTE_CHAIN);
        uint256 ackIndex = _updateVaultsWithUndeliveredAck();
        _abandonConsumed();

        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(40e6));
        relayCursor = endpoint.sentCount(); // the replacement stays undelivered
        _abandonConsumed(); // next = sequence + 2, slot free again
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), sequence + 2, "two sequences consumed");
        assertFalse(_commandSlotActive(), "slot free");

        _relayAt(ackIndex);

        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), epochBefore, "older than next - 1: epoch untouched");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), sequence + 2, "sequence untouched");
    }
}
