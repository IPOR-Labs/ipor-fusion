// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {
    CcipExecutorCommandLib,
    CcipExecutorCommandState,
    ReceiptIgnoreReason
} from "../../contracts/crosschain/ccip/lib/CcipExecutorCommandLib.sol";
import {
    CommandStatus,
    CommandResolution,
    CrosschainConstants
} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @dev Thin storage owner so the library's `self`-taking functions can be driven directly. The CCIP
///      end-to-end harness delivers command receipts synchronously, which closes the window this test
///      needs; the production lane queues them (`flushResponse`), so the window is real there.
contract CommandStateHarness {
    using CcipExecutorCommandLib for CcipExecutorCommandState;

    CcipExecutorCommandState internal _s;
    mapping(bytes32 id => uint32 words) internal _words;

    function initializeRoute(uint256 chainId_) external {
        _s.initializeRoute(chainId_);
    }

    function build(uint256 chainId_, bool advancesConfig_, uint256 nonce_) external returns (bytes32 id, uint64 seq) {
        (id, seq) = (bytes32(0), 0);
        // `action`/`actionData` are irrelevant to the lifecycle under test.
        id = _s.build(
            _words,
            CcipExecutorCommandLib.BuildParams({
                executor: address(this),
                chainId: chainId_,
                action: 1,
                actionData: "",
                advancesConfig: advancesConfig_,
                nonce: nonce_,
                laneGas: DEFAULT_COMMAND_BUDGET + 2_000_000,
                extra: "",
                requestedBudget: 0
            })
        ).commandId;
        seq = _s.commands[id].sequence;
    }

    function fail(uint256 chainId_, bytes32 id_, uint64 sequence_) external returns (ReceiptIgnoreReason) {
        return _s.fail(chainId_, id_, sequence_);
    }

    function requireFailed(uint256 chainId_, bytes32 id_, bool cancel_) external {
        _s.requireFailed(chainId_, id_, cancel_);
    }

    function lastCancelAt(bytes32 id_) external view returns (uint64) {
        return _s.lastCancelAt[id_];
    }

    function markRetrying(bytes32 id_) external {
        _s.markRetrying(id_);
    }

    function acknowledge(
        uint256 chainId_,
        bytes32 id_,
        uint64 sequence_,
        CommandResolution resolution_,
        uint64 dispatcherConfigEpoch_
    ) external returns (ReceiptIgnoreReason) {
        return _s.acknowledge(chainId_, id_, sequence_, uint8(resolution_), dispatcherConfigEpoch_);
    }

    function acknowledgeRaw(uint256 chainId_, bytes32 id_, uint64 sequence_, uint8 resolution_, uint64 epoch_)
        external
        returns (ReceiptIgnoreReason)
    {
        return _s.acknowledge(chainId_, id_, sequence_, resolution_, epoch_);
    }

    function commandConfigEpoch(uint256 chainId_) external view returns (uint64) {
        return _s.commandConfigEpoch[chainId_];
    }

    function status(bytes32 id_) external view returns (CommandStatus) {
        return _s.status[id_];
    }

    function activeCommand(uint256 chainId_) external view returns (bytes32) {
        return _s.active[chainId_];
    }

    function nextCommandSequence(uint256 chainId_) external view returns (uint64) {
        return _s.nextCommandSequence[chainId_];
    }

    function abandon(uint256 chainId_, bool sequenceConsumed_) external returns (bytes32 id, uint64 seq) {
        return _s.abandon(chainId_, sequenceConsumed_);
    }

    function realign(uint256 chainId_, uint256 arg_) external {
        _s.realign(chainId_, arg_);
    }

    function commandSequence(bytes32 id_) external view returns (uint64) {
        return _s.commands[id_].sequence;
    }
}

