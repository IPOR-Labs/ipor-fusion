// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {
    CommandResolution,
    CommandStatus,
    MsgType,
    ResolveOutcome
} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainMessages, CommandAck} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";

/// @title StargateValueNeutralVersionTest
/// @notice IL-8257, Stargate half. The dispatcher `stateVersion` counts VALUE-MOVING transitions only (an
///         inbound transfer settle and a return-started). Command success, command cancel and vault-config
///         updates leave it unchanged and their `COMMAND_ACK` carries the current version as evidence only;
///         the executor's version frontier never moves on an ACK.
/// @dev Dispatcher side and the live end-to-end flows run a REAL executor against a REAL dispatcher with
///      hand-relayed payloads (`StargateTwoSidedBase`). The executor-only cases (crafted and replayed
///      receipts) use the mock-peer base.
contract StargateValueNeutralVersionDispatcherTest is StargateTwoSidedBase {
    event VaultsUpdated(uint64 commandConfigEpoch, uint64 stateVersion, uint256 count);

    function setUp() public {
        _twoSidedSetUp();
        _bringUpBothSides();
    }

    function _lastAck() internal view returns (CommandAck memory) {
        MockLzEndpoint.SentMessage memory m = endpoint.sentAt(endpoint.sentCount() - 1);
        (MsgType mt, bytes memory data) = CrosschainMessages.decodeEnvelope(m.message);
        assertEq(uint8(mt), uint8(MsgType.ACK), "last sent message is an ACK");
        return CrosschainMessages.decodeCommandAck(data);
    }

    function _assertLockstep(string memory what_) internal view {
        assertEq(
            executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN),
            dispatcher.stateVersion(),
            string.concat("lockstep: ", what_)
        );
    }

    /// @notice (a) A vault-config update changes no value: the version stays, and the event reports the
    ///         current version (it used to anticipate a bump with `stateVersion + 1`).
    function testVaultConfigUpdateLeavesVersionUnchangedAndEventReportsCurrent() public {
        assertEq(dispatcher.stateVersion(), 0, "bring-up (initial UPDATE_VAULTS) moved no value");
        _assertLockstep("after bring-up");

        address[] memory vaults = new address[](1);
        vaults[0] = address(remoteVault);
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, vaults);

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit VaultsUpdated(2, 0, 1);
        _relayAt(_lastSentIndex());

        assertEq(dispatcher.stateVersion(), 0, "config update leaves the version unchanged");
        assertEq(dispatcher.commandConfigEpoch(), 2, "but the epoch advanced");
        CommandAck memory ack = _lastAck();
        assertEq(ack.stateVersion, 0, "ACK carries the current version");

        _relayAt(_lastSentIndex());
        _assertLockstep("after the config ACK");
    }

    /// @notice (a) A successful business command leaves the version unchanged; its ACK carries the current
    ///         version (after a value-moving settle bumped it to 1), and the executor frontier stays put.
    function testCommandSuccessLeavesVersionUnchangedAndAckCarriesCurrent() public {
        _allowRemoteVault();
        _bridgeToDispatcher(100e6);
        assertEq(dispatcher.stateVersion(), 1, "the settle bumped the version once");
        _assertLockstep("after settle");

        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(60e6));
        bytes32 commandId = _activeCommandId();
        uint64 sequenceBefore = dispatcher.nextCommandSequence();
        _relayAt(_lastSentIndex());

        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "command ran");
        assertEq(dispatcher.nextCommandSequence(), sequenceBefore + 1, "the sequence advanced");
        assertEq(dispatcher.stateVersion(), 1, "command success moves no value: version unchanged");
        CommandAck memory ack = _lastAck();
        assertEq(ack.stateVersion, 1, "ACK carries the CURRENT version");

        _relayAt(_lastSentIndex());
        assertFalse(_commandSlotActive(), "ACK resolved the command");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 1, "an ACK never moves the frontier");
        _assertLockstep("after the deposit ACK");
    }

    /// @notice (a) A command cancel leaves the version unchanged; the cancel ACK carries the current version.
    function testCommandCancelLeavesVersionUnchangedAndAckCarriesCurrent() public {
        _allowRemoteVault();
        _bridgeToDispatcher(100e6);
        uint64 versionBefore = dispatcher.stateVersion();

        // A config update the dispatcher rejects (foreign asset), leaving the command FAILED on both sides.
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockRemoteVault badVault = new MockRemoteVault(IERC20(address(dai)), "Bad", "BAD");
        address[] memory vaults = new address[](1);
        vaults[0] = address(badVault);
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, vaults);
        _relayAt(_lastSentIndex()); // UPDATE_VAULTS -> dispatcher, NACK queued
        _relayAt(_lastSentIndex()); // NACK -> executor
        relayCursor = endpoint.sentCount();
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED), "failed on both sides");
        assertEq(dispatcher.stateVersion(), versionBefore, "a NACK moves nothing");

        uint64 sequenceBefore = dispatcher.nextCommandSequence();
        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayAt(_lastSentIndex()); // CANCEL_COMMAND -> dispatcher

        assertEq(dispatcher.nextCommandSequence(), sequenceBefore + 1, "cancel advances exactly one sequence");
        assertEq(dispatcher.stateVersion(), versionBefore, "cancel moves no value: version unchanged");
        CommandAck memory ack = _lastAck();
        assertEq(ack.stateVersion, versionBefore, "cancel ACK carries the CURRENT version");

        _relayAt(_lastSentIndex()); // cancel ACK -> executor
        assertFalse(_commandSlotActive(), "cancel ACK freed the slot");
        _assertLockstep("after the cancel ACK");
    }

    /// @notice (a) The value-moving transitions still bump by exactly one each: the inbound transfer settle
    ///         and the return-started.
    function testSettleAndReturnStartedBumpTheVersionByOne() public {
        assertEq(dispatcher.stateVersion(), 0);
        _bridgeToDispatcher(100e6);
        assertEq(dispatcher.stateVersion(), 1, "settle bumped by one");
        _assertLockstep("after settle");

        (bytes32 requestId, , ) = _requestAssets(40e6, 0);
        _relayAt(_lastSentIndex()); // RETURN_ASSETS_REQUEST -> dispatcher: RETURN_STARTED queued
        assertTrue(dispatcher.recallConsumed(requestId), "recall consumed");
        assertEq(dispatcher.stateVersion(), 2, "return-started bumped by one");
        (MsgType mt, bytes memory data) = CrosschainMessages.decodeEnvelope(
            endpoint.sentAt(endpoint.sentCount() - 1).message
        );
        assertEq(uint8(mt), uint8(MsgType.RETURN_STARTED));
        assertGt(data.length, 0);

        _relayAt(_lastSentIndex()); // RETURN_STARTED -> executor
        _assertLockstep("after return-started");
    }

    /// @notice (b) + (e) Command traffic, then a value-moving message, then an honest attestation at the
    ///         dispatcher's `observation().stateVersion`: no drift, nothing gaps, nothing is dropped.
    function testHonestAttestationAtDispatcherVersionSucceedsAfterCommandTraffic() public {
        _allowRemoteVault(); // config traffic: epoch 2, no version bump
        assertEq(dispatcher.stateVersion(), 0);
        _bridgeToDispatcher(100e6); // settle applies at frontier + 1: no gap, no duplicate drop
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "the settle applied");

        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(60e6));
        _relayAll(); // more command traffic after the settle

        uint64 observed = dispatcher.observation().stateVersion;
        assertEq(observed, executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), "no drift after command traffic");

        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: 100e6,
            stateVersion: observed,
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: dispatcher.observation().trackedPositionSetHash
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        uint256 pid = executor.proposalCount();
        vm.prank(approver);
        executor.approveBalance(pid);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "attested");
    }
}

