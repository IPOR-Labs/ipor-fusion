// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {
    CrosschainConstants,
    MsgType,
    ResolveOutcome,
    ReturnRejectReason
} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

contract CrosschainRecallSafetyTest is CrosschainTestBase {
    bytes32 internal constant RETURN_REJECTED_BY_DISPATCHER_TOPIC =
        keccak256("ReturnRejectedByDispatcher(uint256,bytes32,uint8)");

    event ReturnMetadataApplied(
        uint256 srcChainId,
        bytes32 requestId,
        bytes32 guid,
        uint256 amountSentSD,
        uint256 debitedSD,
        uint256 inFlightCreditSD,
        uint64 stateVersion
    );

    event AuthenticatedMessageDroppedAheadOfFrontier(
        uint256 srcChainId, uint8 msgType, bytes32 recordId, uint64 stateVersion, uint64 frontier
    );

    function setUp() public {
        _baseSetUp();
    }

    function testShouldAllowOnlyOneActiveRecallPerChain() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(60e6, 0);

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.ActiveReturnRequestExists.selector, REMOTE_CHAIN, requestId)
        );
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e6, 0, "");
    }

    function testReturnMetadataAboveAccountingBoundCannotBrickLane() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(100e6, 0);

        _deliverReturnStarted(requestId, RGUID, 150e6, 150e6, 2);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "debit clamped to settled/request bound");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 100e6, "metadata reconciled up to the debit (IL-8293)");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 2, "frontier advanced");
    }

    function testForceSetSettledBlockedWhileRecallAwaitsMetadata() public {
        _readyDispatcher();
        _settle100();
        _requestAssets(40e6, 0);

        uint64 observedVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceSetSettledBalance(
            REMOTE_CHAIN, 60e6, observedVersion, _markFsObs(), false
        );
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.PendingTransfersExist.selector, REMOTE_CHAIN, uint256(1))
        );
        executor.executeForceSetSettledBalance(rescueId, REMOTE_CHAIN, 60e6, observedVersion, fsObs, false);
    }

    function testAtomicRescueCanIncludePendingDebitWithoutDoubleDebit() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);

        uint64 observedVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.startPrank(admin);
        uint256 resolveId =
            executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.DROP_RETURN_METADATA_INCLUDED);
        uint256 settleId = executor.scheduleForceSetSettledBalance(
            REMOTE_CHAIN, 60e6, observedVersion, _markFsObs(), false
        );
        vm.stopPrank();
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.startPrank(admin);
        executor.executeForceResolveTransfer(resolveId, requestId, ResolveOutcome.DROP_RETURN_METADATA_INCLUDED);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();
        executor.executeForceSetSettledBalance(settleId, REMOTE_CHAIN, 60e6, observedVersion, fsObs, false);
        vm.stopPrank();

        // IL-8464: the skipped debit is reported as 0, and nothing is booked into `returnInFlight`.
        vm.expectEmit(false, false, false, true, address(executor));
        emit ReturnMetadataApplied(REMOTE_CHAIN, requestId, RGUID, 40e6, 0, 0, 2);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "late metadata not debited twice");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 2, "late metadata advances frontier");
    }

    /// @notice IL-8264 (H-03). A recall is dropped with `DROP_FROM_NAV`, the dispatcher has already sent it
    ///         (state version 3), and the operator reads the post-send balance (60) there. Before the fix the
    ///         force-set executed at once, and the late `RETURN_STARTED` debited the 40 again, leaving 20 and
    ///         shrinking the anchor. The force-set now declares version 3 and cannot execute until that
    ///         metadata has landed, so the debit is applied exactly once.
    function testForceSetObservedPastUndeliveredRecallDebitWaitsForMetadata() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        uint64 acknowledged = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        uint64 observedVersion = acknowledged + 1;

        vm.startPrank(admin);
        uint256 resolveId = executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.DROP_FROM_NAV);
        uint256 settleId = executor.scheduleForceSetSettledBalance(
            REMOTE_CHAIN, 60e6, observedVersion, _markFsObs(), false
        );
        vm.warp(block.timestamp + RESCUE_DELAY);
        executor.executeForceResolveTransfer(resolveId, requestId, ResolveOutcome.DROP_FROM_NAV);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.ForceSetStateVersionMismatch.selector, REMOTE_CHAIN, acknowledged, observedVersion
            )
        );
        executor.executeForceSetSettledBalance(settleId, REMOTE_CHAIN, 60e6, observedVersion, fsObs, false);
        vm.stopPrank();
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "settled untouched by the refused overwrite");

        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, observedVersion);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "late metadata applies the debit once");

        vm.prank(admin);
        executor.executeForceSetSettledBalance(settleId, REMOTE_CHAIN, 60e6, observedVersion, fsObs, false);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "overwrite does not count the debit twice");
    }

    /// @notice IL-8264 control: an overwrite read BEFORE the dispatcher sent the recall declares the current
    ///         frontier and executes at once. The metadata that lands afterwards carries a higher version, so
    ///         the observation cannot have included it, and its debit is the correct and only one.
    function testForceSetObservedBeforeRecallSendKeepsLateDebit() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        uint64 observedVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);

        vm.startPrank(admin);
        uint256 resolveId = executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.DROP_FROM_NAV);
        uint256 settleId = executor.scheduleForceSetSettledBalance(
            REMOTE_CHAIN, 100e6, observedVersion, _markFsObs(), false
        );
        vm.warp(block.timestamp + RESCUE_DELAY);
        executor.executeForceResolveTransfer(resolveId, requestId, ResolveOutcome.DROP_FROM_NAV);
        executor.executeForceSetSettledBalance(settleId, REMOTE_CHAIN, 100e6, observedVersion, fsObs, false);
        vm.stopPrank();

        // IL-8464: late metadata after a no-leg DROP reports the applied debit and no in-flight credit.
        vm.expectEmit(false, false, false, true, address(executor));
        emit ReturnMetadataApplied(REMOTE_CHAIN, requestId, RGUID, 40e6, 40e6, 0, observedVersion + 1);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, observedVersion + 1);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "post-observation send is debited");
    }

    event SettledBalanceForceSet(uint256 chainId, uint256 settledSD);

    /// @notice IL-8488. An observation BEHIND the acknowledged frontier can never execute (the frontier
    ///         never moves backwards), so scheduling it reverts at once instead of after the rescue delay.
    function testShouldRejectForceSetScheduleObservedBehindFrontier() public {
        _readyDispatcher();
        _settle100();
        uint64 acknowledged = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        assertGt(acknowledged, 0, "settle advanced the frontier");
        uint256 pendingBefore = executor.pendingRescueCount();
        uint256 countBefore = executor.rescueCount();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.ForceSetStateVersionMismatch.selector, REMOTE_CHAIN, acknowledged, acknowledged - 1
            )
        );
        executor.scheduleForceSetSettledBalance(REMOTE_CHAIN, 60e6, acknowledged - 1, _markFsObs(), false);

        assertEq(executor.pendingRescueCount(), pendingBefore, "no rescue queued");
        assertEq(executor.rescueCount(), countBefore, "no rescue id consumed");
    }

    /// @notice IL-8488. An observation equal to the frontier schedules and executes, and the executor address
    ///         still emits `SettledBalanceForceSet` (the emit now lives in the delegatecalled library).
    function testShouldEmitSettledBalanceForceSetFromExecutorWhenObservedEqualsFrontier() public {
        _readyDispatcher();
        _settle100();
        uint64 observedVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);

        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceSetSettledBalance(
            REMOTE_CHAIN, 60e6, observedVersion, _markFsObs(), false
        );
        vm.warp(block.timestamp + RESCUE_DELAY);

        vm.expectEmit(false, false, false, true, address(executor));
        emit SettledBalanceForceSet(REMOTE_CHAIN, 60e6);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(rescueId, REMOTE_CHAIN, 60e6, observedVersion, fsObs, false);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "overwrite applied");
    }

    /// @notice IL-8488. An observation AHEAD of the frontier stays schedulable (the frontier may catch up
    ///         during the delay); execute still requires equality and reverts while it has not.
    function testShouldScheduleForceSetObservedAheadOfFrontierButRefuseExecuteUntilItCatchesUp() public {
        _readyDispatcher();
        _settle100();
        uint64 acknowledged = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        uint64 observedVersion = acknowledged + 1;

        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceSetSettledBalance(
            REMOTE_CHAIN, 60e6, observedVersion, _markFsObs(), false
        );
        vm.warp(block.timestamp + RESCUE_DELAY);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.ForceSetStateVersionMismatch.selector, REMOTE_CHAIN, acknowledged, observedVersion
            )
        );
        executor.executeForceSetSettledBalance(rescueId, REMOTE_CHAIN, 60e6, observedVersion, fsObs, false);
    }

    function testComposeFirstWithLostMetadataCanBeReconciledAndClaimed() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(100e6, 0);

        usdc.mint(address(executor), 100e6);
        _deliverReturnCompose(requestId, RGUID, 100e6);
        assertEq(executor.pendingArrivalReserve(), 100e6, "compose-first amount reserved");

        uint64 observedVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.startPrank(admin);
        uint256 resolveId =
            executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.DROP_RETURN_METADATA_INCLUDED);
        uint256 settleId = executor.scheduleForceSetSettledBalance(
            REMOTE_CHAIN, 0, observedVersion, _markFsObs(), false
        );
        vm.warp(block.timestamp + RESCUE_DELAY);
        executor.executeForceResolveTransfer(resolveId, requestId, ResolveOutcome.DROP_RETURN_METADATA_INCLUDED);

        assertEq(executor.pendingArrivalReserve(), 0, "reserve reconciled");
        assertEq(executor.idleLedger(), 100e6, "physical arrival moved to claimable idle");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "staleness slot released");
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();

        executor.executeForceSetSettledBalance(settleId, REMOTE_CHAIN, 0, observedVersion, fsObs, false);
        vm.stopPrank();
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 0, "remote debit declared by force-set");

        vm.prank(manager);
        executor.claimAsset(type(uint256).max);
        assertEq(usdc.balanceOf(manager), 100e6, "returned tokens recovered by the vault manager");
        assertEq(executor.idleLedger(), 0, "claimed idle removed from executor ledger");

        _deliverReturnStarted(requestId, RGUID, 100e6, 100e6, 2);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "late metadata cannot debit twice");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 2, "late frontier still advances");
    }

    function testRejectedRecallDoesNotFreezeNavAndReopensSlot() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        _deliverReturnRejected(requestId);

        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "rejection releases reserved capacity");
        assertEq(executor.inFlightSince(REMOTE_CHAIN), 0);
        vm.warp(block.timestamp + TRANSFER_STALENESS_MAX + 1);
        _requestAssets(40e6, 0);
    }

    /// @notice IL-8447: a rejection after RETURN_STARTED metadata must not finalize the record, or the
    ///         `returnInFlight` it booked stays in NAV with no record left to resolve it.
    /// @dev FAILS WITHOUT THE FIX: the rejection finalizes the record, the chain stays unblocked and the
    ///      `DROP_FROM_NAV` force-resolve has no open record to act on.
    function testRejectionAfterMetadataKeepsRecordOpenAndBlocksChain() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 40e6, "metadata booked return-in-flight");

        _deliverReturnRejected(requestId);

        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "contradicting rejection fails closed");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 40e6, "booked leg is not stranded");

        vm.startPrank(admin);
        uint256 resolveId = executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.DROP_FROM_NAV);
        vm.warp(block.timestamp + RESCUE_DELAY);
        executor.executeForceResolveTransfer(resolveId, requestId, ResolveOutcome.DROP_FROM_NAV);
        vm.stopPrank();
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "record still resolvable through the leg's rescue");
    }

    /// @notice IL-8447: a rejection after the compose leg must not finalize the record, or the tokens booked in
    ///         `pendingArrivalReserve` stay locked there for good.
    /// @dev FAILS WITHOUT THE FIX: the rejection finalizes the record and the reserve can never be released.
    function testRejectionAfterComposeKeepsReserveResolvable() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(100e6, 0);
        usdc.mint(address(executor), 100e6);
        _deliverReturnCompose(requestId, RGUID, 100e6);
        assertEq(executor.pendingArrivalReserve(), 100e6, "compose-first amount reserved");

        _deliverReturnRejected(requestId);

        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "contradicting rejection fails closed");
        assertEq(executor.pendingArrivalReserve(), 100e6, "reserve untouched by the rejection");

        uint64 observedVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.startPrank(admin);
        uint256 resolveId =
            executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.DROP_RETURN_METADATA_INCLUDED);
        uint256 settleId = executor.scheduleForceSetSettledBalance(
            REMOTE_CHAIN, 0, observedVersion, _markFsObs(), false
        );
        vm.warp(block.timestamp + RESCUE_DELAY);
        executor.executeForceResolveTransfer(resolveId, requestId, ResolveOutcome.DROP_RETURN_METADATA_INCLUDED);
        executor.executeForceSetSettledBalance(settleId, REMOTE_CHAIN, 0, observedVersion, fsObs, false);
        vm.stopPrank();

        assertEq(executor.pendingArrivalReserve(), 0, "reserve released by the rescue");
        assertEq(executor.idleLedger(), 100e6, "arrival became claimable idle");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "force-set lifts the block");
    }

    /// @notice IL-8119 T6: a `BELOW_MINIMUM` rejection takes the same non-switching `_onReturnRejected`
    ///         branch as `NO_TRACKED_IDLE` and reopens the slot immediately, no staleness wait needed.
    /// @dev Does NOT compile against the pre-fix contracts: `ReturnRejectReason.BELOW_MINIMUM` did not
    ///      exist. This is the decode-path guard for the new enum value, not "fails pre-fix" regression
    ///      evidence — the enum member re-injection below covers that separately.
    function testBelowMinimumRejectionReopensSlot() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);

        vm.recordLogs();
        _deliverReturnRejected(requestId, ReturnRejectReason.BELOW_MINIMUM);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == RETURN_REJECTED_BY_DISPATCHER_TOPIC) {
                (,, uint8 reason) = abi.decode(logs[i].data, (uint256, bytes32, uint8));
                assertEq(reason, uint8(ReturnRejectReason.BELOW_MINIMUM), "reason carried through to the event");
                found = true;
            }
        }
        assertTrue(found, "ReturnRejectedByDispatcher not emitted");

        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "rejection releases reserved capacity");
        assertEq(executor.inFlightSince(REMOTE_CHAIN), 0);
        _requestAssets(40e6, 0); // no vm.warp: slot must already be free
    }

    /// @notice IL-8119 T7: a floor above the accounted upper bound is refused at request time, before the
    ///         request ever leaves the source chain — mirrors CcipCrosschainExecutor's existing guard.
    function testShouldRejectFloorAboveAccountedBoundAtRequestTime() public {
        _readyDispatcher();
        _settle100(); // settledRemoteBalance = 100e6 -> maxAccountedSD(40e6 request) = 40e6

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidMinimumReturn.selector, 41e6, 40e6));
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 40e6, 41e6, "");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "no record created on the refused request");
    }

    /// @notice IL-8119 T7b: the guard also fires when nothing is settled yet (`maxAccountedSD == 0`),
    ///         where pre-fix the request would have round-tripped into a `NO_TRACKED_IDLE` rejection later.
    function testShouldRejectAnyPositiveFloorWhenNothingIsSettled() public {
        _readyDispatcher(); // settledRemoteBalance == 0

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidMinimumReturn.selector, 1e6, 0));
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 40e6, 1e6, "");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "no record created on the refused request");
    }

    /// @dev Schedules and executes `ADVANCE_STATE_FRONTIER` to `newVersion_` (`id` packs `(chainId << 64) |
    ///      newVersion`) after the dedicated frontier-repair delay.
    function _advanceFrontier(uint64 newVersion_) private {
        bytes32 id = bytes32((uint256(REMOTE_CHAIN) << 64) | uint256(newVersion_));
        vm.startPrank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, ResolveOutcome.ADVANCE_STATE_FRONTIER);
        vm.warp(block.timestamp + CrosschainConstants.FRONTIER_REPAIR_DELAY);
        executor.executeForceResolveTransfer(rescueId, id, ResolveOutcome.ADVANCE_STATE_FRONTIER);
        vm.stopPrank();
    }

    /// @notice IL-8487 (B-38), overshoot. The dispatcher's version 2 was lost and its `RETURN_STARTED` (version 3)
    ///         is still retained by LayerZero. Advancing the frontier to 3 - the lowest still-deliverable version,
    ///         not one below it - makes that packet an "older duplicate": no debit is applied, the alert event
    ///         fires and the recall's compose lands in `pendingArrivalReserve`, outside NAV. Documents the
    ///         hazard the `stargate/README.md` "Frontier repair (Stargate)" section warns about.
    function testShouldDropRetainedReturnStartedWhenFrontierAdvancedPastIt() public {
        _readyDispatcher();
        _settle100(); // frontier = 1
        (bytes32 requestId,,) = _requestAssets(40e6, 0);

        // Version 2 is lost; RETURN_STARTED carries version 3 and is retained on the gap.
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.StateVersionGap.selector, REMOTE_CHAIN, 2, 3));
        this.deliverReturnStartedExternal(requestId, 40e6, 3);

        _advanceFrontier(3); // overshoot: the lowest deliverable version is 3, so the target was 2
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 3, "frontier moved onto the retained packet");

        vm.expectEmit(false, false, false, true, address(executor));
        emit AuthenticatedMessageDroppedAheadOfFrontier(REMOTE_CHAIN, uint8(MsgType.RETURN_STARTED), requestId, 3, 3);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 3);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "dropped metadata applied no debit");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "dropped metadata booked no in-flight credit");

        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);
        assertEq(executor.pendingArrivalReserve(), 40e6, "recall stranded in the reserve, outside NAV");
        assertEq(executor.idleLedger(), 0, "no idle credit without the metadata");
    }

    /// @notice IL-8487 (B-38), correct sizing. Same lost version 2, but the frontier is advanced to exactly the
    ///         lowest deliverable version minus one (2). The retained `RETURN_STARTED` then applies in order and
    ///         the recall completes normally.
    function testShouldApplyRetainedReturnStartedWhenFrontierAdvancedToJustBelowIt() public {
        _readyDispatcher();
        _settle100(); // frontier = 1
        (bytes32 requestId,,) = _requestAssets(40e6, 0);

        _advanceFrontier(2);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 2, "frontier one below the retained packet");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "the repair leaves the chain blocked");
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "the repair arms the latch");

        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 3);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 3, "retained packet consumed in order");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "retained metadata applied its debit");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 40e6, "expected credit booked in flight");

        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);
        assertEq(executor.idleLedger(), 40e6, "compose finalized into idle");
        assertEq(executor.pendingArrivalReserve(), 0, "nothing stranded in the reserve");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "in-flight credit replaced by the idle credit");
    }

    /// @notice IL-8487 (B-39). The compose leg landed first and the `RETURN_STARTED` metadata (version 2) is LOST
    ///         FOR GOOD, while a later packet (the settlement of an older transfer, version 3) is retained on
    ///         `StateVersionGap`. The compose-first rescue pair alone cannot help - the later packet keeps
    ///         reverting - so the documented order is: ADVANCE to the lost version (= lowest deliverable minus one), let
    ///         the retained packet replay, then `DROP_RETURN_METADATA_INCLUDED` + force-set at the new frontier. Both
    ///         rescue steps clear the block and the latch, so no fresh attestation is needed.
    function testShouldRecoverLostReturnMetadataByAdvancingThenComposeFirstRescue() public {
        _readyDispatcher();
        _settle100(); // frontier = 1, settled = 100
        (bytes32 otherTransferId, bytes32 otherGuid,) = _sendAsset(20e6, 0); // outbound in flight, settles at v3
        (bytes32 requestId,,) = _requestAssets(60e6, 0);

        usdc.mint(address(executor), 60e6);
        _deliverReturnCompose(requestId, RGUID, 60e6);
        assertEq(executor.pendingArrivalReserve(), 60e6, "compose-first amount reserved");

        // The metadata (v2) never arrives; the later settlement (v3) is retained by the lane.
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.StateVersionGap.selector, REMOTE_CHAIN, 2, 3));
        this.deliverTransferSettledExternal(otherTransferId, otherGuid, 20e6, 3);

        _advanceFrontier(2); // lowest deliverable (3) minus one
        _deliverTransferSettled(otherTransferId, otherGuid, 20e6, 3);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 3, "retained packet replayed in order");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e6, "settled counts both bridged amounts");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "still blocked until the rescue pair resolves the record");
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "latch still armed from the ADVANCE");

        // Rescue pair at the new frontier: the true remote value is 120 - 60 = 60.
        uint64 observedVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.startPrank(admin);
        uint256 resolveId =
            executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.DROP_RETURN_METADATA_INCLUDED);
        uint256 settleId = executor.scheduleForceSetSettledBalance(
            REMOTE_CHAIN, 60e6, observedVersion, _markFsObs(), false
        );
        vm.warp(block.timestamp + RESCUE_DELAY);
        executor.executeForceResolveTransfer(resolveId, requestId, ResolveOutcome.DROP_RETURN_METADATA_INCLUDED);
        assertFalse(executor.frontierRepairPending(REMOTE_CHAIN), "the drop discards the repair latch");
        executor.executeForceSetSettledBalance(settleId, REMOTE_CHAIN, 60e6, observedVersion, fsObs, false);
        vm.stopPrank();

        assertEq(executor.idleLedger(), 60e6, "idle credited with the compose amount");
        assertEq(executor.pendingArrivalReserve(), 0, "reserve released");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "no slot left held");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "settled equals the forced value");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "chain unblocked without a fresh attestation");
        assertFalse(executor.frontierRepairPending(REMOTE_CHAIN), "latch consumed");
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 60e6, "NAV prices the remote value again");
    }

    /// @dev External wrappers so `vm.expectRevert` binds to a single external call whose revert is the
    ///      endpoint delivery bubbling up, with no helper-internal external call in between.
    function deliverReturnStartedExternal(bytes32 requestId_, uint256 amountSD_, uint64 stateVersion_) external {
        _deliverReturnStarted(requestId_, RGUID, amountSD_, amountSD_, stateVersion_);
    }

    function deliverTransferSettledExternal(bytes32 transferId_, bytes32 guid_, uint256 amountSD_, uint64 stateVersion_)
        external
    {
        _deliverTransferSettled(transferId_, guid_, amountSD_, stateVersion_);
    }
}
