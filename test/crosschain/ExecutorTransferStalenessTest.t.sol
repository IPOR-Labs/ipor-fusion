// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {StargateCrosschainExecutor} from "../../contracts/crosschain/stargate/StargateCrosschainExecutor.sol";
import {ExecutorInitParams} from "../../contracts/crosschain/interfaces/ICrosschainFactory.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool} from "./mocks/MockStargatePool.sol";
import {MockCrosschainFactory} from "./mocks/MockCrosschainFactory.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @title ExecutorTransferStalenessTest
/// @notice P2 audit regression suite: every unresolved transfer/recall record — regardless of which NAV
///         bucket currently holds its value — is subject to TRANSFER_STALENESS_MAX (CROSSCHAIN_AUDIT_FIX_PLAN
///         §4). Deployed with a transfer-staleness window SHORTER than the settled-observation window so the
///         transfer gate is the binding constraint (with a fresh approved settled bucket), letting the tests
///         isolate the record-based gate from the settled-freshness gate.
contract ExecutorTransferStalenessTest is CrosschainTestBase {
    /// @dev Shorter than STALENESS_MAX (1h) so the transfer gate binds while settled is still fresh.
    uint256 internal constant SHORT_TRANSFER = 30 minutes;

    function setUp() public {
        // Mirror `_baseSetUp` but with a short transfer-staleness window.
        vm.chainId(LOCAL_CHAIN);
        vm.warp(365 days);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        factory = new MockCrosschainFactory();
        factory.setPath(REMOTE_CHAIN, REMOTE_EID);

        ExecutorInitParams memory p = _params();
        p.transferStalenessMax = SHORT_TRANSFER;
        executor = _deployExecutor(address(factory), p);
        vm.deal(address(executor), 100 ether);
    }

    /// @dev Propose + approve an absolute settled balance at the current time so the settled-freshness gate
    ///      stays open (freshness marker = now) while the transfer gate ages independently.
    function _approveSettledFresh(uint256 settledLD_, uint64 version_) internal {
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: settledLD_,
            stateVersion: version_,
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 20 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        uint256 pid = executor.proposalCount();
        vm.prank(approver);
        executor.approveBalance(pid);
    }

    // ---------------------------------------------------------------------
    // Pending recall directly ages the NAV staleness gate, including lost metadata
    // ---------------------------------------------------------------------

    function testShouldDirectlyStaleWhenPendingRecallMetadataIsLost() public {
        _readyDispatcher();
        _settle100(); // settled = 100e6, frontier = 1
        _approveSettledFresh(100e6, 1);

        // Value remains in settled, but the unresolved protocol operation has a direct liveness clock.
        _requestAssets(40e6, 0);
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "no in-flight bucket value yet");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 1, "capacity reserved");
        assertEq(executor.inFlightSince(REMOTE_CHAIN), uint64(block.timestamp), "request arms staleness");
        assertEq(executor.getBalance(), 100e6, "fresh before the deadline");

        vm.warp(block.timestamp + SHORT_TRANSFER + 1);
        _approveSettledFresh(100e6, 1);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavTransferStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    function testShouldStayFreshBeforeRecallDeadline() public {
        _readyDispatcher();
        _settle100();
        _approveSettledFresh(100e6, 1);
        _requestAssets(40e6, 0);
        vm.warp(block.timestamp + SHORT_TRANSFER); // exactly at the boundary, not past it
        assertEq(executor.getBalance(), 100e6, "fresh at the boundary");
    }

    // ---------------------------------------------------------------------
    // Metadata-first return keeps the gate armed until finalization
    // ---------------------------------------------------------------------

    function testShouldKeepGateArmedThroughMetadataFirstReturnUntilFinalized() public {
        _readyDispatcher();
        _settle100();
        _approveSettledFresh(100e6, 1);
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2); // metadata: value now in returnInFlight
        assertGt(executor.inFlightSince(REMOTE_CHAIN), 0, "still armed mid-flight");

        vm.warp(block.timestamp + SHORT_TRANSFER + 1);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavTransferStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    function testShouldClearGateOnFinalizationWhenNoOtherRecord() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6); // finalize -> settled 60e6, idle 40e6

        assertEq(executor.inFlightSince(REMOTE_CHAIN), 0, "gate cleared on finalization");
        // Keep settled fresh; only idle + fresh settled remain, no unresolved record.
        _approveSettledFresh(60e6, 2);
        vm.warp(block.timestamp + SHORT_TRANSFER + 100);
        // Re-approve so the settled window stays open across the warp; the transfer gate must not fire.
        _approveSettledFresh(60e6, 2);
        assertEq(executor.getBalance(), 100e6, "no staleness once every record is resolved");
    }

    // ---------------------------------------------------------------------
    // Two records: resolving the newer must NOT reset the older record's clock
    // (outbound-only: value lives in outboundInFlight, so settled staleness is irrelevant)
    // ---------------------------------------------------------------------

    function testShouldNotResetOlderRecordClockWhenNewerCompletes() public {
        _readyDispatcher();

        // Record A (outbound) created first.
        _sendAsset(10e6, 0);
        uint64 armedA = executor.inFlightSince(REMOTE_CHAIN);

        // Advance time, then create record B (outbound).
        vm.warp(block.timestamp + 10 minutes);
        (bytes32 transferIdB, bytes32 guidB,) = _sendAsset(10e6, 0);
        assertEq(executor.inFlightSince(REMOTE_CHAIN), armedA, "oldest clock is still A's creation time");

        // Complete the NEWER record B. The oldest clock must remain A's, not reset to B's.
        _deliverTransferSettled(transferIdB, guidB, 10e6, 1);
        assertEq(executor.inFlightSince(REMOTE_CHAIN), armedA, "older record clock preserved");

        // A is now old enough to be stale (armedA + SHORT_TRANSFER + 1). settled from B's settlement is
        // approved fresh so only the transfer gate can fire.
        _approveSettledFresh(10e6, 1);
        vm.warp(uint256(armedA) + SHORT_TRANSFER + 1);
        _approveSettledFresh(10e6, 1);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavTransferStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    // ---------------------------------------------------------------------
    // Force-resolving the oldest leaves the next record correctly timed
    // ---------------------------------------------------------------------

    function testShouldRetimeToNextRecordWhenOldestForceResolved() public {
        _readyDispatcher();

        (bytes32 transferIdA,,) = _sendAsset(10e6, 0);
        uint64 armedA = executor.inFlightSince(REMOTE_CHAIN);
        vm.warp(block.timestamp + 10 minutes);
        _sendAsset(10e6, 0);
        uint256 bCreatedAt = block.timestamp;

        // Force-resolve the OLDEST record A (drop it from NAV) after the rescue timelock.
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(transferIdA, ResolveOutcome.DROP_FROM_NAV);
        vm.warp(block.timestamp + RESCUE_DELAY + 1);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, transferIdA, ResolveOutcome.DROP_FROM_NAV);

        // The clock now reflects B's creation time, not A's: the resolved oldest record no longer pins it.
        assertEq(executor.inFlightSince(REMOTE_CHAIN), uint64(bCreatedAt), "clock retimed to next record");
        assertTrue(executor.inFlightSince(REMOTE_CHAIN) != armedA, "clock no longer pinned to resolved record");
    }

    // ---------------------------------------------------------------------
    // The permissionless stale-recall escape must not disarm a gate that protects booked value
    // (audit `permissionless_disarm_of_fail_closed_nav_staleness_gate`)
    // ---------------------------------------------------------------------

    /// @dev Any unprivileged address. The escape stays permissionless by design; what is constrained is
    ///      the STATE it may be applied to, not the caller.
    address internal constant OUTSIDER = address(0xBADBAD);

    /// @dev Local re-declaration of the library event for `vm.expectEmit` topic matching (no indexed
    ///      params anywhere in this codebase, so plain positional matching is used, same pattern as
    ///      `FrontierJumpBoundTest.AuthenticatedMessageDroppedAheadOfFrontier`).
    event ReturnComposeWithoutStalenessClock(uint256 srcChainId, bytes32 requestId, uint256 amountSD);

    /// @dev Local re-declarations of the IL-8465 accounting events (library events, emitted by the executor).
    event ReturnComposeReserved(uint256 srcChainId, bytes32 requestId, bytes32 guid, uint256 amountSD);
    event ReturnRecordForceResolved(
        uint256 chainId,
        bytes32 requestId,
        uint8 outcome,
        uint256 inFlightRemovedSD,
        uint256 reserveToIdleSD
    );

    /// @dev IL-8472 library event, emitted by the executor address.
    event ProposalInvalidated(uint256 chainId, uint256 proposalId, uint64 newEpoch);

    bytes32 internal constant RETURN_COMPOSE_NO_CLOCK_TOPIC =
        keccak256("ReturnComposeWithoutStalenessClock(uint256,bytes32,uint256)");

    /// @notice The finding's exact sequence: a recall whose metadata landed has moved value into
    ///         `returnInFlight`, and its unresolved-transfer slot is the ONLY clock on that value. The
    ///         staleness predicate of the escape and the NAV gate fire at the very same instant, so before
    ///         the fix the gate could be disarmed by anyone the moment it engaged, leaving the stuck value
    ///         priced into NAV forever with no clock.
    function testShouldRejectPermissionlessCancelOnceRecallMetadataMovedValue() public {
        _readyDispatcher();
        _settle100();
        _approveSettledFresh(100e6, 1);
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2); // settled 60e6, returnInFlight 40e6

        assertEq(executor.returnInFlight(REMOTE_CHAIN), 40e6, "metadata booked the expected credit");
        uint64 armedAt = executor.inFlightSince(REMOTE_CHAIN);
        assertGt(armedAt, 0, "the record's staleness clock is armed");

        // The delivery compose is permanently stuck; the fail-closed gate engages.
        vm.warp(block.timestamp + SHORT_TRANSFER + 1);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavTransferStale.selector, REMOTE_CHAIN));
        executor.getBalance();

        vm.prank(OUTSIDER);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.ReturnRequestValueMoved.selector, REMOTE_CHAIN, requestId)
        );
        executor.cancelStaleReturnRequest(REMOTE_CHAIN);

        // Nothing was released: the clock, the booked value and the request slot all survive.
        assertEq(executor.inFlightSince(REMOTE_CHAIN), armedAt, "clock still armed");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 40e6, "value still booked in NAV");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 1, "capacity still held");
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.ActiveReturnRequestExists.selector, REMOTE_CHAIN, requestId)
        );
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 1e6, 0, "");

        // The gate is still closed — which is the whole point of it.
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavTransferStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    /// @notice Compose-first (order b): the tokens are physically here and tracked in
    ///         `pendingArrivalReserve` while `settled` still counts them. The record is mid-reconciliation,
    ///         so its clock must survive the escape just as in the metadata-first order.
    function testShouldRejectPermissionlessCancelOnceDeliveryComposeArrivedFirst() public {
        _readyDispatcher();
        _settle100();
        _approveSettledFresh(100e6, 1);
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);
        assertEq(executor.pendingArrivalReserve(), 40e6, "compose-first credit tracked in the reserve");

        vm.warp(block.timestamp + SHORT_TRANSFER + 1);
        vm.prank(OUTSIDER);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.ReturnRequestValueMoved.selector, REMOTE_CHAIN, requestId)
        );
        executor.cancelStaleReturnRequest(REMOTE_CHAIN);

        assertGt(executor.inFlightSince(REMOTE_CHAIN), 0, "clock still armed");
        assertEq(executor.pendingArrivalReserve(), 40e6, "reserve untouched");
    }

    /// @notice The liveness escape the function actually exists for is unchanged: a recall on which nothing
    ///         moved is a pure reservation (value still sits in `settled`, which has its own freshness
    ///         gate), so anyone may hand the slot back once the window elapses.
    function testShouldStillAllowPermissionlessCancelWhenNoValueHasMoved() public {
        _readyDispatcher();
        _settle100();
        _approveSettledFresh(100e6, 1);
        _requestAssets(40e6, 0);
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 1, "capacity reserved by the request");

        vm.warp(block.timestamp + SHORT_TRANSFER + 1);
        vm.prank(OUTSIDER);
        executor.cancelStaleReturnRequest(REMOTE_CHAIN);

        assertEq(executor.inFlightSince(REMOTE_CHAIN), 0, "clock released");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "capacity handed back");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "no value was ever booked");
        // NAV is not fail-open here (IL-8621): the cancel keeps the cancelled-recall clock armed, so the
        // overstatement window of an already bridged recall is bounded like any in-flight transfer.
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavTransferStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    /// @notice The state the escape no longer clears has a proper terminal exit: the timelocked rescue,
    ///         which — unlike the escape — also removes the value from the NAV buckets.
    function testShouldForceResolveTheStuckRecallTheEscapeNoLongerClears() public {
        _readyDispatcher();
        _settle100();
        _approveSettledFresh(100e6, 1);
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);

        vm.warp(block.timestamp + SHORT_TRANSFER + 1);
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.DROP_FROM_NAV);
        vm.warp(block.timestamp + RESCUE_DELAY + 1);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, requestId, ResolveOutcome.DROP_FROM_NAV);

        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "rescue removes the value from NAV");
        assertEq(executor.inFlightSince(REMOTE_CHAIN), 0, "and releases the clock with it");
        _approveSettledFresh(60e6, 2);
        assertEq(executor.getBalance(), 60e6, "NAV reopens on the remaining, attested settled balance");
    }

    /// @notice The related fail-open named by the same finding: late metadata for an abandoned recall books
    ///         `returnInFlight` even when the staleness pool is full and no clock can be armed. Reverting
    ///         is not an option (it would freeze the version frontier for good), so the chain fails closed
    ///         instead and the timelocked rescue owns the exit.
    function testShouldFailClosedWhenLateMetadataBooksInFlightWithNoStalenessSlot() public {
        _readyDispatcher();
        _settle100();
        _approveSettledFresh(100e6, 1);
        (bytes32 requestId,,) = _requestAssets(40e6, 0);

        vm.warp(block.timestamp + SHORT_TRANSFER + 1);
        vm.prank(OUTSIDER);
        executor.cancelStaleReturnRequest(REMOTE_CHAIN); // legitimate: nothing had moved

        // Newer transfers fill the staleness pool before the abandoned recall's metadata finally lands.
        for (uint256 i; i < 16; ++i) {
            _sendAsset(1e6, 0);
        }
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 16, "pool full, no slot left to reclaim");

        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);

        assertEq(executor.returnInFlight(REMOTE_CHAIN), 40e6, "late metadata booked the expected credit");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "clock-less in-flight value must fail closed");
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    // ---------------------------------------------------------------------
    // Pending-transfer cap covers value-moving records; unaccepted recalls use their own single slot
    // ---------------------------------------------------------------------

    function testShouldCapPendingTransfersAcrossOutboundAndReturns() public {
        _readyDispatcher();
        _settle100();

        // Fill the value-moving pool with outbound records. A recall does not occupy it until metadata.
        for (uint256 i; i < 16; ++i) {
            _sendAsset(1e6, 0);
        }
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 16, "value-moving pool full");

        usdc.mint(address(executor), 1e6);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.PendingTransfersCapReached.selector, REMOTE_CHAIN, uint256(16))
        );
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 1e6, 0, "");
    }

    // ---------------------------------------------------------------------
    // IL-7966: a delivery compose landing on a cancelled recall must not book value with no clock
    // ---------------------------------------------------------------------

    /// @dev Shared setup for the IL-7966 tests: a recall whose staleness slot was released by the
    ///      permissionless cancel (nothing had moved), followed by the delivery compose arriving late.
    /// @dev The epoch snapshot taken right after the cancel and right before the late compose is applied,
    ///      so callers can isolate the epoch delta the compose's own re-arm/block sub-branch contributes.
    uint64 internal _epochBeforeCancelThenCompose;

    function _cancelThenDeliverLateCompose() internal returns (bytes32 requestId) {
        _readyDispatcher();
        _settle100();
        _approveSettledFresh(100e6, 1);
        (requestId,,) = _requestAssets(40e6, 0);
        vm.warp(block.timestamp + SHORT_TRANSFER + 1);
        vm.prank(OUTSIDER);
        executor.cancelStaleReturnRequest(REMOTE_CHAIN); // legitimate: nothing had moved
        usdc.mint(address(executor), 40e6);
        _epochBeforeCancelThenCompose = executor.accountingEpoch(REMOTE_CHAIN);
        _deliverReturnCompose(requestId, RGUID, 40e6);
    }

    /// @notice IL-8465 (B-04). An order-(b) compose on a live record (compose before `RETURN_STARTED`)
    ///         books `pendingArrivalReserve` and must announce it with the amount-carrying event.
    function testShouldEmitReturnComposeReservedOnLiveComposeFirst() public {
        _readyDispatcher();
        _settle100();
        _approveSettledFresh(100e6, 1);
        (bytes32 requestId,,) = _requestAssets(40e6, 0);

        usdc.mint(address(executor), 40e6);
        vm.expectEmit(false, false, false, true, address(executor));
        emit ReturnComposeReserved(REMOTE_CHAIN, requestId, RGUID, 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);

        assertEq(executor.pendingArrivalReserve(), 40e6, "reserve booked");
    }

    /// @notice IL-8465 (B-04). The late compose after a permissionless `cancelStaleReturnRequest` (slot
    ///         re-armed) also books the reserve and must announce it.
    function testShouldEmitReturnComposeReservedOnLateComposeAfterCancel() public {
        _readyDispatcher();
        _settle100();
        _approveSettledFresh(100e6, 1);
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        vm.warp(block.timestamp + SHORT_TRANSFER + 1);
        vm.prank(OUTSIDER);
        executor.cancelStaleReturnRequest(REMOTE_CHAIN);

        usdc.mint(address(executor), 40e6);
        vm.expectEmit(false, false, false, true, address(executor));
        emit ReturnComposeReserved(REMOTE_CHAIN, requestId, RGUID, 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);

        assertEq(executor.pendingArrivalReserve(), 40e6, "reserve booked");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 1, "slot re-armed");
    }

    /// @notice IL-8472 (B-12). The late compose after a permissionless cancel bumps the accounting epoch; an
    ///         active proposal is voided with `ProposalInvalidated` and marked SUPERSEDED (4).
    function testShouldInvalidateActiveProposalOnLateComposeAfterCancel() public {
        _readyDispatcher();
        _settle100();
        _approveSettledFresh(100e6, 1);
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        vm.warp(block.timestamp + SHORT_TRANSFER + 1);
        vm.prank(OUTSIDER);
        executor.cancelStaleReturnRequest(REMOTE_CHAIN);

        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: 100e6,
            stateVersion: executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN),
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 20 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        uint256 pid = executor.proposalCount();
        assertEq(executor.activeProposalId(REMOTE_CHAIN), pid, "proposal active before the late compose");

        uint64 newEpoch = executor.accountingEpoch(REMOTE_CHAIN) + 1;
        usdc.mint(address(executor), 40e6);
        vm.expectEmit(false, false, false, true, address(executor));
        emit ProposalInvalidated(REMOTE_CHAIN, pid, newEpoch);
        _deliverReturnCompose(requestId, RGUID, 40e6);

        (,,,,,,,, uint8 status) = executor.proposals(pid);
        assertEq(status, 4, "status SUPERSEDED");
        assertEq(executor.activeProposalId(REMOTE_CHAIN), 0, "no active proposal");
        vm.prank(approver);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ProposalNotActive.selector, pid));
        executor.approveBalance(pid);
    }

    /// @notice The finding's core case: a compose lands after the permissionless cancel released the
    ///         record's staleness slot. The fix re-arms a fresh slot on the reopened record exactly as
    ///         `_onReturnStarted` does for the mirror (late-metadata) case, so the reserved value gets a
    ///         clock again instead of sitting unsignalled forever.
    ///         FAILS WITHOUT THE FIX: `inFlightSince` stays 0 (no clock re-armed), the accounting epoch is
    ///         not bumped, and `getBalance()` never reverts even after the transfer-staleness window
    ///         elapses again — the stranded value is priced into NAV forever with nothing to flag it.
    function testShouldReclockLateComposeOnCancelledRecall() public {
        bytes32 requestId = _cancelThenDeliverLateCompose();
        // `_epochBeforeCancelThenCompose` is snapshotted by the helper right after the cancel and right
        // before the compose is delivered, isolating the epoch delta the COMPOSE's own re-arm contributes.
        uint64 epochBeforeCompose = _epochBeforeCancelThenCompose;

        assertEq(executor.pendingArrivalReserve(), 40e6, "compose value tracked in the reserve");
        assertEq(executor.inFlightSince(REMOTE_CHAIN), block.timestamp, "fresh staleness clock armed");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 1, "slot capacity re-consumed");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "capacity was available, no block needed");
        assertEq(executor.getBalance(), 100e6, "still counted once, as settled");
        assertEq(
            executor.accountingEpoch(REMOTE_CHAIN),
            epochBeforeCompose + 1,
            "compose's own re-arm bumps the epoch exactly once"
        );

        // Re-approve settled freshness so the warp below ages only the (re-armed) transfer clock,
        // isolating `NavTransferStale` from the unrelated settled-freshness gate — the cancel's own warp
        // already consumed most of `STALENESS_MAX` (1h) against the first approval.
        _approveSettledFresh(100e6, 1);
        vm.warp(block.timestamp + SHORT_TRANSFER + 1);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavTransferStale.selector, REMOTE_CHAIN));
        executor.getBalance();

        requestId; // silence unused-var warning; kept for readability/parity with the other tests
    }

    /// @notice Sub-branch 2 of the fix: the re-arm cannot find a free slot (the staleness pool is full of
    ///         newer transfers by the time the abandoned recall's compose finally lands). The handler must
    ///         still never revert (it is the inbound LayerZero compose handler; a revert would retain the
    ///         packet forever with the tokens already physically on the executor) — it fails closed via
    ///         `chainBlocked` instead, exactly mirroring `_onReturnStarted`'s own no-slot branch.
    ///         FAILS WITHOUT THE FIX: no `ReturnComposeWithoutStalenessClock` event is ever emitted (the
    ///         branch does not exist), `chainBlocked` stays false, and `getBalance()` never reverts.
    function testShouldFailClosedWhenLateComposeCannotReclaimStalenessSlot() public {
        _readyDispatcher();
        _settle100();
        _approveSettledFresh(100e6, 1);
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        vm.warp(block.timestamp + SHORT_TRANSFER + 1);
        vm.prank(OUTSIDER);
        executor.cancelStaleReturnRequest(REMOTE_CHAIN); // legitimate: nothing had moved

        // Newer transfers fill the staleness pool before the abandoned recall's compose finally lands.
        for (uint256 i; i < 16; ++i) {
            _sendAsset(1e6, 0);
        }
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 16, "pool full, no slot left to reclaim");

        usdc.mint(address(executor), 40e6);
        // IL-8465: the reserve booking is announced first, then the clock-less alert.
        vm.expectEmit(false, false, false, true, address(executor));
        emit ReturnComposeReserved(REMOTE_CHAIN, requestId, RGUID, 40e6);
        vm.expectEmit(false, false, false, true, address(executor));
        emit ReturnComposeWithoutStalenessClock(REMOTE_CHAIN, requestId, 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);

        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "clock-less compose value must fail closed");
        assertEq(executor.pendingArrivalReserve(), 40e6, "value still tracked, just unclocked");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 16, "no slot was consumed (none available)");
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    /// @notice When the metadata never follows, the re-armed record ages out exactly like any other open
    ///         recall and the existing two-step timelocked rescue exits it — no new rescue state was added
    ///         by the fix. Proves "one shared rescue window" between the metadata-first and compose-first
    ///         late orders.
    ///         The `NavTransferStale` assertion below FAILS WITHOUT THE FIX (no clock was ever re-armed, so
    ///         the gate never engages and there is nothing for the rescue to be needed for in the first
    ///         place under the old behaviour).
    function testShouldRescueLateComposeOnCancelledRecallWhenMetadataNeverArrives() public {
        bytes32 requestId = _cancelThenDeliverLateCompose();
        // Re-approve settled freshness here so the SECOND warp below ages only the (re-armed) transfer
        // clock, isolating `NavTransferStale` from the unrelated settled-freshness gate (`NavSettledStale`)
        // — the same isolation `_approveSettledFresh` buys at the top of the test, now needed a second
        // time because the cancel's own warp already consumed most of `STALENESS_MAX` (1h) against the
        // first approval.
        _approveSettledFresh(100e6, 1);

        vm.warp(block.timestamp + SHORT_TRANSFER + 1);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavTransferStale.selector, REMOTE_CHAIN));
        executor.getBalance();

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
        // IL-8465: the compose-only rescue reports the reserve -> idle move.
        vm.expectEmit(false, false, false, true, address(executor));
        emit ReturnRecordForceResolved(
            REMOTE_CHAIN, requestId, uint8(ResolveOutcome.DROP_RETURN_METADATA_INCLUDED), 0, 40e6
        );
        executor.executeForceResolveTransfer(resolveId, requestId, ResolveOutcome.DROP_RETURN_METADATA_INCLUDED);
        executor.executeForceSetSettledBalance(settleId, REMOTE_CHAIN, 60e6, observedVersion, fsObs, false);
        vm.stopPrank();

        assertEq(executor.idleLedger(), 40e6, "physical compose value moved to claimable idle");
        assertEq(executor.pendingArrivalReserve(), 0, "reserve reconciled");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "staleness slot released");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "block lifted by the timelocked rescue");
        // IL-8646: the force-set stamps its (RESCUE_DELAY-old) committed observation time, stale against the 1h
        // STALENESS_MAX; an ordinary attestation of the new settled figure restores NAV freshness.
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        executor.getBalance();
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _approveSettledFresh(60e6, observedVersion);
        assertEq(executor.getBalance(), 100e6, "same NAV total, now backed by idle instead of settled");

        vm.prank(manager);
        executor.claimAsset(type(uint256).max);
        assertEq(usdc.balanceOf(manager), 40e6, "rescued tokens claimable by the vault manager");

        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "late metadata does not debit twice");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 2, "late frontier still advances");
    }

    /// @notice Non-regression guard, NOT fail-without-fix evidence: passes in BOTH states by design. If the
    ///         metadata eventually follows the late compose, the record self-heals through the existing
    ///         order-(b) finalize in `_onReturnStarted` exactly as it does for a live record — proving the
    ///         re-armed slot is released exactly once (no capacity leak) and that the fix does not force a
    ///         rescue where the accounting can resolve itself for free.
    function testShouldSelfHealCancelledRecallWhenMetadataFollowsLateCompose() public {
        bytes32 requestId = _cancelThenDeliverLateCompose();

        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);

        assertEq(executor.idleLedger(), 40e6, "compose value recognized as idle");
        assertEq(executor.pendingArrivalReserve(), 0, "reserve released");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "remote debit applied exactly once");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "slot released, no leak");
        assertEq(executor.inFlightSince(REMOTE_CHAIN), 0, "clock released with the record");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "never blocked: no rescue was needed");
        assertEq(executor.getBalance(), 100e6, "NAV correct with no rescue at all");
    }

    /// @notice Non-regression guard, NOT fail-without-fix evidence: passes in BOTH states by design. Pins
    ///         that the fix's general `!rec.pendingSlotArmed` key does not touch an ordinary, never-cancelled
    ///         compose-first arrival: its slot was armed at `buildReturnRequest` and is still held, so the
    ///         new re-arm/block sub-branch must not fire and the clock must be the record's original
    ///         creation time, not a freshly re-armed one.
    function testShouldNotReclockLiveComposeFirstArrival() public {
        _readyDispatcher();
        _settle100();
        _approveSettledFresh(100e6, 1);
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        uint64 createdAt = executor.inFlightSince(REMOTE_CHAIN);
        assertGt(createdAt, 0, "buildReturnRequest arms the slot immediately at request creation");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 1, "capacity reserved by the request");

        // Advance time (but stay well inside the transfer-staleness window) so a re-armed clock would be
        // visibly different from the original creation timestamp.
        vm.warp(block.timestamp + 5 minutes);

        usdc.mint(address(executor), 40e6);
        vm.recordLogs();
        _deliverReturnCompose(requestId, RGUID, 40e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != RETURN_COMPOSE_NO_CLOCK_TOPIC, "no alert on a live compose-first arrival");
        }
        assertEq(executor.inFlightSince(REMOTE_CHAIN), createdAt, "clock unchanged: slot was already armed");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 1, "still exactly one slot held, none re-consumed");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "never blocked on a live record");
    }
}