/// @notice Executor-side behaviour of a command receipt, with crafted and replayed ACKs.
contract StargateValueNeutralVersionExecutorTest is CrosschainTestBase {
    event CommandReceiptConsumedWithoutCommand(uint256 srcChainId, bytes32 commandId, uint64 stateVersion);
    event CommandReceiptAdopted(
        uint256 srcChainId,
        bytes32 commandId,
        uint64 sequence,
        uint64 dispatcherConfigEpoch,
        bytes32 superseded
    );

    bytes32 private constant ADOPTED_TOPIC = keccak256("CommandReceiptAdopted(uint256,bytes32,uint64,uint64,bytes32)");

    function setUp() public {
        _baseSetUp();
        _readyDispatcher();
    }

    function _sendConfigCommand() internal returns (bytes32 commandId, uint64 sequence) {
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, new address[](0));
        (, , , , commandId, sequence, ) = executor.activeCommand(REMOTE_CHAIN);
    }

    function _commandSlotActive() internal view returns (bool active) {
        (active, , , , , , ) = executor.activeCommand(REMOTE_CHAIN);
    }

    function _abandon(ResolveOutcome outcome_) internal {
        bytes32 id = bytes32(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, outcome_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, id, outcome_);
    }

    /// @notice (b) An ACK never moves the frontier, even when it names a far-ahead evidence version, and a
    ///         following settle at frontier + 1 applies: no gap, no "older duplicate" drop.
    function testAckNeverMovesFrontierAndNextSettleAtFrontierPlusOneApplies() public {
        (bytes32 transferId, bytes32 guid, ) = _sendAsset(100e6, 0);
        (bytes32 commandId, uint64 sequence) = _sendConfigCommand();
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 0);

        _deliverCommandAck(commandId, sequence, 7, 0); // evidence version far ahead of the frontier
        assertFalse(_commandSlotActive(), "ACK resolved the command");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 0, "an ACK never moves the frontier");

        _deliverTransferSettled(transferId, guid, 100e6, 1);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 1, "settle at frontier + 1 applied");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "and was credited, not dropped");
    }

    /// @notice (b) Same with a cancel resolution.
    function testCancelAckNeverMovesFrontier() public {
        (bytes32 commandId, uint64 sequence) = _sendConfigCommand();
        _deliverCommandNack(commandId, sequence);
        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _deliverCommandCancelAck(commandId, sequence, 3);
        assertFalse(_commandSlotActive(), "cancel ACK freed the slot");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 0, "a cancel ACK never moves the frontier");
    }

    /// @notice (c) A redelivered ACK is a no-op: the command is not double-resolved and the sequence mirror is
    ///         not advanced twice. The duplicate is decided by command identity and sequence alone.
    function testRedeliveredAckIsANoOp() public {
        (bytes32 commandId, uint64 sequence) = _sendConfigCommand();
        _deliverCommandAck(commandId, sequence, 0, 0);
        uint64 mirrorAfter = executor.nextSequenceToSend(REMOTE_CHAIN);
        uint64 epochAfter = executor.chainConfigEpoch(REMOTE_CHAIN);
        assertEq(mirrorAfter, sequence + 1, "resolved once");

        // A NEW command now occupies the slot; the replayed ACK must not touch it either.
        (bytes32 nextId, uint64 nextSequence) = _sendConfigCommand();
        assertEq(nextSequence, mirrorAfter);

        vm.recordLogs();
        _deliver(
            CrosschainMessages.encodeCommandAck(
                CommandAck({
                    commandId: commandId,
                    sequence: sequence,
                    stateVersion: 0,
                    dispatcherConfigEpoch: epochAfter,
                    resolution: CommandResolution.SUCCEEDED,
                    valueDeltaSD: 0
                })
            )
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != ADOPTED_TOPIC, "a duplicate is not adopted");
        }
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), mirrorAfter, "sequence mirror not advanced twice");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), epochAfter, "epoch mirror untouched");
        assertEq(_activeCommandId(), nextId, "the new command still holds the slot");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 0, "frontier untouched");
    }

    /// @notice (c) A redelivered ACK with the slot free surfaces `CommandReceiptConsumedWithoutCommand`
    ///         and changes nothing.
    function testRedeliveredAckWithFreeSlotIsSurfacedAndHarmless() public {
        (bytes32 commandId, uint64 sequence) = _sendConfigCommand();
        _deliverCommandAck(commandId, sequence, 0, 0);
        uint64 mirrorAfter = executor.nextSequenceToSend(REMOTE_CHAIN);
        uint64 epochAfter = executor.chainConfigEpoch(REMOTE_CHAIN);

        vm.expectEmit(false, false, false, true, address(executor));
        emit CommandReceiptConsumedWithoutCommand(REMOTE_CHAIN, commandId, 0);
        _deliverCommandAckAs(commandId, sequence, 0, 0, CommandResolution.SUCCEEDED, epochAfter);

        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), mirrorAfter, "sequence not double-advanced");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), epochAfter);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 0);
    }

    /// @notice (d) A late ACK after a CONSUMED abandon (sequence below the mirror) is ignored, exactly as
    ///         before, and the frontier does not move.
    function testLateAckAfterConsumedAbandonIsIgnoredBySequence() public {
        (bytes32 commandId, uint64 sequence) = _sendConfigCommand();
        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);
        uint64 mirror = executor.nextSequenceToSend(REMOTE_CHAIN);
        assertEq(mirror, sequence + 1);

        vm.recordLogs();
        _deliverCommandAckAs(
            commandId,
            sequence,
            5,
            0,
            CommandResolution.SUCCEEDED,
            executor.chainConfigEpoch(REMOTE_CHAIN)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != ADOPTED_TOPIC, "nothing adopted");
        }
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), mirror, "mirror not moved by a stale receipt");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 0, "frontier untouched");
    }

    /// @notice (d) A late ACK after an UNUSED abandon (sequence at the mirror) is adopted by sequence, and
    ///         the frontier still does not move.
    function testLateAckAfterUnusedAbandonIsAdoptedBySequence() public {
        (bytes32 commandId, uint64 sequence) = _sendConfigCommand();
        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), sequence, "unused: sequence reused");

        vm.expectEmit(false, false, false, true, address(executor));
        emit CommandReceiptAdopted(REMOTE_CHAIN, commandId, sequence, 2, bytes32(0));
        _deliverCommandAckAs(commandId, sequence, 5, 0, CommandResolution.SUCCEEDED, 2);

        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), sequence + 1, "adopted: mirror follows the dispatcher");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 2, "epoch adopted");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 0, "frontier untouched");
    }

    /// @notice (e) After command traffic the executor frontier still equals the dispatcher's version, so an
    ///         honest attestation at that version is accepted.
    function testAttestationAtFrontierSucceedsAfterCommandTraffic() public {
        _settle100(); // value-moving: dispatcher version 1, frontier 1
        (bytes32 commandId, uint64 sequence) = _sendConfigCommand();
        _deliverCommandAck(commandId, sequence, 1, 0); // current version as evidence

        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 1, "no drift");
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: 100e6,
            stateVersion: 1,
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        uint256 pid = executor.proposalCount();
        vm.prank(approver);
        executor.approveBalance(pid);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6);
    }

    /// @notice (f) Command traffic during the delay no longer voids a scheduled settled force-set...
    function testScheduledForceSetSurvivesCommandTraffic() public {
        _settle100(); // frontier 1
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceSetSettledBalance(REMOTE_CHAIN, 80e6, 1, _markFsObs(), false);

        (bytes32 commandId, uint64 sequence) = _sendConfigCommand();
        _deliverCommandAck(commandId, sequence, 1, 0);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 1, "command traffic left the frontier");

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(rescueId, REMOTE_CHAIN, 80e6, 1, fsObs, false);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 80e6, "force-set executed");
    }

    /// @notice (f) ...but a value-moving message still does.
    function testScheduledForceSetIsStillVoidedByValueMovingMessage() public {
        _settle100(); // frontier 1
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceSetSettledBalance(REMOTE_CHAIN, 80e6, 1, _markFsObs(), false);

        (bytes32 transferId, bytes32 guid, ) = _sendAsset(10e6, 0);
        _deliverTransferSettled(transferId, guid, 10e6, 2);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 2);

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.ForceSetStateVersionMismatch.selector, REMOTE_CHAIN, 2, 1)
        );
        executor.executeForceSetSettledBalance(rescueId, REMOTE_CHAIN, 80e6, 1, fsObs, false);
    }
}
