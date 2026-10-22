// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {StargateExecutorAccountingLib} from "../../contracts/crosschain/stargate/lib/StargateExecutorAccountingLib.sol";
import {
    BusinessAction,
    CommandResolution,
    CommandStatus,
    CrosschainConstants,
    ResolveOutcome
} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {Command, CommandAck, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @title StargateExpiredCommandReceiptTest
/// @notice IL-8594, Stargate half: a CANCEL_COMMAND that outlives its command's deadline closes the command WITHOUT
///         consuming its sequence and is answered with an authenticated `EXPIRED` receipt. The executor frees the
///         slot only for the FAILED command that still owns it (so the manager's post-TTL cancel ends an
///         stall of a FAILED command without the admin) and ignores the receipt in every other state (so a retained
///         cancel can no longer retire a same-sequence replacement).
/// @dev Two-sided against a REAL dispatcher with hand-relayed payloads (`StargateTwoSidedBase`).
contract StargateExpiredCommandReceiptTest is StargateTwoSidedBase {
    function setUp() public {
        _twoSidedSetUp();
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _msgAt(uint256 index_) internal view returns (MockLzEndpoint.SentMessage memory) {
        return endpoint.sentAt(index_);
    }

    /// @dev Deliver a recorded executor -> dispatcher packet with exactly `gas_` given to the endpoint call.
    function _deliverMsg(MockLzEndpoint.SentMessage memory m_, uint256 gas_)
        internal
        returns (bool ok, bytes memory ret)
    {
        bytes memory callData = abi.encodeCall(
            MockLzEndpoint.deliverLz,
            (address(dispatcher), LOCAL_EID, bytes32(uint256(uint160(address(dispatcher)))), m_.guid, m_.message)
        );
        (ok, ret) = address(endpoint).call{gas: gas_}(callData);
    }

    function _abandon(ResolveOutcome outcome_) internal {
        bytes32 id = bytes32(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, outcome_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, id, outcome_);
    }

    /// @dev Send a DEPOSIT the dispatcher fails (no tracked idle): FAILED on both sides.
    function _failedDeposit(uint256 amountSD_) internal returns (bytes32 commandId, uint64 sequence) {
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(amountSD_));
        (,,,, commandId, sequence,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "failed on the dispatcher");
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED), "failed on the executor");
    }

    /// @dev Cancel the active command and keep the packet undelivered (the dispatcher cannot fund the receipt, so
    ///      LayerZero retains it). Returns the retained packet.
    function _retainedCancel() internal returns (MockLzEndpoint.SentMessage memory cancelMsg) {
        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        cancelMsg = _msgAt(_lastSentIndex());
        vm.deal(address(dispatcher), 0);
        (bool ok,) = _deliverMsg(cancelMsg, 4_000_000);
        assertFalse(ok, "CANCEL retained by LayerZero");
        vm.deal(address(dispatcher), 100 ether);
        relayCursor = endpoint.sentCount();
    }

    function _redeemCommand(uint256 shares_) internal view returns (Command memory) {
        return Command({
            commandId: bytes32(0),
            sequence: 0,
            commandConfigEpoch: 0,
            action: uint8(BusinessAction.REDEEM),
            minExecutionGas: DEFAULT_COMMAND_BUDGET,
            actionData: CrosschainMessages.encodeRedeemAction(address(remoteVault), shares_, 0)
        });
    }

    /// @dev Deliver an authenticated dispatcher -> executor COMMAND_ACK that no real flow would produce.
    function _deliverForgedAck(bytes32 commandId_, uint64 sequence_, CommandResolution resolution_, uint256 nonce_)
        internal
    {
        bytes memory message = CrosschainMessages.encodeCommandAck(
            CommandAck({
                commandId: commandId_,
                sequence: sequence_,
                stateVersion: dispatcher.stateVersion(),
                dispatcherConfigEpoch: dispatcher.commandConfigEpoch(),
                resolution: resolution_,
                valueDeltaSD: 0
            })
        );
        endpoint.deliverLz(
            address(executor),
            REMOTE_EID,
            bytes32(uint256(uint160(address(executor)))),
            keccak256(abi.encode("forged-ack", nonce_)),
            message
        );
    }

    function _countLogs(Vm.Log[] memory logs_, address emitter_, bytes32 topic0_) internal pure returns (uint256 n) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == emitter_ && logs_[i].topics.length != 0 && logs_[i].topics[0] == topic0_) ++n;
        }
    }

    function _assertMirrorsMatchDispatcher(string memory label_) internal view {
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), dispatcher.nextCommandSequence(), label_);
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), dispatcher.commandConfigEpoch(), label_);
    }

    // ---------------------------------------------------------------------
    // The twin of the CCIP stale-cancel defect
    // ---------------------------------------------------------------------

    /// @notice IL-8594 scenario on Stargate: a CANCEL_COMMAND retained by LayerZero, executed after the abandon and
    ///         after the replacement was BUILT at the same sequence (but before it executed). Before the fence the
    ///         cancel consumed the sequence and its CANCELLED receipt retired the replacement (`SequenceGap`
    ///         forever). Now the cancel is closed without consuming anything, its EXPIRED receipt is ignored, and
    ///         the replacement executes and runs its deposit.
    function testShouldRunTheReplacementWhenARetainedCancelLandsAfterTheReplacementWasBuilt() public {
        _bringUpBothSides();
        _allowRemoteVault();

        (bytes32 c1, uint64 s1) = _failedDeposit(50e6);
        MockLzEndpoint.SentMessage memory cancelMsg = _retainedCancel();

        // Past deadline + COMMAND_EXPIRY_MARGIN the admin abandons as UNUSED (true at that moment).
        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), s1, "sequence not consumed");
        assertEq(dispatcher.nextCommandSequence(), s1, "dispatcher agrees");

        // Capital arrives; the replacement R reuses s1 and is in flight.
        _bridgeToDispatcher(100e6);
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(40e6));
        (,,,, bytes32 r, uint64 sR,) = executor.activeCommand(REMOTE_CHAIN);
        MockLzEndpoint.SentMessage memory rMsg = _msgAt(_lastSentIndex());
        assertEq(sR, s1, "replacement reuses the sequence");
        relayCursor = endpoint.sentCount();

        // Anyone executes the retained (long expired) CANCEL first.
        uint256 ackIndex = endpoint.sentCount();
        vm.recordLogs();
        (bool ok,) = _deliverMsg(cancelMsg, 4_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok, "the stale cancel is consumed");
        assertEq(
            _countLogs(logs, address(dispatcher), StargateCrosschainDispatcher.CancelCommandExpiredIgnored.selector),
            1,
            "CancelCommandExpiredIgnored"
        );
        assertEq(uint8(dispatcher.commandStatus(c1)), uint8(CommandStatus.CANCELLED), "C1 closed");
        assertEq(dispatcher.nextCommandSequence(), s1, "the cancel did NOT consume the replacement's sequence");
        assertEq(endpoint.sentCount(), ackIndex + 1, "one EXPIRED receipt sent");

        // Its receipt reaches the executor and is ignored: R keeps the slot.
        _relayAt(ackIndex);
        assertTrue(_commandSlotActive(), "R keeps the slot");
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.PENDING), "and is still PENDING");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), s1, "mirror untouched");

        // R executes and its deposit runs.
        (ok,) = _deliverMsg(rMsg, 4_000_000);
        assertTrue(ok, "R executes");
        assertEq(uint8(dispatcher.commandStatus(r)), uint8(CommandStatus.SUCCEEDED), "R succeeded");
        assertEq(dispatcher.trackedIdle(), 60e6, "R's deposit ran");
        assertEq(remoteVault.balanceOf(address(dispatcher)), 40e6, "shares received");
        _relayAt(_lastSentIndex()); // R's own receipt
        assertFalse(_commandSlotActive(), "resolved by its own receipt");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    /// @notice Stale RETRY of the abandoned command, executed before R: the expired command is NACKed
    ///         (`CommandExpired`, IL-8255) without consuming the sequence, the executor ignores the NACK (R owns the
    ///         slot) and R runs.
    function testShouldNackAndIgnoreAStaleRetryOfAnAbandonedCommand() public {
        _bringUpBothSides();
        _allowRemoteVault();
        (bytes32 c1, uint64 s1) = _failedDeposit(50e6);

        vm.prank(manager);
        executor.retryCommand(REMOTE_CHAIN);
        MockLzEndpoint.SentMessage memory retryMsg = _msgAt(_lastSentIndex());
        relayCursor = endpoint.sentCount(); // retained: never delivered
        // The retry made the executor wait again; resolve it by the abandon.
        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);

        _bridgeToDispatcher(100e6);
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(40e6));
        (,,,, bytes32 r,,) = executor.activeCommand(REMOTE_CHAIN);
        MockLzEndpoint.SentMessage memory rMsg = _msgAt(_lastSentIndex());
        relayCursor = endpoint.sentCount();

        uint256 nackIndex = endpoint.sentCount();
        (bool ok,) = _deliverMsg(retryMsg, 4_000_000);
        assertTrue(ok, "stale retry consumed");
        assertEq(endpoint.sentCount(), nackIndex + 1, "exactly one packet answered: the NACK");
        assertEq(uint8(dispatcher.commandStatus(c1)), uint8(CommandStatus.FAILED), "expired retry NACKed");
        assertEq(dispatcher.nextCommandSequence(), s1, "sequence not consumed");
        _relayAt(nackIndex); // the NACK reaches the executor and is ignored
        assertTrue(_commandSlotActive(), "R keeps the slot");
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.PENDING), "R still PENDING");

        (ok,) = _deliverMsg(rMsg, 4_000_000);
        assertTrue(ok, "R executes");
        assertEq(uint8(dispatcher.commandStatus(r)), uint8(CommandStatus.SUCCEEDED), "R succeeded");
        assertEq(remoteVault.balanceOf(address(dispatcher)), 40e6, "only R's deposit ran");
    }

    /// @notice The abandoned command's own first delivery retained and executed only after the abandon and R:
    ///         NACK `CommandExpired`, ignored by the executor, R runs.
    function testShouldNackAndIgnoreTheStaleFirstDeliveryOfAnAbandonedCommand() public {
        _bringUpBothSides();
        _allowRemoteVault();
        _bridgeToDispatcher(100e6);

        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(10e6));
        (,,,, bytes32 c1, uint64 s1,) = executor.activeCommand(REMOTE_CHAIN);
        MockLzEndpoint.SentMessage memory c1Msg = _msgAt(_lastSentIndex());
        relayCursor = endpoint.sentCount(); // never delivered
        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);

        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(40e6));
        (,,,, bytes32 r,,) = executor.activeCommand(REMOTE_CHAIN);
        MockLzEndpoint.SentMessage memory rMsg = _msgAt(_lastSentIndex());
        relayCursor = endpoint.sentCount();

        uint256 nackIndex = endpoint.sentCount();
        (bool ok,) = _deliverMsg(c1Msg, 4_000_000);
        assertTrue(ok, "stale first delivery consumed");
        assertEq(uint8(dispatcher.commandStatus(c1)), uint8(CommandStatus.FAILED), "expired first delivery NACKed");
        assertEq(dispatcher.nextCommandSequence(), s1, "sequence not consumed");
        _relayAt(nackIndex);
        assertTrue(_commandSlotActive(), "NACK ignored, R keeps the slot");

        (ok,) = _deliverMsg(rMsg, 4_000_000);
        assertTrue(ok, "R executes");
        assertEq(uint8(dispatcher.commandStatus(r)), uint8(CommandStatus.SUCCEEDED), "R succeeded");
        assertEq(remoteVault.balanceOf(address(dispatcher)), 40e6, "only R's deposit ran");
    }

    // ---------------------------------------------------------------------
    // Boundary
    // ---------------------------------------------------------------------

    /// @notice A cancel AT the deadline is a normal cancel (sequence consumed, CANCELLED receipt); one second later it
    ///         is EXPIRED (nothing consumed, slot released by the receipt).
    function testShouldTreatACancelAtTheDeadlineAsNormalAndOneSecondLaterAsExpired() public {
        _bringUpBothSides();
        _allowRemoteVault();

        (bytes32 c1, uint64 s1) = _failedDeposit(50e6);
        vm.warp(CrosschainMessages.commandDeadline(c1));
        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayAll();
        assertEq(dispatcher.nextCommandSequence(), s1 + 1, "at the deadline: sequence consumed");
        assertFalse(_commandSlotActive(), "CANCELLED receipt freed the slot");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), s1 + 1, "mirror advanced");

        (bytes32 c2, uint64 s2) = _failedDeposit(50e6);
        vm.warp(CrosschainMessages.commandDeadline(c2) + 1);
        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit StargateCrosschainDispatcher.CancelCommandExpiredIgnored(c2, s2);
        _relayNext(); // CANCEL -> dispatcher
        vm.expectEmit(false, false, false, true, address(executor));
        emit StargateExecutorAccountingLib.CommandExpiryReleased(REMOTE_CHAIN, c2, s2);
        _relayNext(); // EXPIRED receipt -> executor
        assertEq(dispatcher.nextCommandSequence(), s2, "past the deadline: sequence NOT consumed");
        assertEq(uint8(dispatcher.commandStatus(c2)), uint8(CommandStatus.CANCELLED), "closed");
        assertFalse(_commandSlotActive(), "EXPIRED receipt freed the slot");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), s2, "mirror unchanged");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    /// @notice The release is a slot release like the CANCELLED/SUCCEEDED receipts and abandon: it bumps the
    ///         accounting epoch, so a balance proposal armed over the blocked lane is invalidated the same way.
    function testShouldBumpTheAccountingEpochWhenAnExpiredReceiptReleasesTheSlot() public {
        _bringUpBothSides();
        _allowRemoteVault();
        (bytes32 c1,) = _failedDeposit(50e6);
        vm.warp(CrosschainMessages.commandDeadline(c1) + 1);
        uint64 epochBefore = executor.accountingEpoch(REMOTE_CHAIN);
        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayAll();
        assertFalse(_commandSlotActive(), "slot released");
        assertEq(executor.accountingEpoch(REMOTE_CHAIN), epochBefore + 1, "accounting epoch bumped once");
    }

    // ---------------------------------------------------------------------
    // Executor-side guards of the EXPIRED receipt
    // ---------------------------------------------------------------------

    /// @notice The slot holds a replacement R at the abandoned command's sequence: an EXPIRED receipt naming the
    ///         abandoned C1 is ignored (surfaced as `CommandReceiptConsumedWithoutCommand`), R keeps the slot.
    function testShouldIgnoreAnExpiredReceiptWhenTheSlotHoldsAReplacement() public {
        _bringUpBothSides();
        _allowRemoteVault();
        (bytes32 c1, uint64 s1) = _failedDeposit(50e6);
        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(10e6));
        (,,,, bytes32 r,,) = executor.activeCommand(REMOTE_CHAIN);
        relayCursor = endpoint.sentCount();
        uint64 epochBefore = executor.accountingEpoch(REMOTE_CHAIN);

        vm.expectEmit(false, false, false, true, address(executor));
        emit StargateExecutorAccountingLib.CommandReceiptConsumedWithoutCommand(
            REMOTE_CHAIN, c1, dispatcher.stateVersion()
        );
        _deliverForgedAck(c1, s1, CommandResolution.EXPIRED, 1);
        assertTrue(_commandSlotActive(), "R keeps the slot");
        (,,,, bytes32 stillActive,,) = executor.activeCommand(REMOTE_CHAIN);
        assertEq(stillActive, r, "and it is R");
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.PENDING), "R untouched");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), s1, "mirror kept");
        assertEq(executor.accountingEpoch(REMOTE_CHAIN), epochBefore, "no epoch bump");
    }

    /// @notice An EXPIRED receipt frees the slot only while the command is FAILED. Forged for the PENDING active
    ///         command (a state a real dispatcher cannot produce): ignored, nothing moves, the command still runs.
    function testShouldIgnoreAnExpiredReceiptWhenTheActiveCommandIsNotFailed() public {
        _bringUpBothSides();
        _allowRemoteVault();
        _bridgeToDispatcher(100e6);
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(10e6));
        (,,,, bytes32 c, uint64 s,) = executor.activeCommand(REMOTE_CHAIN);
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.PENDING), "PENDING");

        vm.expectEmit(false, false, false, true, address(executor));
        emit StargateExecutorAccountingLib.CommandReceiptConsumedWithoutCommand(
            REMOTE_CHAIN, c, dispatcher.stateVersion()
        );
        _deliverForgedAck(c, s, CommandResolution.EXPIRED, 2);
        assertTrue(_commandSlotActive(), "slot kept");
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.PENDING), "status kept");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), s, "mirror kept");

        _relayAll(); // the command itself still runs normally
        assertEq(uint8(dispatcher.commandStatus(c)), uint8(CommandStatus.SUCCEEDED));
        assertFalse(_commandSlotActive());
    }

    /// @notice An EXPIRED receipt that names the active command's id with a DIFFERENT sequence frees nothing and, unlike
    ///         a SUCCEEDED/CANCELLED receipt, does not revert: it is ignored.
    function testShouldIgnoreAnExpiredReceiptWithTheWrongSequence() public {
        _bringUpBothSides();
        _allowRemoteVault();
        (bytes32 c1, uint64 s1) = _failedDeposit(50e6);
        uint64 epochBefore = executor.accountingEpoch(REMOTE_CHAIN);

        _deliverForgedAck(c1, s1 + 1, CommandResolution.EXPIRED, 3);
        assertTrue(_commandSlotActive(), "slot kept");
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED), "still FAILED");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), s1, "mirror kept");
        assertEq(executor.accountingEpoch(REMOTE_CHAIN), epochBefore, "no epoch bump");
    }

    // ---------------------------------------------------------------------
    // Empty-revert business failures (IL-8625 gas budget)
    // ---------------------------------------------------------------------

    /// @notice IL-8625. A deterministic business failure whose revert data is EMPTY (REQUEST_SHARES aimed at a
    ///         tracked plain ERC-4626 that has no `UniversalReader.read`) is a business failure like any other: at the
    ///         command's budget the dispatcher records FAILED and sends the NACK, so the manager frees the lane in
    ///         the same block (CANCEL inside the window consumes the sequence) instead of waiting for the TTL.
    function testShouldNackAnEmptyRevertCommandAtOnceAndLetTheManagerCancelInTheSameBlock() public {
        _bringUpBothSides();
        _allowRemoteVault();
        _bridgeToDispatcher(100e6);
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(50e6));
        _relayAll();
        assertEq(remoteVault.balanceOf(address(dispatcher)), 50e6, "healthy position opened");
        assertFalse(_commandSlotActive(), "slot free");

        uint256 t0 = block.timestamp;
        vm.prank(manager);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.REQUEST_SHARES),
                minExecutionGas: DEFAULT_COMMAND_BUDGET,
                actionData: CrosschainMessages.encodeRequestSharesAction(
                    address(0xBEEF), address(remoteVault), 10e6, type(uint256).max
                )
            })
        );
        (,,,, bytes32 commandId, uint64 s,) = executor.activeCommand(REMOTE_CHAIN);
        MockLzEndpoint.SentMessage memory m = _msgAt(_lastSentIndex());
        relayCursor = endpoint.sentCount();
        uint256 sentBefore = endpoint.sentCount();

        (bool ok,) = _deliverMsg(m, 4_000_000);
        assertTrue(ok, "an empty-revert business failure is a clean delivery at the budget");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
        assertEq(endpoint.sentCount(), sentBefore + 1, "NACK sent");
        _relayAll(); // NACK -> executor
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED), "NACK applied");

        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayAll(); // CANCEL -> dispatcher (inside the window) -> CANCELLED -> executor
        assertFalse(_commandSlotActive(), "slot freed by the manager, no admin, no TTL wait");
        assertEq(dispatcher.nextCommandSequence(), s + 1, "inside the window the cancel consumes the sequence");
        assertEq(block.timestamp, t0, "no waiting");

        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _redeemCommand(50e6));
        _relayAll();
        assertEq(remoteVault.balanceOf(address(dispatcher)), 0, "redeemed right after");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    /// @notice Same class, second trigger: UPDATE_VAULTS naming a contract without `asset()` (here the ERC-20 itself)
    ///         reverts with empty data and is a business failure at the budget (IL-8625): FAILED + NACK.
    function testShouldNackUpdateVaultsWithANonVaultAtTheBudget() public {
        _bringUpBothSides();
        address[] memory vaults = new address[](1);
        vaults[0] = address(usdc);
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, vaults);
        (,,,, bytes32 commandId,,) = executor.activeCommand(REMOTE_CHAIN);
        MockLzEndpoint.SentMessage memory m = _msgAt(_lastSentIndex());
        uint256 sentBefore = endpoint.sentCount();

        (bool ok,) = _deliverMsg(m, 4_000_000);
        assertTrue(ok, "clean delivery");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
        assertEq(endpoint.sentCount(), sentBefore + 1, "NACK sent");
    }

    // ---------------------------------------------------------------------
    // Late receipt of an in-window cancel, clock lag, re-send, UPDATE_VAULTS
    // ---------------------------------------------------------------------

    /// @notice What remains of "a late receipt retires a dead replacement" (Stargate twin of the CCIP test): a cancel
    ///         that ran INSIDE the window consumed S and its ACK is still in transit when the admin wrongly abandons
    ///         the command as UNUSED. The replacement at S is dead on arrival (the dispatcher is at S + 1); the late
    ///         ACK is adopted (`CommandReceiptAdopted`), retires the replacement and realigns the mirrors.
    function testShouldStillRetireADeadReplacementWhenAnInWindowCancelReceiptIsInTransit() public {
        _bringUpBothSides();
        _allowRemoteVault();
        (bytes32 c1, uint64 s) = _failedDeposit(50e6);

        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayAt(_lastSentIndex()); // the cancel runs inside the window and consumes S
        uint256 ackIndex = _lastSentIndex(); // its CANCELLED receipt stays in transit
        relayCursor = endpoint.sentCount();
        assertEq(dispatcher.nextCommandSequence(), s + 1, "the in-window cancel consumed S");

        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED); // wrong declaration
        _bridgeToDispatcher(100e6);
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(40e6));
        (,,,, bytes32 r, uint64 sR,) = executor.activeCommand(REMOTE_CHAIN);
        assertEq(sR, s, "replacement stamped with the abandoned sequence");
        uint256 rPacket = _lastSentIndex();
        relayCursor = endpoint.sentCount();

        vm.expectEmit(false, false, false, true, address(executor));
        emit StargateExecutorAccountingLib.CommandReceiptAdopted(
            REMOTE_CHAIN, c1, s, dispatcher.commandConfigEpoch(), r
        );
        _relayAt(ackIndex);
        assertFalse(_commandSlotActive(), "the dead replacement was retired");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), s + 1, "mirror repaired by the receipt");
        _assertMirrorsMatchDispatcher("mirrors realigned");

        MockLzEndpoint.SentMessage memory m = _msgAt(rPacket);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.SequenceGap.selector, s + 1, s));
        endpoint.deliverLz(
            address(dispatcher), LOCAL_EID, bytes32(uint256(uint160(address(dispatcher)))), m.guid, m.message
        );
        assertEq(uint8(dispatcher.commandStatus(r)), uint8(CommandStatus.NONE), "the replacement never ran");
    }

    /// @dev Abandon with a retained cancel, replacement built, then the retained cancel runs on a dispatcher whose
    ///      clock is either exactly AT the command deadline (`clockAtDeadline_`) or one second past it. The cancel is
    ///      fenced iff the dispatcher clock is strictly past the deadline.
    function _lagScenario(bool clockAtDeadline_)
        internal
        returns (bytes32 c1, bytes32 r, MockLzEndpoint.SentMessage memory rMsg, uint64 s)
    {
        _bringUpBothSides();
        _allowRemoteVault();
        (c1, s) = _failedDeposit(50e6);
        MockLzEndpoint.SentMessage memory cancelMsg = _retainedCancel();
        _abandon(ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED);
        _bridgeToDispatcher(100e6);
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(40e6));
        (,,,, r,,) = executor.activeCommand(REMOTE_CHAIN);
        rMsg = _msgAt(_lastSentIndex());
        relayCursor = endpoint.sentCount();

        uint256 executorNow = block.timestamp;
        uint256 gap = executorNow - CrosschainMessages.commandDeadline(c1);
        uint256 lag = clockAtDeadline_ ? gap : gap - 1;
        vm.warp(executorNow - lag); // dispatcher clock
        (bool ok,) = _deliverMsg(cancelMsg, 4_000_000);
        assertTrue(ok, "the retained cancel is consumed");
        vm.warp(executorNow);
    }

    /// @notice One second short of the gap the dispatcher clock is still past the deadline: fenced, R runs.
    function testShouldStayFencedWhenTheDispatcherClockLagsOneSecondShortOfTheGap() public {
        (bytes32 c1, bytes32 r, MockLzEndpoint.SentMessage memory rMsg, uint64 s) = _lagScenario(false);
        assertEq(dispatcher.nextCommandSequence(), s, "fenced");
        assertEq(uint8(dispatcher.commandStatus(c1)), uint8(CommandStatus.CANCELLED));
        (bool ok,) = _deliverMsg(rMsg, 4_000_000);
        assertTrue(ok, "R executes");
        assertEq(uint8(dispatcher.commandStatus(r)), uint8(CommandStatus.SUCCEEDED), "R succeeded");
    }

    /// @notice KNOWN LIMITATION (accepted IL-8591 residual, runbook rule in contracts/crosschain/stargate/README.md):
    ///         a dispatcher clock at or before the command deadline when the retained cancel runs defeats the fence:
    ///         the cancel consumes R's sequence and its CANCELLED receipt retires the still-PENDING R. Operators avoid
    ///         it by executing ABANDON_COMMAND_SEQUENCE_UNUSED only once the dispatcher chain's safe block is past the
    ///         deadline.
    function testKnownLimitationDispatcherClockAtOrBeforeTheDeadlineReopensTheDefectOnTheAdminAbandonPath() public {
        (bytes32 c1, bytes32 r, MockLzEndpoint.SentMessage memory rMsg, uint64 s) = _lagScenario(true);
        assertEq(dispatcher.nextCommandSequence(), s + 1, "stale cancel consumed R's sequence");
        assertEq(uint8(dispatcher.commandStatus(c1)), uint8(CommandStatus.CANCELLED));
        _relayAt(_lastSentIndex()); // its CANCELLED receipt retires R
        assertFalse(_commandSlotActive(), "R retired by the late CANCELLED receipt");
        (bool ok, bytes memory ret) = _deliverMsg(rMsg, 4_000_000);
        assertFalse(ok, "R can never execute");
        assertEq(bytes4(ret), CrosschainErrors.SequenceGap.selector);
        assertEq(uint8(dispatcher.commandStatus(r)), uint8(CommandStatus.NONE), "R never ran");
    }

    /// @notice The EXPIRED receipt of the first cancel is still in transit when the manager re-sends the cancel (past
    ///         the IL-8579 cooldown): the re-send is idempotent on the dispatcher (no second receipt) and the first
    ///         receipt still frees the slot when it lands.
    function testShouldFreeTheSlotFromTheFirstExpiredReceiptEvenAfterAResentCancel() public {
        _bringUpBothSides();
        _allowRemoteVault();
        (bytes32 c1, uint64 s) = _failedDeposit(50e6);
        vm.warp(CrosschainMessages.commandDeadline(c1) + 1);

        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayNext(); // the cancel runs: closed, EXPIRED receipt sent
        uint256 receiptIndex = _lastSentIndex();
        relayCursor = endpoint.sentCount();
        assertEq(dispatcher.nextCommandSequence(), s, "sequence not consumed");
        assertTrue(_commandSlotActive(), "slot held until the receipt lands");

        vm.warp(block.timestamp + CrosschainConstants.CANCEL_COMMAND_COOLDOWN);
        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        uint256 resentIndex = _lastSentIndex();
        uint256 sentBefore = endpoint.sentCount();
        _relayAt(resentIndex);
        assertEq(endpoint.sentCount(), sentBefore, "the re-sent cancel sent no second receipt");
        assertTrue(_commandSlotActive(), "slot still held");

        _relayAt(receiptIndex);
        relayCursor = endpoint.sentCount();
        assertFalse(_commandSlotActive(), "the first EXPIRED receipt freed the slot");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    /// @notice A FAILED UPDATE_VAULTS is released through EXPIRED: neither epoch moves (the update was never applied),
    ///         and the next UPDATE_VAULTS at the same sequence succeeds and advances both.
    function testShouldReleaseAFailedUpdateVaultsThroughExpiredWithBothEpochsUnchanged() public {
        _bringUpBothSides();
        _allowRemoteVault();
        uint64 epochBefore = dispatcher.commandConfigEpoch();
        uint64 s = dispatcher.nextCommandSequence();
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), epochBefore, "epochs in lockstep");

        MockRemoteVault wrongAsset = new MockRemoteVault(IERC20(address(remoteVault)), "Wrong", "wUSDC");
        address[] memory vaults = new address[](1);
        vaults[0] = address(wrongAsset);
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, vaults);
        (,,,, bytes32 id,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();
        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.FAILED), "UPDATE_VAULTS NACKed");
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED), "NACK applied");

        vm.warp(CrosschainMessages.commandDeadline(id) + 1);
        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayAll();
        assertFalse(_commandSlotActive(), "slot released by EXPIRED");
        assertEq(dispatcher.commandConfigEpoch(), epochBefore, "dispatcher epoch unchanged");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), epochBefore, "executor epoch unchanged");
        assertEq(dispatcher.nextCommandSequence(), s, "sequence unconsumed");

        MockRemoteVault another = new MockRemoteVault(IERC20(address(usdc)), "Another", "aUSDC");
        vaults[0] = address(another);
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, vaults);
        _relayAll();
        assertFalse(_commandSlotActive(), "next UPDATE_VAULTS resolved");
        assertEq(dispatcher.commandConfigEpoch(), epochBefore + 1, "dispatcher epoch advanced");
        assertEq(dispatcher.nextCommandSequence(), s + 1, "at the reused sequence");
        _assertMirrorsMatchDispatcher("and the executor followed");
    }
}