/// @title ExecutorDustGuardTest
/// @notice P2 audit regression: sub-shared-decimal amounts (local>shared decimals, so a positive local
///         amount can truncate to zero shared decimals) must revert BEFORE any state growth or fee spend,
///         never creating a permanent zero-value record (CROSSCHAIN_AUDIT_FIX_PLAN §4 item 7). Uses an
///         18-decimal asset with shared=6 so `_toSD(amount) == 0` is reachable for a nonzero `amount`.
contract ExecutorDustGuardTest is CrosschainTestBase {
    /// @dev 1e12 - 1 in an 18/6 asset converts to 0 shared decimals (below one shared unit).
    uint256 internal constant DUST = 1e12 - 1;

    function setUp() public {
        vm.chainId(LOCAL_CHAIN);
        vm.warp(365 days);

        usdc = new MockERC20("Asset18", "AST", 18);
        pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        factory = new MockCrosschainFactory();
        factory.setPath(REMOTE_CHAIN, REMOTE_EID);

        executor = _deployExecutor(address(factory), _params());
        vm.deal(address(executor), 100 ether);
    }

    function testShouldRejectSubSharedDecimalOutboundBeforeStateGrowth() public {
        _readyDispatcher();
        usdc.mint(address(executor), 1e18);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.AmountBelowSharedDecimals.selector, DUST));
        executor.sendAssetToDispatcher(REMOTE_CHAIN, DUST, 0, "");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "no record created for dust");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "no bucket growth for dust");
    }

    function testShouldRejectSubSharedDecimalRecallBeforeStateGrowth() public {
        _readyDispatcher();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.AmountBelowSharedDecimals.selector, DUST));
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, DUST, 0, "");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "no return record created for dust");
    }

    function testShouldRejectBridgeableAmountWithDustRemainder() public {
        _readyDispatcher();
        uint256 amount = 1e12 + 1;
        usdc.mint(address(executor), amount);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.AmountBelowSharedDecimals.selector, amount));
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount, 0, "");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0);
    }
}
