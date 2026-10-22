// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher, CcipReturnRejectReason} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipChainRescue, CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CcipExecutorTransferLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {CcipToken} from "./CcipLifecycleTest.t.sol";

/// @notice IL-8590 (reviewer residual R1): a `RETURN_REQUEST` carries a deadline the dispatcher enforces
///         (`EXPIRED`). `FORCE_SET_SETTLED` refuses to clear a cancelled recall's clock until the newest cancelled
///         request's deadline plus `RECALL_DEADLINE_SKEW_MARGIN` has passed (`refusedUntil`); `ADVANCE_FRONTIER`
///         never reverts on it, it keeps the clock until then.
contract CcipRecallDeadlineTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    uint256 internal constant STALENESS = 1 days;
    bytes32 internal constant EXECUTOR_RETURN_REJECTED_TOPIC = keccak256("ReturnRejected(uint256,bytes32,uint8)");

    MockCcipRouter internal router;
    CcipToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new CcipToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router), factory, address(this), address(token), keccak256("USDC"), 18, _safety()
        );
        CcipRouteConfig memory back = CcipRouteConfig({
            chainSelector: EXECUTOR_SELECTOR,
            peer: address(executor),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            18,
            block.chainid,
            back,
            address(0xA11),
            address(0xB22),
            3 days
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
    }

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return CcipCrosschainExecutor.SafetyConfig({
            rescueAdmin: address(0xA11),
            rescueGuardian: address(0xB22),
            balanceProposer: address(this),
            balanceApprover: address(0xA33),
            rescueDelay: 3 days,
            balanceStalenessMax: 7 days,
            bigChangeBps: 2_000, // == ATTESTATION_ANCHOR_BAND_BPS, the constructor ceiling (IL-8058)
            minUpdateInterval: 1 hours,
            transferStalenessMax: 1 days
        });
    }

    function _attestBalance(uint256 balance_) private {
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            balance_,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            uint64(block.number == 0 ? 1 : block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
        vm.prank(address(0xA33));
        executor.approveBalance(proposalId);
    }

    function _fundRemoteIdle(uint256 amount_) private {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 500_000);
        _attestBalance(dispatcher.accountedBalance());
    }

    function _expectStale(uint256 createdAt_) private {
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorTransferLib.TransferStale.selector, REMOTE_CHAIN, createdAt_)
        );
    }

    function _expectNotExpired(uint256 refusedUntil_) private {
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorTransferLib.CancelledRecallNotExpired.selector, REMOTE_CHAIN, refusedUntil_)
        );
    }

    /// @dev Hold every message, then recall `amount_` (the request stays undelivered at the router).
    function _holdAndRequest(uint256 amount_) private returns (bytes32 operationId, uint256 createdAt) {
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, amount_, 0, 0, address(0), 500_000);
        operationId = executor.activeReturn(REMOTE_CHAIN);
        createdAt = block.timestamp;
    }

    function _schedule(CcipChainRescue kind_, uint256 arg_) private returns (uint256 rescueId) {
        vm.prank(address(0xA11));
        rescueId = executor.scheduleChainRescue(kind_, REMOTE_CHAIN, arg_);
    }

    function _execute(uint256 rescueId_, CcipChainRescue kind_, uint256 arg_) private {
        vm.prank(address(0xA11));
        executor.executeChainRescue(rescueId_, kind_, REMOTE_CHAIN, arg_);
    }

    /// @dev FORCE_SET_SETTLED argument read now: (observed version << 192) | (observation time << 128) | balance.
    function _forceSetArg(uint256 balance_) private view returns (uint256) {
        return (uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) << 192) | (block.timestamp << 128) | balance_;
    }

    function _skipStuckReturn() private {
        uint64 stuck = dispatcher.responseQueueHead();
        vm.prank(address(0xA11));
        uint256 skipId = dispatcher.scheduleSkipStuckResponse(stuck);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        dispatcher.executeSkipStuckResponse(skipId, stuck);
    }

    function _deliverReject(bytes32 operationId_) private {
        vm.prank(address(router));
        executor.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256(abi.encode("reject", operationId_)),
                sourceChainSelector: DISPATCHER_SELECTOR,
                sender: abi.encode(address(dispatcher)),
                data: CcipMessages.encode(CcipMsgType.RETURN_REJECTED, abi.encode(operationId_, uint8(1))),
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
    }


    // ---------------------------------------------------------------- dispatcher deadline

    function testShouldRejectRequestExecutedAfterDeadlineWithExpired() public {
        _fundRemoteIdle(100e18);
        uint64 versionBefore = dispatcher.stateVersion();
        (bytes32 opId, uint256 createdAt) = _holdAndRequest(60e18);
        vm.warp(createdAt + STALENESS + 1);

        router.deliverHeld(0);

        assertTrue(dispatcher.processedOperation(opId), "operation consumed, the message cannot be replayed");
        assertEq(dispatcher.trackedIdle(), 100e18, "no value moved");
        assertEq(dispatcher.stateVersion(), versionBefore, "a rejection burns no state version");
        assertEq(router.heldCount(), 2, "only the RETURN_REJECTED was queued");

        vm.recordLogs();
        router.deliverHeld(1); // the RETURN_REJECTED reaches the executor
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(executor) && logs[i].topics[0] == EXECUTOR_RETURN_REJECTED_TOPIC) {
                (uint256 chainId, bytes32 rejectedOp, uint8 reason) = abi.decode(logs[i].data, (uint256, bytes32, uint8));
                assertEq(chainId, REMOTE_CHAIN);
                assertEq(rejectedOp, opId);
                assertEq(reason, uint8(CcipReturnRejectReason.EXPIRED), "EXPIRED on the wire");
                seen = true;
            }
        }
        assertTrue(seen, "executor emitted ReturnRejected");
    }

    function testShouldHonourRequestExecutedExactlyAtDeadline() public {
        _fundRemoteIdle(100e18);
        (bytes32 opId, uint256 createdAt) = _holdAndRequest(60e18);
        vm.warp(createdAt + STALENESS);

        router.deliverHeld(0);

        assertTrue(dispatcher.processedOperation(opId));
        assertEq(dispatcher.trackedIdle(), 40e18, "boundary request is honoured");
        assertEq(dispatcher.stateVersion(), executor.lastRemoteStateVersion(REMOTE_CHAIN) + 1, "RETURN_TRANSFER version");
    }

    function testShouldFreeActiveRecallWhenExpiredRejectionLands() public {
        _fundRemoteIdle(100e18);
        (bytes32 opId, uint256 createdAt) = _holdAndRequest(60e18);
        vm.warp(createdAt + STALENESS + 1);
        router.deliverHeld(0);

        router.deliverHeld(1); // the RETURN_REJECTED(EXPIRED) reaches the executor

        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "active recall freed, keeper may request again");
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
        assertTrue(opId != bytes32(0));
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18, "nothing debited");
    }

    /// @dev TRANSFER_STALENESS_MAX == 0 is refused by the executor constructor, so a zero-window "no expiry"
    ///      configuration cannot exist.
    function testShouldRefuseZeroTransferStalenessMax() public {
        CcipCrosschainExecutor.SafetyConfig memory safety = _safety();
        safety.transferStalenessMax = 0;
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        new CcipCrosschainExecutor(address(router), factory, address(this), address(token), keccak256("USDC"), 18, safety);
    }

    /// @notice Reviewer scenario R1 end to end: the request is stuck, anyone cancels it once stale, the rescue admin
    ///         force-sets the true value, and the stuck request is executed afterwards. The dispatcher now rejects
    ///         it (EXPIRED), so the 100 stay home and the books match.
    function testShouldRejectLateRequestAfterStaleCancelAndForceSet() public {
        _fundRemoteIdle(100e18);
        (bytes32 opId, uint256 requestedAt) = _holdAndRequest(60e18);

        vm.warp(requestedAt + STALENESS + 1);
        vm.prank(address(0xBAD));
        executor.cancelStalePendingReturn(REMOTE_CHAIN);
        _expectStale(requestedAt);
        executor.getBalance();

        uint256 arg = _forceSetArg(100e18);
        uint256 rescueId = _schedule(CcipChainRescue.FORCE_SET_SETTLED, arg);
        vm.warp(block.timestamp + 3 days);
        _execute(rescueId, CcipChainRescue.FORCE_SET_SETTLED, arg);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0, "clock reset after the deadline had passed");

        router.deliverHeld(0); // the stuck request is executed manually, long after its deadline
        assertTrue(dispatcher.processedOperation(opId));
        assertEq(dispatcher.trackedIdle(), 100e18, "the dispatcher keeps all 100");
        assertEq(router.heldCount(), 2, "only a RETURN_REJECTED is in transit, no tokens");
        assertEq(executor.getBalance(), 100e18, "NAV is right");

        router.deliverHeld(1);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18);
        assertEq(executor.idleLedger(), 0);
        assertEq(executor.getBalance(), 100e18);
    }

    /// @notice Same stuck request without a reset: the EXPIRED rejection resolves the cancelled recall's clock.
    function testShouldResolveCancelledClockWhenExpiredRejectionLands() public {
        _fundRemoteIdle(100e18);
        (, uint256 requestedAt) = _holdAndRequest(60e18);
        vm.warp(requestedAt + STALENESS + 1);
        executor.cancelStalePendingReturn(REMOTE_CHAIN);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1);

        router.deliverHeld(0);
        router.deliverHeld(1);

        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0, "clock resolved by the rejection");
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0);
        assertEq(dispatcher.trackedIdle(), 100e18);
        assertEq(executor.getBalance(), 100e18, "NAV live again");
    }

    // ---------------------------------------------------------------- reset guard

    function testShouldRefuseForceSetWhileCancelledRequestMayStillBeHonoured() public {
        _fundRemoteIdle(100e18);
        vm.warp(block.timestamp + 1); // IL-8604 R1: read strictly after the last value-moving receipt
        uint256 arg = _forceSetArg(100e18);
        uint256 scheduledAt = block.timestamp;
        uint256 rescueId = _schedule(CcipChainRescue.FORCE_SET_SETTLED, arg);

        vm.warp(scheduledAt + 2 days); // a recall can open after scheduling
        (, uint256 createdAt) = _holdAndRequest(60e18);
        executor.cancelPendingReturn(REMOTE_CHAIN);
        assertEq(executor.cancelledRecallLatestAt(REMOTE_CHAIN), createdAt);

        uint256 refusedUntil = createdAt + STALENESS + CrosschainConstants.RECALL_DEADLINE_SKEW_MARGIN;
        vm.warp(scheduledAt + 3 days);
        _expectNotExpired(refusedUntil);
        _execute(rescueId, CcipChainRescue.FORCE_SET_SETTLED, arg);

        vm.warp(refusedUntil); // inclusive
        _expectNotExpired(refusedUntil);
        _execute(rescueId, CcipChainRescue.FORCE_SET_SETTLED, arg);

        vm.warp(refusedUntil + 1);
        _execute(rescueId, CcipChainRescue.FORCE_SET_SETTLED, arg);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0);
        assertEq(executor.cancelledRecallGeneration(REMOTE_CHAIN), 1);
        // the anchor is not cleared, but with count == 0 the guard no longer applies
        vm.warp(block.timestamp + 1); // IL-8604 R1: read strictly after the last value-moving receipt
        uint256 arg2 = _forceSetArg(100e18);
        uint256 rescueId2 = _schedule(CcipChainRescue.FORCE_SET_SETTLED, arg2);
        vm.warp(block.timestamp + 3 days);
        _execute(rescueId2, CcipChainRescue.FORCE_SET_SETTLED, arg2);
        assertEq(executor.cancelledRecallGeneration(REMOTE_CHAIN), 2, "guard not applied with count == 0");
    }

    /// @dev Cancelled recall scheduled-around advance: returns (rescueId, arg, opId, createdAt, refusedUntil, execAt).
    function _advanceWithCancelledRecall()
        private
        returns (uint256 rescueId, uint256 arg, bytes32 opId, uint256 createdAt, uint256 refusedUntil)
    {
        _fundRemoteIdle(100e18);
        arg = uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) + 1;
        uint256 scheduledAt = block.timestamp;
        rescueId = _schedule(CcipChainRescue.ADVANCE_FRONTIER, arg);
        vm.warp(scheduledAt + CrosschainConstants.FRONTIER_REPAIR_DELAY - 1);
        (opId, createdAt) = _holdAndRequest(60e18);
        executor.cancelPendingReturn(REMOTE_CHAIN);
        refusedUntil = createdAt + STALENESS + CrosschainConstants.RECALL_DEADLINE_SKEW_MARGIN;
        vm.warp(scheduledAt + CrosschainConstants.FRONTIER_REPAIR_DELAY);
    }

    /// @notice An early ADVANCE_FRONTIER does not revert on the guard: the frontier advances and the chain stays
    ///         blocked, but the clock (count, anchors, generation) is kept, so NAV stays TransferStale-gated; the
    ///         EXPIRED answer of the cancelled request then resolves it in the same generation.
    function testShouldAdvanceFrontierEarlyKeepingCancelledRecallClock() public {
        (uint256 rescueId, uint256 arg,, uint256 createdAt, uint256 refusedUntil) = _advanceWithCancelledRecall();
        assertTrue(block.timestamp <= refusedUntil);
        uint64 versionBefore = executor.lastRemoteStateVersion(REMOTE_CHAIN);

        _execute(rescueId, CcipChainRescue.ADVANCE_FRONTIER, arg);

        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), versionBefore + 1, "frontier advanced");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "still blocked");
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "repair latch armed");
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1, "count kept");
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), createdAt, "pendingAt kept");
        assertEq(executor.cancelledRecallLatestAt(REMOTE_CHAIN), createdAt, "latestAt kept");
        assertEq(executor.cancelledRecallGeneration(REMOTE_CHAIN), 0, "generation kept");

        // A fresh attestation reopens NAV, but the kept clock still gates it once the recall turns stale.
        _attestBalance(dispatcher.accountedBalance());
        assertFalse(executor.chainBlocked(REMOTE_CHAIN));
        vm.warp(createdAt + STALENESS + 1);
        _expectStale(createdAt);
        executor.getBalance();

        // The stuck request is executed late: EXPIRED, which resolves the cancelled recall in the same generation.
        router.deliverHeld(0);
        assertEq(dispatcher.trackedIdle(), 100e18, "no value moved");
        router.deliverHeld(1);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0, "resolved by the EXPIRED answer");
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0);
        assertEq(executor.cancelledRecallGeneration(REMOTE_CHAIN), 0, "same generation");
        assertEq(executor.getBalance(), 100e18, "NAV live again");
    }

    function testShouldKeepClockWhenAdvanceExecutedExactlyAtRefusedUntil() public {
        (uint256 rescueId, uint256 arg,,, uint256 refusedUntil) = _advanceWithCancelledRecall();
        // boundary: the second AT refusedUntil still keeps the clock
        vm.warp(refusedUntil);
        _execute(rescueId, CcipChainRescue.ADVANCE_FRONTIER, arg);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1, "kept at refusedUntil");
        assertEq(executor.cancelledRecallGeneration(REMOTE_CHAIN), 0);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN));
    }

    function testShouldResetClockWhenAdvanceExecutedAfterRefusedUntil() public {
        (uint256 rescueId, uint256 arg,,, uint256 refusedUntil) = _advanceWithCancelledRecall();
        vm.warp(refusedUntil + 1);
        _execute(rescueId, CcipChainRescue.ADVANCE_FRONTIER, arg);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0, "cleared one second after refusedUntil");
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0);
        assertEq(executor.cancelledRecallGeneration(REMOTE_CHAIN), 1);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "advance still blocks until a fresh attestation");
    }

    /// @notice Griefing regression: the manager recalls and cancels right before the advance, repeatedly; the
    ///         advance still executes.
    function testShouldNotLetManagerPostponeAdvanceFrontierWithRecallCancelLoop() public {
        _fundRemoteIdle(100e18);
        uint256 arg = uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) + 1;
        uint256 scheduledAt = block.timestamp;
        uint256 rescueId = _schedule(CcipChainRescue.ADVANCE_FRONTIER, arg);
        vm.warp(scheduledAt + CrosschainConstants.FRONTIER_REPAIR_DELAY - 2);
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        for (uint256 i; i < 2; ++i) {
            executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 1e18, 0, 0, address(0), 500_000);
            executor.cancelPendingReturn(REMOTE_CHAIN);
            vm.warp(block.timestamp + 1);
        }
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 2);
        _execute(rescueId, CcipChainRescue.ADVANCE_FRONTIER, arg);
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), arg, "advance went through");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN));
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 2, "clock kept");
    }

    /// @notice Manager cancel at createdAt (no wait), FORCE_SET after the guard, then the stuck request is executed
    ///         late: EXPIRED, nothing moves.
    function testShouldRejectLateRequestAfterManagerCancelAndForceSet() public {
        _fundRemoteIdle(100e18);
        (bytes32 opId, uint256 createdAt) = _holdAndRequest(60e18);
        executor.cancelPendingReturn(REMOTE_CHAIN); // manager path, same second
        uint256 refusedUntil = createdAt + STALENESS + CrosschainConstants.RECALL_DEADLINE_SKEW_MARGIN;
        uint256 arg = _forceSetArg(100e18);
        uint256 rescueId = _schedule(CcipChainRescue.FORCE_SET_SETTLED, arg);
        vm.warp(block.timestamp + 3 days);
        assertTrue(block.timestamp > refusedUntil);
        _execute(rescueId, CcipChainRescue.FORCE_SET_SETTLED, arg);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
        assertEq(executor.cancelledRecallGeneration(REMOTE_CHAIN), 1);

        router.deliverHeld(0);
        assertTrue(dispatcher.processedOperation(opId));
        assertEq(dispatcher.trackedIdle(), 100e18, "trackedIdle unchanged, no value moved");
        router.deliverHeld(1); // EXPIRED answer of an older generation
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
        assertEq(executor.cancelledRecallGeneration(REMOTE_CHAIN), 1);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18);
        assertEq(executor.getBalance(), 100e18);
    }

    /// @notice An EXPIRED answer for a recall cancelled in an OLDER generation must not drop the new count.
    function testShouldNotDropNewGenerationCountOnOlderGenerationExpiredAnswer() public {
        (uint256 rescueId, uint256 arg,,, uint256 refusedUntil) = _advanceWithCancelledRecall();
        vm.warp(refusedUntil + 1);
        _execute(rescueId, CcipChainRescue.ADVANCE_FRONTIER, arg); // generation 1, count 0
        _attestBalance(dispatcher.accountedBalance());
        assertFalse(executor.chainBlocked(REMOTE_CHAIN));

        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 1e18, 0, 0, address(0), 500_000); // held at index 1
        executor.cancelPendingReturn(REMOTE_CHAIN);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1);
        assertEq(executor.cancelledRecallGeneration(REMOTE_CHAIN), 1);

        router.deliverHeld(0); // the OLD request: expired, rejected -> RETURN_REJECTED(EXPIRED) held at index 2
        uint256 rejectIndex = router.heldCount() - 1;
        router.deliverHeld(rejectIndex);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1, "older-generation answer must not drop the count");
    }

    function testShouldNotApplyResetGuardWithoutCancelledRecall() public {
        _fundRemoteIdle(100e18);
        uint256 arg = _forceSetArg(100e18);
        uint256 rescueId = _schedule(CcipChainRescue.FORCE_SET_SETTLED, arg);
        vm.warp(block.timestamp + 3 days);
        _execute(rescueId, CcipChainRescue.FORCE_SET_SETTLED, arg);
        assertEq(executor.cancelledRecallGeneration(REMOTE_CHAIN), 1, "reset ran without a guard revert");
    }

    function testShouldNotApplyResetGuardOnceCancelledRecallResolved() public {
        _fundRemoteIdle(100e18);
        uint256 arg = _forceSetArg(100e18);
        uint256 scheduledAt = block.timestamp;
        uint256 rescueId = _schedule(CcipChainRescue.FORCE_SET_SETTLED, arg);
        vm.warp(scheduledAt + 3 days - 1 hours);
        (bytes32 opId,) = _holdAndRequest(60e18);
        executor.cancelPendingReturn(REMOTE_CHAIN);
        _deliverReject(opId);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0, "clock cleared with the last resolution");

        vm.warp(scheduledAt + 3 days);
        _execute(rescueId, CcipChainRescue.FORCE_SET_SETTLED, arg);
        assertEq(executor.cancelledRecallGeneration(REMOTE_CHAIN), 1);
    }

    function testShouldKeyResetGuardOnNewestCancelledRecall() public {
        _fundRemoteIdle(100e18);
        uint256 arg = _forceSetArg(100e18);
        uint256 scheduledAt = block.timestamp;
        uint256 rescueId = _schedule(CcipChainRescue.FORCE_SET_SETTLED, arg);

        vm.warp(scheduledAt + 2 days);
        (, uint256 olderAt) = _holdAndRequest(10e18);
        executor.cancelPendingReturn(REMOTE_CHAIN);
        vm.warp(scheduledAt + 2 days + 12 hours);
        (, uint256 newerAt) = _holdAndRequest(10e18);
        executor.cancelPendingReturn(REMOTE_CHAIN);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 2);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), olderAt, "staleness clock stays on the oldest");
        assertEq(executor.cancelledRecallLatestAt(REMOTE_CHAIN), newerAt, "guard anchor is the newest");

        uint256 olderRefusedUntil = olderAt + STALENESS + CrosschainConstants.RECALL_DEADLINE_SKEW_MARGIN;
        uint256 newerRefusedUntil = newerAt + STALENESS + CrosschainConstants.RECALL_DEADLINE_SKEW_MARGIN;
        vm.warp(olderRefusedUntil + 1); // past the older deadline, inside the newer one
        _expectNotExpired(newerRefusedUntil);
        _execute(rescueId, CcipChainRescue.FORCE_SET_SETTLED, arg);

        vm.warp(newerRefusedUntil + 1);
        _execute(rescueId, CcipChainRescue.FORCE_SET_SETTLED, arg);
    }

    /// @notice Skip-valve exit in the documented order: skip -> cancel -> ADVANCE_FRONTIER.
    function testShouldAdvanceFrontierAfterSkipThenCancelOnceDeadlinePassed() public {
        _fundRemoteIdle(100e18);
        router.setFailSend(address(dispatcher), true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 500_000);
        uint256 createdAt = block.timestamp;
        _skipStuckReturn();
        router.setFailSend(address(dispatcher), false);
        executor.cancelPendingReturn(REMOTE_CHAIN);

        uint256 arg = uint256(dispatcher.stateVersion());
        uint256 rescueId = _schedule(CcipChainRescue.ADVANCE_FRONTIER, arg);
        vm.warp(block.timestamp + CrosschainConstants.FRONTIER_REPAIR_DELAY);
        assertTrue(block.timestamp > createdAt + STALENESS + CrosschainConstants.RECALL_DEADLINE_SKEW_MARGIN);
        _execute(rescueId, CcipChainRescue.ADVANCE_FRONTIER, arg);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
    }
}
