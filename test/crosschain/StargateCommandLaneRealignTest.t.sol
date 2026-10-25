// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {BusinessAction, CommandStatus, ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CrosschainMessages, Command} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {StargateExecutorAccountingLib} from "../../contracts/crosschain/stargate/lib/StargateExecutorAccountingLib.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @title StargateCommandLaneRealignTest
/// @notice IL-7970, Stargate half, two-sided against a REAL dispatcher: adoption of a late `COMMAND_ACK`
///         and the timelocked `REALIGN_COMMAND_LANE` force-resolve outcome.
/// @dev Same two holes as the CCIP transport. `_onCommandAck` used to discard the `sequence` and
///      `dispatcherConfigEpoch` of every receipt that resolved no active command, even though both are
///      authenticated dispatcher state; and `ResolveOutcome` had no primitive that could LOWER
///      `nextSequenceToSend`, so an executor whose mirror ran ahead of the dispatcher (one wrong
///      `ABANDON_COMMAND_SEQUENCE_CONSUMED`) stamped sequences the dispatcher would reject forever.
///
///      Payloads are relayed by hand (`StargateTwoSidedBase`), so "the receipt is still in flight" and
///      "the receipt is never delivered" are both modelled by genuinely produced, genuinely undelivered
///      messages rather than by mocks.
contract StargateCommandLaneRealignTest is StargateTwoSidedBase {
    bytes32 internal constant RECEIPT_ADOPTED_TOPIC =
        keccak256("CommandReceiptAdopted(uint256,bytes32,uint64,uint64,bytes32)");

    function setUp() public {
        _twoSidedSetUp();
    }

    // ---------------------------------------------------------------------
    // Helpers (duplicated from StaleCommandResolutionTest / StuckCommandRecoveryTest on purpose: those
    // are audit regression files and are left byte-identical)
    // ---------------------------------------------------------------------

    function _abandon(ResolveOutcome outcome_) internal {
        bytes32 id = bytes32(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, outcome_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, id, outcome_);
    }

    /// @dev IL-8652: `(chainId << 192) | (expectedEpoch << 144) | (expectedSequence << 96) | (newEpoch << 48) |
    ///      newSequence`, with 48-bit counter fields.
    function _realignIdFrom(uint256 chainId_, uint64 expEpoch_, uint64 expSequence_, uint64 epoch_, uint64 sequence_)
        internal
        pure
        returns (bytes32)
    {
        return bytes32(
            (chainId_ << 192) | (uint256(expEpoch_) << 144) | (uint256(expSequence_) << 96) | (uint256(epoch_) << 48)
                | uint256(sequence_)
        );
    }

    /// @dev Realign id armed against the executor's CURRENT mirrors.
    function _realignId(uint256 chainId_, uint64 epoch_, uint64 sequence_) internal view returns (bytes32) {
        return _realignIdFrom(
            chainId_, executor.chainConfigEpoch(chainId_), executor.nextSequenceToSend(chainId_), epoch_, sequence_
        );
    }

    function _realign(uint64 epoch_, uint64 sequence_) internal {
        bytes32 id = _realignId(REMOTE_CHAIN, epoch_, sequence_);
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, ResolveOutcome.REALIGN_COMMAND_LANE);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, id, ResolveOutcome.REALIGN_COMMAND_LANE);
    }

    /// @dev Free the slot and realign it in ONE delay window. The free-slot requirement is checked at
    ///      EXECUTE time only, which is exactly what lets both be armed in the same block.
    function _abandonThenRealign(ResolveOutcome abandonOutcome_, uint64 epoch_, uint64 sequence_) internal {
        bytes32 abandonId = bytes32(REMOTE_CHAIN);
        // Expected pair = the state AFTER the abandon: a CONSUMED abandon raises the sequence mirror by one.
        bytes32 realignId = _realignIdFrom(
            REMOTE_CHAIN,
            executor.chainConfigEpoch(REMOTE_CHAIN),
            executor.nextSequenceToSend(REMOTE_CHAIN)
                + (abandonOutcome_ == ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED ? 1 : 0),
            epoch_,
            sequence_
        );
        vm.startPrank(admin);
        uint256 abandonRescue = executor.scheduleForceResolveTransfer(abandonId, abandonOutcome_);
        uint256 realignRescue = executor.scheduleForceResolveTransfer(realignId, ResolveOutcome.REALIGN_COMMAND_LANE);
        vm.stopPrank();
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.startPrank(admin);
        executor.executeForceResolveTransfer(abandonRescue, abandonId, abandonOutcome_);
        executor.executeForceResolveTransfer(realignRescue, realignId, ResolveOutcome.REALIGN_COMMAND_LANE);
        vm.stopPrank();
    }

    /// @dev Bring both sides up and allowlist the remote vault (both epochs -> 2) WITHOUT bridging
    ///      capital, so a DEPOSIT fails on the dispatcher for a transient reason (no tracked idle).
    function _readyWithoutCapital() internal {
        _bringUpBothSides();
        _allowRemoteVault();
    }

    function _readyWithCapital() internal {
        _bringUpBothSides();
        _allowRemoteVault();
        _bridgeToDispatcher(100e6);
    }

    /// @dev Send a DEPOSIT that the dispatcher fails (no tracked idle), leaving a FAILED record at `S`.
    function _failedDeposit(uint256 amountSD_) internal returns (bytes32 commandId, uint64 sequence) {
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(amountSD_));
        (,,,, commandId, sequence,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "failed on the dispatcher");
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED), "failed on the executor");
    }

    /// @dev Send a DEPOSIT, run it through the REAL dispatcher, and leave its ACK undelivered.
    function _commandWithUndeliveredAck() internal returns (bytes32 commandId, uint256 ackIndex) {
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(50e6));
        (,,,, commandId,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAt(_lastSentIndex());
        ackIndex = _lastSentIndex();
        relayCursor = endpoint.sentCount();
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "dispatcher ran it");
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.PENDING), "executor still waiting");
    }

    /// @dev Deliver the packet at `packetIndex_` while the dispatcher cannot fund the worst-case receipt,
    ///      proving it is retained by LayerZero rather than consumed. MUST read `endpoint.sentAt` and
    ///      `endpoint.messagingFee` BEFORE `vm.expectRevert`: it applies to the very next external call.
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

    /// @dev Attempt a delivery that the dispatcher must reject with `SequenceGap`, leaving the packet
    ///      retained. Reads the packet and the fee before arming `vm.expectRevert`.
    function _expectSequenceGapOnDelivery(uint256 packetIndex_, uint64 expected_, uint64 received_) internal {
        MockLzEndpoint.SentMessage memory m = endpoint.sentAt(packetIndex_);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.SequenceGap.selector, expected_, received_));
        endpoint.deliverLz(
            address(dispatcher), LOCAL_EID, bytes32(uint256(uint160(address(dispatcher)))), m.guid, m.message
        );
    }

    function _redeemAllCommand() internal view returns (Command memory) {
        return Command({
            commandId: bytes32(0),
            sequence: 0,
            commandConfigEpoch: 0,
            action: uint8(BusinessAction.REDEEM),
            minExecutionGas: DEFAULT_COMMAND_BUDGET,
            actionData: CrosschainMessages.encodeRedeemAction(
                address(remoteVault), remoteVault.balanceOf(address(dispatcher)), 0
            )
        });
    }

    function _assertMirrorsMatchDispatcher(string memory label_) internal view {
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), dispatcher.nextCommandSequence(), label_);
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), dispatcher.commandConfigEpoch(), label_);
    }

    // ---------------------------------------------------------------------
    // S1-S2 — the late receipt
    // ---------------------------------------------------------------------

    /// @notice IL-7979's handed-over ordering, as changed by IL-8594: a CANCEL_COMMAND packet retained by LayerZero
    ///         outlives an `ABANDON_COMMAND_SEQUENCE_UNUSED` rescue (which is only possible past the command's
    ///         deadline), then executes. Past the deadline the dispatcher closes the command WITHOUT consuming its
    ///         sequence and answers `EXPIRED`; the executor, whose slot is free, ignores the receipt. Before the fix
    ///         the cancel consumed the sequence and the CANCELLED receipt had to be adopted to realign the mirror.
    ///         (Rewritten: it used to assert the dispatcher moved to `sequence + 1` and the mirror adopted it.)
    function testShouldIgnoreAStaleCancelThatLandsAfterTheAbandonBeforeAnyReplacement() public {
        _readyWithoutCapital();
        (bytes32 abandoned, uint64 sequence) = _failedDeposit(50e6);

        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        uint256 cancelPacket = _lastSentIndex();
        _retainByStarvingBudget(cancelPacket);
        relayCursor = endpoint.sentCount();

        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), sequence, "mirror parked on the abandoned sequence");

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit StargateCrosschainDispatcher.CancelCommandExpiredIgnored(abandoned, sequence);
        _relayAt(cancelPacket); // the retained CANCEL finally executes, past the deadline
        assertEq(dispatcher.nextCommandSequence(), sequence, "the expired cancel did not consume the sequence");
        assertEq(uint8(dispatcher.commandStatus(abandoned)), uint8(CommandStatus.CANCELLED), "but closed the command");

        vm.expectEmit(false, false, false, true, address(executor));
        emit StargateExecutorAccountingLib.CommandReceiptConsumedWithoutCommand(
            REMOTE_CHAIN, abandoned, dispatcher.stateVersion()
        );
        _relayAt(cancelPacket + 1); // its EXPIRED receipt: no active command, ignored

        _assertMirrorsMatchDispatcher("nothing moved: mirrors still agree");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), sequence, "sequence mirror untouched");
        relayCursor = endpoint.sentCount();

        // The lane is alive with no rescue beyond the abandon that started this.
        _bridgeToDispatcher(100e6);
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(40e6));
        (,,,, bytes32 fresh, uint64 freshSequence,) = executor.activeCommand(REMOTE_CHAIN);
        assertEq(freshSequence, sequence, "the replacement reuses the abandoned sequence");
        _relayAll();
        assertEq(uint8(dispatcher.commandStatus(fresh)), uint8(CommandStatus.SUCCEEDED), "lane alive");
        assertFalse(_commandSlotActive(), "and its receipt resolved normally");
    }

    /// @notice The same ordering with a replacement already in the freed slot. Before IL-8594 the retained cancel
    ///         consumed the replacement's sequence and its CANCELLED receipt retired the replacement ("doomed",
    ///         `SequenceGap` forever). Now the expired cancel consumes nothing, its `EXPIRED` receipt is ignored
    ///         because the slot holds the replacement, and the replacement executes at its own sequence.
    ///         (Rewritten: it used to pin the doomed-replacement supersede as intended.)
    function testShouldRunTheReplacementWhenAStaleCancelLandsAfterTheAbandon() public {
        _readyWithoutCapital();
        (bytes32 abandoned, uint64 sequence) = _failedDeposit(50e6);

        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        uint256 cancelPacket = _lastSentIndex();
        _retainByStarvingBudget(cancelPacket);
        relayCursor = endpoint.sentCount();

        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);

        // Capital arrives and a replacement takes the freed slot at the same sequence; its packet is not
        // delivered yet.
        _bridgeToDispatcher(100e6);
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(10e6));
        (,,,, bytes32 replacement, uint64 replacementSequence,) = executor.activeCommand(REMOTE_CHAIN);
        assertEq(replacementSequence, sequence, "replacement reuses the abandoned sequence");
        uint256 replacementPacket = _lastSentIndex();
        relayCursor = endpoint.sentCount();

        _relayAt(cancelPacket); // the retained CANCEL executes; its receipt is the newest packet
        assertEq(dispatcher.nextCommandSequence(), sequence, "the expired cancel did not consume the sequence");
        uint256 ackIndex = _lastSentIndex();
        // The EXPIRED receipt names the abandoned command and is ignored: the replacement keeps the slot.
        vm.expectEmit(false, false, false, true, address(executor));
        emit StargateExecutorAccountingLib.CommandReceiptConsumedWithoutCommand(
            REMOTE_CHAIN, abandoned, dispatcher.stateVersion()
        );
        _relayAt(ackIndex);
        assertTrue(_commandSlotActive(), "the replacement keeps the slot");
        (,,,, bytes32 stillActive,,) = executor.activeCommand(REMOTE_CHAIN);
        assertEq(stillActive, replacement, "and it is the replacement");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), sequence, "mirror untouched");

        // The replacement's own packet now executes and its deposit runs.
        _relayAt(replacementPacket);
        _relayAt(_lastSentIndex()); // its receipt is the newest packet
        assertEq(uint8(dispatcher.commandStatus(replacement)), uint8(CommandStatus.SUCCEEDED), "replacement ran");
        assertEq(remoteVault.balanceOf(address(dispatcher)), 10e6, "its deposit ran");
        assertFalse(_commandSlotActive(), "resolved by its own receipt");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    // ---------------------------------------------------------------------
    // S3-S4 — the realign rescue on the two desynced directions
    // ---------------------------------------------------------------------

    /// @notice The terminal sub-state: a CONSUMED declaration for a command the dispatcher never received
    ///         puts the mirror AHEAD. `_onCommandAck` and `_abandonCommand` only ever raise it and the
    ///         dispatcher advances only by executing the sequence it expects, so before this fix the pair
    ///         was dead with no exit.
    function testShouldRealignAnExecutorThatRanAhead() public {
        _readyWithCapital();

        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(50e6));
        (,,,, bytes32 deposited,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();
        assertEq(uint8(dispatcher.commandStatus(deposited)), uint8(CommandStatus.SUCCEEDED), "position opened");
        assertGt(remoteVault.balanceOf(address(dispatcher)), 0, "capital deployed");

        // A command the dispatcher never receives, declared CONSUMED anyway.
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(10e6));
        relayCursor = endpoint.sentCount();
        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);
        uint64 dispatcherSequence = dispatcher.nextCommandSequence();
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), dispatcherSequence + 1, "executor is one AHEAD");

        // Every command the executor can now stamp is rejected by the dispatcher: the lane is dead.
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(10e6));
        uint256 doomedPacket = _lastSentIndex();
        relayCursor = endpoint.sentCount();
        _expectSequenceGapOnDelivery(doomedPacket, dispatcherSequence, dispatcherSequence + 1);

        uint256 settledBefore = executor.settledRemoteBalance(REMOTE_CHAIN);
        uint64 frontierBefore = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);

        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED); // free the slot the doomed command holds
        _realign(dispatcher.commandConfigEpoch(), dispatcher.nextCommandSequence());

        _assertMirrorsMatchDispatcher("realigned downwards onto the dispatcher's counters");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), settledBefore, "settled untouched");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), frontierBefore, "frontier untouched");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "no NAV block raised");

        // Build the command BEFORE the prank: it reads the vault's share balance externally, which would
        // otherwise consume `vm.prank`.
        Command memory redeem = _redeemAllCommand();
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, redeem);
        (,,,, bytes32 redeemId,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();
        assertEq(uint8(dispatcher.commandStatus(redeemId)), uint8(CommandStatus.SUCCEEDED), "lane alive again");
        assertEq(remoteVault.balanceOf(address(dispatcher)), 0, "position drained through the protocol");
    }

    /// @notice The executor-behind direction: an UNUSED declaration for a command the dispatcher DID run
    ///         used to cost one sacrificial command plus one timelocked CONSUMED abandon per unit of lag
    ///         (IL-7979 §1.11's residual). The abandon and the realign are armed in the SAME block here
    ///         and executed back to back, which is what the execute-time free-slot check buys.
    /// @dev The ACK is never delivered. It is value-neutral and carries no frontier version (IL-8257), so
    ///      nothing is missing from the frontier and no `ADVANCE_STATE_FRONTIER` repair is needed. The
    ///      assertion below is dispatcher-side.
    function testShouldRealignAnExecutorThatFellBehindWithoutASacrificialCommand() public {
        _readyWithCapital();
        _commandWithUndeliveredAck();

        uint64 dispatcherSequence = dispatcher.nextCommandSequence();
        _abandonThenRealign(
            ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED, dispatcher.commandConfigEpoch(), dispatcherSequence
        );

        _assertMirrorsMatchDispatcher("realigned upwards with no sacrificial command");

        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(25e6));
        (,,,, bytes32 fresh,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAt(_lastSentIndex());
        assertEq(uint8(dispatcher.commandStatus(fresh)), uint8(CommandStatus.SUCCEEDED), "dispatcher accepted it");
    }

    // ---------------------------------------------------------------------
    // S5-S7 — the fences on the realign
    // ---------------------------------------------------------------------

    /// @notice A realign while a command is outstanding would leave that command stamped with a sequence
    ///         the mirror no longer stands behind. Scheduling is still allowed; the refusal is at execute.
    function testShouldRejectRealignWhileACommandIsActive() public {
        _readyWithCapital();
        _commandWithUndeliveredAck();

        bytes32 id = _realignId(REMOTE_CHAIN, 9, 9);
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, ResolveOutcome.REALIGN_COMMAND_LANE);
        vm.warp(block.timestamp + RESCUE_DELAY);

        uint64 sequenceBefore = executor.nextSequenceToSend(REMOTE_CHAIN);
        uint64 epochBefore = executor.chainConfigEpoch(REMOTE_CHAIN);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ActiveCommandExists.selector, REMOTE_CHAIN));
        executor.executeForceResolveTransfer(rescueId, id, ResolveOutcome.REALIGN_COMMAND_LANE);

        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), sequenceBefore, "sequence mirror untouched");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), epochBefore, "epoch mirror untouched");
    }

    /// @notice The chain id travels inside the packed id, so a mis-pack decodes to some other id. Since
    ///         IL-8652 the schedule refuses an id whose decoded chain has no ready dispatcher, before the
    ///         delay is spent: an unregistered id, the frontier layout (decodes to 0) and the pre-binding
    ///         layout (`chainId << 128`, decodes to 0). A mis-pack that decodes to a registered chain still
    ///         passes, so the operator re-decodes `id >> 192` themselves.
    function testShouldRefuseRealignForAnUnregisteredChainAtSchedule() public {
        _readyWithCapital();

        bytes32 wrongChain = _realignIdFrom(REMOTE_CHAIN + 1, 2, 5, 2, 5);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DispatcherNotReady.selector, REMOTE_CHAIN + 1));
        executor.scheduleForceResolveTransfer(wrongChain, ResolveOutcome.REALIGN_COMMAND_LANE);

        // The frontier layout `(chainId << 64) | value` decodes to chain 0 under this one.
        bytes32 frontierLayout = bytes32((REMOTE_CHAIN << 64) | uint256(5));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DispatcherNotReady.selector, uint256(0)));
        executor.scheduleForceResolveTransfer(frontierLayout, ResolveOutcome.REALIGN_COMMAND_LANE);

        // The pre-IL-8652 layout `(chainId << 128) | (epoch << 64) | sequence` decodes to chain 0 as well.
        bytes32 legacyLayout = bytes32((REMOTE_CHAIN << 128) | (uint256(2) << 64) | uint256(5));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.DispatcherNotReady.selector, uint256(0)));
        executor.scheduleForceResolveTransfer(legacyLayout, ResolveOutcome.REALIGN_COMMAND_LANE);

        _assertMirrorsMatchDispatcher("mirrors untouched by the refusals");
    }

    /// @notice The realign is the only outcome that can lower a counter, so it carries the full rescue
    ///         envelope: admin-only, timelocked, cancellable and guardian-vetoable.
    function testShouldTimelockAndGuardianVetoRealign() public {
        _readyWithCapital();
        bytes32 id = _realignId(REMOTE_CHAIN, 4, 7);
        uint64 sequenceBefore = executor.nextSequenceToSend(REMOTE_CHAIN);
        uint64 epochBefore = executor.chainConfigEpoch(REMOTE_CHAIN);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedRescueAdmin.selector, manager));
        executor.scheduleForceResolveTransfer(id, ResolveOutcome.REALIGN_COMMAND_LANE);

        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, ResolveOutcome.REALIGN_COMMAND_LANE);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueTimelockNotElapsed.selector,
                rescueId,
                block.timestamp,
                block.timestamp + RESCUE_DELAY
            )
        );
        executor.executeForceResolveTransfer(rescueId, id, ResolveOutcome.REALIGN_COMMAND_LANE);

        vm.prank(guardian);
        executor.cancelRescue(rescueId);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueNotScheduled.selector, rescueId));
        executor.executeForceResolveTransfer(rescueId, id, ResolveOutcome.REALIGN_COMMAND_LANE);

        vm.prank(admin);
        uint256 vetoedId = executor.scheduleForceResolveTransfer(id, ResolveOutcome.REALIGN_COMMAND_LANE);
        vm.prank(guardian);
        executor.vetoAllPendingRescues();
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueVetoed.selector, vetoedId));
        executor.executeForceResolveTransfer(vetoedId, id, ResolveOutcome.REALIGN_COMMAND_LANE);

        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), sequenceBefore, "sequence mirror untouched so far");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), epochBefore, "epoch mirror untouched so far");

        _realign(4, 7);
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), 7, "a clean round applies");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 4, "a clean round applies");
    }

    // ---------------------------------------------------------------------
    // S8 — control
    // ---------------------------------------------------------------------

    /// @notice CONTROL, passes before and after this fix: it is not regression evidence, it pins the
    ///         boundary of the new adoption path. A receipt BELOW the mirror is a duplicate, or one a
    ///         correct CONSUMED abandon already accounted for, so adopting it would double-count. It must
    ///         still take the "command effects skipped" exit, and a command receipt never moves
    ///         the frontier.
    function testShouldNotLetAStaleReceiptLowerTheMirror() public {
        _readyWithCapital();
        (, uint256 ackIndex) = _commandWithUndeliveredAck();

        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED); // the CORRECT declaration
        uint64 mirrorAfterAbandon = executor.nextSequenceToSend(REMOTE_CHAIN);
        uint64 frontierBefore = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);

        vm.recordLogs();
        _relayAt(ackIndex);
        relayCursor = endpoint.sentCount();

        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), mirrorAfterAbandon, "mirror not moved by a stale receipt");
        assertEq(
            executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), frontierBefore, "and it never moves the frontier"
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != RECEIPT_ADOPTED_TOPIC, "nothing was adopted");
        }
    }

    // ---------------------------------------------------------------------
    // S9 — the blast radius of the new writer
    // ---------------------------------------------------------------------

    /// @notice The realign is a lever on exactly two storage slots. Running it repeatedly, including to
    ///         nonsense values, must move nothing else.
    /// @dev GUARD, not regression evidence: it asserts what the new writer must NOT do, so it passes both
    ///      with the realign branch present and with it stubbed out. It bounds the blast radius of a
    ///      writer that can lower a counter.
    /// @dev On Stargate `getBalanceByChain` is a raw sum of the three booked buckets with no staleness
    ///      window or `ChainBlocked` gate (IL-9066), so the snapshot holds the buckets it reads.
    function testShouldNotLetRepeatedRealignsTouchAnythingButTheMirrors() public {
        _readyWithCapital();

        uint256 settled = executor.settledRemoteBalance(REMOTE_CHAIN);
        uint256 idle = executor.idleLedger();
        uint256 inFlight = executor.outboundInFlight(REMOTE_CHAIN);
        uint64 frontier = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        bool blocked = executor.chainBlocked(REMOTE_CHAIN);
        uint64 dispatcherSequence = dispatcher.nextCommandSequence();
        uint64 dispatcherEpoch = dispatcher.commandConfigEpoch();
        uint256 dispatcherIdle = dispatcher.trackedIdle();

        // Each realign is armed against the state the previous one leaves behind.
        bytes32[3] memory ids = [
            _realignId(REMOTE_CHAIN, 7, 99),
            _realignIdFrom(REMOTE_CHAIN, 7, 99, 2, 3),
            _realignIdFrom(REMOTE_CHAIN, 2, 3, dispatcherEpoch, dispatcherSequence)
        ];
        uint256[3] memory rescueIds;
        vm.startPrank(admin);
        for (uint256 i; i < 3; ++i) {
            rescueIds[i] = executor.scheduleForceResolveTransfer(ids[i], ResolveOutcome.REALIGN_COMMAND_LANE);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + RESCUE_DELAY);

        for (uint256 i; i < 3; ++i) {
            vm.prank(admin);
            executor.executeForceResolveTransfer(rescueIds[i], ids[i], ResolveOutcome.REALIGN_COMMAND_LANE);
            assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), settled, "settled untouched");
            assertEq(executor.idleLedger(), idle, "idle untouched");
            assertEq(executor.outboundInFlight(REMOTE_CHAIN), inFlight, "in-flight untouched");
            assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), frontier, "frontier untouched");
            assertEq(executor.chainBlocked(REMOTE_CHAIN), blocked, "block flag untouched");
            assertEq(dispatcher.nextCommandSequence(), dispatcherSequence, "dispatcher sequence untouched");
            assertEq(dispatcher.commandConfigEpoch(), dispatcherEpoch, "dispatcher epoch untouched");
            assertEq(dispatcher.trackedIdle(), dispatcherIdle, "dispatcher idle untouched");
        }

        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(25e6));
        (,,,, bytes32 fresh,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();
        assertEq(uint8(dispatcher.commandStatus(fresh)), uint8(CommandStatus.SUCCEEDED), "lane works at the end");
    }
}