/// @title CcipExecutorCommandLibTest
/// @notice Regression cover for the CCIP half of
///         `config_epoch_desync_via_retry_clearing_in_flight_cancel`.
/// @dev The CCIP transport had the mirror-image of the Stargate defect: `markRetrying` did NOT clear
///      `cancelRequested`, and `acknowledge` used that stale flag as the sole discriminator between a
///      success and a cancel resolution. With the executor->dispatcher lane explicitly out-of-order, a
///      RETRY could be applied before the CANCEL, so the dispatcher advanced its epoch while the executor
///      — reading the stale flag — recorded CANCELLED and skipped the advance. Same root cause, opposite
///      direction: a local flag cannot describe a receipt.
contract CcipExecutorCommandLibTest is Test {
    uint256 internal constant CHAIN = 8453;

    CommandStateHarness internal h;

    function setUp() public {
        h = new CommandStateHarness();
        h.initializeRoute(CHAIN);
    }

    function _failedConfigCommand() internal returns (bytes32 id, uint64 seq) {
        (id, seq) = h.build(CHAIN, true, 1);
        h.fail(CHAIN, id, seq);
        assertEq(uint8(h.status(id)), uint8(CommandStatus.FAILED));
    }

    function testShouldRejectRetryWhileCancelIsInFlight() public {
        (bytes32 id,) = _failedConfigCommand();

        h.requireFailed(CHAIN, id, true); // cancel armed

        vm.expectRevert(abi.encodeWithSelector(CcipExecutorCommandLib.CancelInFlight.selector, CHAIN, id));
        h.requireFailed(CHAIN, id, false); // retry refused
    }

    function testShouldIgnoreARepeatNackForAnAlreadyFailedCommand() public {
        (bytes32 id, uint64 seq) = h.build(CHAIN, false, 1);

        ReceiptIgnoreReason first = h.fail(CHAIN, id, seq);
        assertEq(uint8(first), uint8(ReceiptIgnoreReason.NONE), "first NACK applied");
        assertEq(uint8(h.status(id)), uint8(CommandStatus.FAILED), "FAILED after first NACK");

        // A duplicate NACK for the same id and sequence reaches the FAILED branch and is absorbed.
        ReceiptIgnoreReason second = h.fail(CHAIN, id, seq);
        assertEq(uint8(second), uint8(ReceiptIgnoreReason.ALREADY_RESOLVED), "repeat NACK ignored");
        assertEq(uint8(h.status(id)), uint8(CommandStatus.FAILED), "status stays FAILED");
    }

    function testShouldStillAllowAnOrdinaryRetry() public {
        (bytes32 id,) = _failedConfigCommand();

        h.requireFailed(CHAIN, id, false); // no cancel outstanding: the retry path is untouched
        h.markRetrying(id);
        assertEq(uint8(h.status(id)), uint8(CommandStatus.PENDING));
    }

    function testShouldAllowRepeatedCancelOnlyAfterCooldown() public {
        (bytes32 id,) = _failedConfigCommand();

        h.requireFailed(CHAIN, id, true);
        uint256 sentAt = block.timestamp;

        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorCommandLib.CancelCooldown.selector,
                CHAIN,
                id,
                sentAt + CrosschainConstants.CANCEL_COMMAND_COOLDOWN
            )
        );
        h.requireFailed(CHAIN, id, true);

        vm.warp(sentAt + CrosschainConstants.CANCEL_COMMAND_COOLDOWN - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorCommandLib.CancelCooldown.selector,
                CHAIN,
                id,
                sentAt + CrosschainConstants.CANCEL_COMMAND_COOLDOWN
            )
        );
        h.requireFailed(CHAIN, id, true);

        vm.warp(sentAt + CrosschainConstants.CANCEL_COMMAND_COOLDOWN);
        h.requireFailed(CHAIN, id, true); // a lost cancel can be re-sent once the cooldown has passed
        assertEq(h.lastCancelAt(id), sentAt + CrosschainConstants.CANCEL_COMMAND_COOLDOWN, "cooldown restarts");
    }

    /// @notice The CCIP desync itself: a cancel is armed, but the dispatcher applied the RETRY first and
    ///         reports SUCCEEDED. The receipt is authoritative — the stale local flag must not turn a
    ///         success into a CANCELLED record, nor skip the epoch the dispatcher actually committed.
    function testShouldTrustTheReceiptOverAStaleCancelFlag() public {
        (bytes32 id, uint64 seq) = _failedConfigCommand();
        uint64 epochBefore = h.commandConfigEpoch(CHAIN);

        h.requireFailed(CHAIN, id, true); // cancel armed and still in flight
        h.markRetrying(id);

        // The dispatcher applied the retry and advanced its epoch.
        ReceiptIgnoreReason reason = h.acknowledge(CHAIN, id, seq, CommandResolution.SUCCEEDED, epochBefore + 1);

        assertEq(uint8(reason), uint8(ReceiptIgnoreReason.NONE), "receipt applied");
        assertEq(uint8(h.status(id)), uint8(CommandStatus.SUCCEEDED), "resolution comes from the receipt");
        assertEq(h.commandConfigEpoch(CHAIN), epochBefore + 1, "executor mirrors the epoch the dispatcher committed");
        assertEq(h.activeCommand(CHAIN), bytes32(0), "slot freed");
    }

    /// @notice The converse: a genuine cancel resolution must not advance the epoch, even though the
    ///         command was flagged as a config update.
    function testShouldNotAdvanceEpochOnACancelResolution() public {
        (bytes32 id, uint64 seq) = _failedConfigCommand();
        uint64 epochBefore = h.commandConfigEpoch(CHAIN);

        h.requireFailed(CHAIN, id, true);
        h.acknowledge(CHAIN, id, seq, CommandResolution.CANCELLED, epochBefore);

        assertEq(uint8(h.status(id)), uint8(CommandStatus.CANCELLED), "recorded as cancelled");
        assertEq(h.commandConfigEpoch(CHAIN), epochBefore, "no epoch committed for work never applied");
    }

    /// @notice An out-of-range resolution byte must be ignored, not decoded into a bogus enum. The
    ///         receipt lane must never revert, so this is an ignore reason rather than a panic.
    function testShouldIgnoreAnOutOfRangeResolutionByte() public {
        (bytes32 id, uint64 seq) = _failedConfigCommand();
        uint64 epochBefore = h.commandConfigEpoch(CHAIN);

        ReceiptIgnoreReason reason = h.acknowledgeRaw(CHAIN, id, seq, 7, epochBefore + 1);

        assertEq(uint8(reason), uint8(ReceiptIgnoreReason.INVALID_RESOLUTION), "ignored, not applied");
        assertEq(uint8(h.status(id)), uint8(CommandStatus.FAILED), "command untouched");
        assertEq(h.commandConfigEpoch(CHAIN), epochBefore, "no epoch committed");
    }

    /// @notice A divergence between the executor's expectation and the dispatcher's reported epoch is
    ///         realigned to the dispatcher and surfaced, rather than bricking the ordered lane.
    function testShouldResyncAndSurfaceAnUnexpectedDispatcherEpoch() public {
        (bytes32 id, uint64 seq) = _failedConfigCommand();
        uint64 epochBefore = h.commandConfigEpoch(CHAIN);

        vm.expectEmit(true, false, false, true, address(h));
        emit CcipExecutorCommandLib.ConfigEpochResynced(CHAIN, epochBefore + 1, epochBefore + 7);
        h.acknowledge(CHAIN, id, seq, CommandResolution.SUCCEEDED, epochBefore + 7);

        assertEq(h.commandConfigEpoch(CHAIN), epochBefore + 7, "mirror follows the authoritative value");
    }

    // ---------------------------------------------------------------------
    // `no_recovery_path_for_stuck_pending_command_bricks_command_lane` (CCIP half)
    // ---------------------------------------------------------------------

    /// @notice `active[chainId]` was cleared nowhere but `acknowledge`, and `build` refuses while it is
    ///         set, so a receipt the lane never applies froze every later command for that chain. On this
    ///         transport that is worse than on Stargate: `acknowledgeReceipt` NEVER reverts, so an
    ///         ignored receipt is simply gone — there is no redelivery to hope for.
    function testShouldFreeACommandSlotWhoseReceiptWasIgnored() public {
        (bytes32 id, uint64 seq) = _pendingCommand();

        // A receipt bound to the wrong sequence is ignored, not retried: the slot is now terminal.
        ReceiptIgnoreReason reason = h.acknowledge(CHAIN, id, seq + 1, CommandResolution.SUCCEEDED, 1);
        assertEq(uint8(reason), uint8(ReceiptIgnoreReason.SEQUENCE_MISMATCH), "receipt dropped");
        assertEq(h.activeCommand(CHAIN), id, "slot still occupied");

        vm.expectRevert(abi.encodeWithSelector(CcipExecutorCommandLib.ActiveCommandExists.selector, CHAIN, id));
        h.build(CHAIN, false, 99);

        _abandonExpired(true);

        assertEq(h.activeCommand(CHAIN), bytes32(0), "slot freed");
        assertEq(uint8(h.status(id)), uint8(CommandStatus.CANCELLED), "abandoned command is terminal");
        h.build(CHAIN, false, 99); // the lane works again
    }

    /// @notice The abandoned command must not be resolvable afterwards. Its receipt names a command that
    ///         no longer owns the slot, so applying it would delete the REPLACEMENT's slot and advance the
    ///         sequence past a command that is still outstanding.
    function testShouldNotLetAnAbandonedCommandsReceiptResolveItsReplacement() public {
        (bytes32 abandoned, uint64 abandonedSeq) = _pendingCommand();
        _abandonExpired(true);

        (bytes32 replacement,) = h.build(CHAIN, false, 77);
        uint64 sequenceBefore = h.nextCommandSequence(CHAIN);

        ReceiptIgnoreReason reason = h.acknowledge(CHAIN, abandoned, abandonedSeq, CommandResolution.SUCCEEDED, 1);

        assertEq(uint8(reason), uint8(ReceiptIgnoreReason.ALREADY_RESOLVED), "stale receipt ignored");
        assertEq(h.activeCommand(CHAIN), replacement, "replacement still owns the slot");
        assertEq(h.nextCommandSequence(CHAIN), sequenceBefore, "sequence not advanced past an outstanding command");
    }

    /// @notice The dispatcher advances its sequence on BOTH a success and a cancel. The executor cannot
    ///         observe which happened — the receipt that would have said so is the one that was lost — so
    ///         the rescue admin declares it, and both declarations must be honoured exactly.
    function testShouldApplyTheDeclaredSequenceOutcomeOnAbandon() public {
        _pendingCommand();
        uint64 consumedBefore = h.nextCommandSequence(CHAIN);
        _abandonExpired(true);
        assertEq(h.nextCommandSequence(CHAIN), consumedBefore + 1, "mirror followed the dispatcher's advance");

        h.build(CHAIN, false, 5);
        uint64 unusedBefore = h.nextCommandSequence(CHAIN);
        _abandonExpired(false);
        assertEq(h.nextCommandSequence(CHAIN), unusedBefore, "sequence reused when the dispatcher never ran it");
    }

    function testShouldRejectAbandonWhenTheCommandSlotIsFree() public {
        h.initializeRoute(CHAIN);
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorCommandLib.NoStuckCommand.selector, CHAIN));
        h.abandon(CHAIN, true);
    }

    // ---------------------------------------------------------------------
    // IL-7970 — late-receipt adoption and the timelocked realign
    // ---------------------------------------------------------------------
    // These four live at library level because the CCIP end-to-end harness delivers command receipts
    // synchronously (`MockCcipRouter.ccipSend` calls `ccipReceive` inline), so a receipt cannot be held
    // in flight across an `abandon` there without going through the dispatcher's own response queue.
    // `CcipCommandLaneRealignTest` covers the queued form end to end; these cover the library's own
    // branch table directly, including the ones that queue cannot reach (a realign to an arbitrary pair).

    /// @notice A receipt for a command that no longer owns the slot is authenticated dispatcher state:
    ///         at or above the mirror it carries a resolution the mirror never accounted for (the abandon
    ///         that freed the slot declared `sequenceConsumed = false` from no observation), so its
    ///         counters are adopted. The same receipt replayed is then below the mirror and stays ignored.
    function testShouldAdoptAReceiptAtOrAboveTheMirrorAndIgnoreOneBelow() public {
        (bytes32 id, uint64 seq) = _pendingCommand();
        _abandonExpired(false); // UNUSED: the mirror stays at `seq`
        assertEq(h.nextCommandSequence(CHAIN), seq, "mirror parked on the abandoned sequence");

        ReceiptIgnoreReason reason = h.acknowledge(CHAIN, id, seq, CommandResolution.SUCCEEDED, 1);

        assertEq(uint8(reason), uint8(ReceiptIgnoreReason.NONE), "late receipt adopted");
        assertEq(h.nextCommandSequence(CHAIN), seq + 1, "mirror follows the dispatcher past the resolved sequence");
        assertEq(uint8(h.status(id)), uint8(CommandStatus.SUCCEEDED), "resolution taken from the receipt");

        // Replay: now strictly below the mirror, so it must change nothing.
        ReceiptIgnoreReason replay = h.acknowledge(CHAIN, id, seq, CommandResolution.SUCCEEDED, 1);
        assertEq(uint8(replay), uint8(ReceiptIgnoreReason.ALREADY_RESOLVED), "duplicate ignored");
        assertEq(h.nextCommandSequence(CHAIN), seq + 1, "mirror not advanced twice");
    }

    /// @notice A replacement occupying the slot at a sequence the dispatcher has already consumed can
    ///         never execute — the dispatcher's `nextCommandSequence` is strictly monotonic and past it — so the
    ///         adoption retires it instead of leaving it for a second timelocked abandon.
    function testShouldSupersedeAnActiveReplacementWhoseSequenceTheReceiptConsumed() public {
        (bytes32 c1, uint64 seq) = _pendingCommand();
        _abandonExpired(false);
        (bytes32 c2,) = h.build(CHAIN, false, 77);
        assertEq(h.commandSequence(c2), seq, "replacement reuses the abandoned sequence");
        assertEq(h.activeCommand(CHAIN), c2, "replacement owns the slot");

        vm.expectEmit(true, false, false, true, address(h));
        emit CcipExecutorCommandLib.CommandReceiptAdopted(CHAIN, c1, seq, 1, c2);
        ReceiptIgnoreReason reason = h.acknowledge(CHAIN, c1, seq, CommandResolution.SUCCEEDED, 1);

        assertEq(uint8(reason), uint8(ReceiptIgnoreReason.NONE), "late receipt adopted");
        assertEq(h.activeCommand(CHAIN), bytes32(0), "the doomed replacement was retired");
        assertEq(uint8(h.status(c2)), uint8(CommandStatus.CANCELLED), "and marked terminal");
        assertEq(h.nextCommandSequence(CHAIN), seq + 1, "mirror at the dispatcher's counter");
    }

    /// @notice Adoption writes `sequence + 1`, not `mirror + 1`: after a realign that lowered the mirror,
    ///         a receipt above it must jump the mirror straight to the dispatcher's counter.
    function testShouldAdoptAReceiptAboveTheMirrorAfterARealignDown() public {
        _pendingCommand();
        _abandonExpired(true); // mirror -> 1
        (bytes32 c1, uint64 seq) = h.build(CHAIN, false, 2);
        assertEq(seq, 1, "second command sits at sequence 1");
        _abandonExpired(false); // mirror stays 1, slot free

        // the operator declares the dispatcher is back at 0
        h.realign(CHAIN, (uint256(h.commandConfigEpoch(CHAIN)) << 192) | (uint256(1) << 128) | (uint256(1) << 64));
        assertEq(h.nextCommandSequence(CHAIN), 0, "mirror lowered");

        ReceiptIgnoreReason reason = h.acknowledge(CHAIN, c1, seq, CommandResolution.SUCCEEDED, 1);

        assertEq(uint8(reason), uint8(ReceiptIgnoreReason.NONE), "receipt above the mirror is adopted");
        assertEq(h.nextCommandSequence(CHAIN), seq + 1, "mirror jumped to sequence + 1, not mirror + 1");
    }

    /// @notice The realign is the one writer of these mirrors that can lower them, so it is fenced: a free
    ///         slot (checked at execute time, so an abandon and a realign can be scheduled together) and a
    ///         well-formed `(commandConfigEpoch << 64) | nextCommandSequence` argument.
    function testShouldRealignOnlyWithAFreeSlotAndAWellFormedArg() public {
        (bytes32 id,) = _pendingCommand();

        vm.expectRevert(abi.encodeWithSelector(CcipExecutorCommandLib.ActiveCommandExists.selector, CHAIN, id));
        h.realign(CHAIN, (uint256(5) << 64) | 9);

        _abandonExpired(false);

        uint64 previousSequence = h.nextCommandSequence(CHAIN);
        uint64 previousEpoch = h.commandConfigEpoch(CHAIN);
        uint256 stale = (uint256(previousEpoch + 1) << 192) | (uint256(previousSequence) << 128) | (5 << 64) | 9;
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorCommandLib.RealignStateMoved.selector,
                CHAIN,
                previousSequence,
                previousSequence,
                previousEpoch + 1,
                previousEpoch
            )
        );
        h.realign(CHAIN, stale);

        vm.expectEmit(true, false, false, true, address(h));
        emit CcipExecutorCommandLib.CommandLaneRealigned(CHAIN, previousSequence, 9, previousEpoch, 5);
        h.realign(
            CHAIN, (uint256(previousEpoch) << 192) | (uint256(previousSequence) << 128) | (uint256(5) << 64) | 9
        );

        assertEq(h.nextCommandSequence(CHAIN), 9, "sequence mirror set to the declared value");
        assertEq(h.commandConfigEpoch(CHAIN), 5, "epoch mirror set to the declared value");
    }

    // ---------------------------------------------------------------------
    // IL-8255 — the command TTL fences the abandon
    // ---------------------------------------------------------------------

    /// @notice Every built command carries its own expiry in the high 64 bits of its id, and the low bits
    ///         are still the per-executor hash, so ids stay unique.
    function testShouldStampTheDeadlineIntoTheCommandId() public {
        vm.warp(1_000_000);
        (bytes32 id,) = h.build(CHAIN, false, 1);
        bytes32 hash = keccak256(abi.encode(address(h), CHAIN, "CCIP_COMMAND", uint256(1)));

        assertEq(CrosschainMessages.commandDeadline(id), 1_000_000 + CrosschainConstants.COMMAND_TTL, "deadline");
        assertEq(uint256(id) << 64, uint256(hash) >> 64 << 64, "low 192 bits are the top of the hash");
    }

    /// @notice An abandon executed while the command can still run on the dispatcher would free its sequence
    ///         for a replacement that the still-executable original then supersedes. Both declarations are
    ///         refused up to and including `deadline + COMMAND_EXPIRY_MARGIN`, and accepted one second later.
    function testShouldRejectAbandonUntilTheCommandExpiredOnBothChains() public {
        (bytes32 id,) = _pendingCommand();
        uint256 abandonableAt = CrosschainMessages.commandDeadline(id) + CrosschainConstants.COMMAND_EXPIRY_MARGIN;

        vm.warp(CrosschainMessages.commandDeadline(id) + 1); // expired on the dispatcher's clock, not yet here
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorCommandLib.CommandNotExpired.selector, id, abandonableAt));
        h.abandon(CHAIN, false);

        vm.warp(abandonableAt);
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorCommandLib.CommandNotExpired.selector, id, abandonableAt));
        h.abandon(CHAIN, true);
        assertEq(h.activeCommand(CHAIN), id, "the slot is still held");

        vm.warp(abandonableAt + 1);
        h.abandon(CHAIN, false);
        assertEq(h.activeCommand(CHAIN), bytes32(0), "abandoned once expired on both chains");
    }

    /// @dev A command sitting in the slot awaiting its receipt.
    function _pendingCommand() internal returns (bytes32 id, uint64 seq) {
        h.initializeRoute(CHAIN);
        (id, seq) = h.build(CHAIN, false, 1);
        assertEq(uint8(h.status(id)), uint8(CommandStatus.PENDING), "command pending");
    }

    /// @dev Abandon the active command once it can no longer execute on the dispatcher (IL-8255).
    function _abandonExpired(bool sequenceConsumed_) internal {
        vm.warp(
            CrosschainMessages.commandDeadline(h.activeCommand(CHAIN)) + CrosschainConstants.COMMAND_EXPIRY_MARGIN + 1
        );
        h.abandon(CHAIN, sequenceConsumed_);
    }
}
