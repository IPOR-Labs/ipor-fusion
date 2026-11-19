// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipChainRescue} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CcipExecutorTransferLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {CcipToken} from "./CcipLifecycleTest.t.sol";

/// @notice IL-8590 (Ackee TP-M-12): cancelling a recall must carry its staleness clock over instead of
///         deleting it, so NAV stays fail-closed on a late `RETURN_TRANSFER` that CCIP 2.0 may deliver at
///         any time (IL-8496). IL-9595: the clock is anchored on the OLDEST UNRESOLVED cancelled recall, so a
///         resolved recall no longer closes NAV, while an unresolved one never escapes its own window.
contract CcipCancelledRecallClockTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    uint256 internal constant STALENESS = 1 days;
    /// @dev `CrosschainConstants.MAX_CANCELLED_RECALLS_PER_CHAIN` (manager-path cap on unresolved cancelled recalls).
    uint256 internal constant CAP = 4;

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
            anchorBandBps: 2_000,
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

    /// @dev Recall 60 of 100, hold the messages, deliver the request so the dispatcher debits its tracked idle and
    ///      dispatches the token-bearing `RETURN_TRANSFER` (held, index 1), then cancel on the executor.
    function _recallDispatchedThenCancelled(bool permissionless_) private returns (bytes32 operationId) {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 500_000);
        operationId = executor.activeReturn(REMOTE_CHAIN);
        router.deliverHeld(0);
        assertEq(dispatcher.trackedIdle(), 40e18, "dispatcher debited its idle");
        assertEq(router.heldCount(), 2, "RETURN_TRANSFER dispatched");
        if (permissionless_) {
            vm.warp(block.timestamp + STALENESS + 1);
            executor.cancelStalePendingReturn(REMOTE_CHAIN);
        } else {
            executor.cancelPendingReturn(REMOTE_CHAIN);
        }
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0));
    }

    function _expectStale(uint256 createdAt_) private {
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorTransferLib.TransferStale.selector, REMOTE_CHAIN, createdAt_)
        );
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

    function testShouldKeepNavFailClosedAfterCancelUntilLateReturnLands() public {
        uint256 requestedAt = block.timestamp + 1; // _fundRemoteIdle warps 1s before the recall
        _recallDispatchedThenCancelled(false);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), requestedAt, "clock carried over");
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1);
        assertEq(executor.getBalance(), 100e18, "within the window NAV is live");

        vm.warp(requestedAt + STALENESS + 1);
        _expectStale(requestedAt);
        executor.getBalance();

        router.deliverHeld(1);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0, "clock cleared by the late return");
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
        assertEq(executor.idleLedger(), 60e18, "credited once");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18, "debited once");
        assertEq(executor.getBalance(), 100e18, "NAV healthy after the late return");
    }

    function testShouldReopenNavWhenLateReturnLandsBeforeStaleness() public {
        _recallDispatchedThenCancelled(false);
        assertEq(executor.getBalance(), 100e18);
        vm.warp(block.timestamp + STALENESS - 10);
        assertEq(executor.getBalance(), 100e18, "no revert inside the window");
        router.deliverHeld(1);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0);
        vm.warp(block.timestamp + 5 days);
        _attestBalance(40e18);
        assertEq(executor.getBalance(), 100e18, "no clock left to trip after the window");
    }

    function testShouldKeepClockOnPermissionlessStaleCancel() public {
        uint256 requestedAt = block.timestamp + 1;
        _recallDispatchedThenCancelled(true);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), requestedAt, "stale cancel keeps the clock");
        _expectStale(requestedAt);
        executor.getBalance();
        router.deliverHeld(1);
        assertEq(executor.getBalance(), 100e18, "late return resolves it");
    }

    function testShouldClearCancelledClockOnReturnRejected() public {
        uint256 requestedAt = block.timestamp + 1;
        bytes32 operationId = _recallDispatchedThenCancelled(false);
        vm.warp(requestedAt + STALENESS + 1);
        _expectStale(requestedAt);
        executor.getBalance();

        _deliverReject(operationId);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
        assertEq(executor.getBalance(), 100e18, "NAV live after the rejection");
    }

    /// @dev Recall 60 of 100 with the dispatcher's response send failing, so the `RETURN_TRANSFER` sits in its
    ///      queue; cancel on the executor, then drop it with the timelocked skip valve (tokens back to
    ///      `trackedIdle`, `settled` never debited, one state version burned). The IL-8294 runbook forbids a
    ///      force-set while a return is still deliverable, so this is the state a force-set may start from.
    function _recallDroppedThenCancelled() private returns (bytes32 operationId) {
        _fundRemoteIdle(100e18);
        router.setFailSend(address(dispatcher), true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 500_000);
        operationId = executor.activeReturn(REMOTE_CHAIN);
        uint64 stuck = dispatcher.responseQueueHead();
        assertTrue(stuck != 0, "return stuck in the dispatcher queue");
        executor.cancelPendingReturn(REMOTE_CHAIN);
        vm.prank(address(0xA11));
        uint256 skipId = dispatcher.scheduleSkipStuckResponse(stuck);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        dispatcher.executeSkipStuckResponse(skipId, stuck);
        router.setFailSend(address(dispatcher), false);
        assertEq(dispatcher.trackedIdle(), 100e18, "dropped return's tokens are back in idle");
    }

    function _rescue(CcipChainRescue kind_, uint256 arg_) private {
        vm.prank(address(0xA11));
        uint256 rescueId = executor.scheduleChainRescue(kind_, REMOTE_CHAIN, arg_);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        executor.executeChainRescue(rescueId, kind_, REMOTE_CHAIN, arg_);
    }

    function testShouldClearCancelledClockOnForceSetSettled() public {
        uint256 requestedAt = block.timestamp + 1;
        _recallDroppedThenCancelled();
        _expectStale(requestedAt);
        executor.getBalance();

        _rescue(
            CcipChainRescue.FORCE_SET_SETTLED,
            (uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) << 192) | (block.timestamp << 128) | 100e18
        );

        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
        assertEq(executor.getBalance(), 100e18, "NAV live after the force-set");
    }

    /// @notice IL-8590: the skip valve drops the cancelled recall's return for good, so the executor's
    ///         `ADVANCE_FRONTIER` repair clears the clock; the chain stays blocked until a fresh approved
    ///         attestation at the new frontier reopens NAV.
    function testShouldClearCancelledClockOnAdvanceFrontier() public {
        uint256 requestedAt = block.timestamp + 1;
        _recallDroppedThenCancelled();
        _expectStale(requestedAt);
        executor.getBalance();

        _rescue(CcipChainRescue.ADVANCE_FRONTIER, uint256(dispatcher.stateVersion()));

        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0, "clock cleared");
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0, "count cleared");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "blocked until a fresh attestation");
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN));
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();

        _attestBalance(dispatcher.accountedBalance());
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "approval at the new frontier lifts the block");
        assertEq(executor.getBalance(), 100e18, "NAV reopened");
    }

    /// @notice Cancel A, force-set (new generation), cancel B, then A's late answer lands: it must not touch B's
    ///         clock. (A's answer is a synthetic reject; the guard is independent of the answer kind.)
    function testShouldIgnoreStaleGenerationResolution() public {
        bytes32 idA = _recallDispatchedThenCancelled(false);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1);
        assertEq(executor.cancelledRecallGeneration(REMOTE_CHAIN), 0);

        // The runbook forbids force-setting while A's RETURN_TRANSFER is still deliverable; the order is used
        // here only to exercise the generation guard.
        _rescue(
            CcipChainRescue.FORCE_SET_SETTLED,
            (uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) << 192) | (block.timestamp << 128) | 100e18
        );
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
        assertEq(executor.cancelledRecallGeneration(REMOTE_CHAIN), 1, "reset bumps the generation");

        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 10e18, 0, 0, address(0), 500_000);
        bytes32 idB = executor.activeReturn(REMOTE_CHAIN);
        uint64 bCreatedAt = uint64(block.timestamp);
        executor.cancelPendingReturn(REMOTE_CHAIN);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1);
        assertEq(executor.cancelledRecallGenerationOf(idA), 0);
        assertEq(executor.cancelledRecallGenerationOf(idB), 1);

        _deliverReject(idA);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1, "stale-generation answer ignored");
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), bCreatedAt, "B's clock untouched");

        _deliverReject(idB);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0, "B's own answer resolves it");
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0);
    }

    /// @notice A new recall may open while a cancelled one is unresolved (the skipped-response recovery path
    ///         relies on it). The cancelled clock stays separate: it keeps gating NAV after the new recall is
    ///         finalized and only the cancelled recall's own resolution clears it.
    function testShouldKeepCancelledClockSeparateWhenNewRecallOpens() public {
        uint256 requestedAt = block.timestamp + 1;
        bytes32 cancelledId = _recallDispatchedThenCancelled(false);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 10e18, 0, 0, address(0), 500_000);
        bytes32 newId = executor.activeReturn(REMOTE_CHAIN);
        assertTrue(newId != cancelledId && newId != bytes32(0));
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), requestedAt, "cancelled clock untouched");

        vm.warp(requestedAt + STALENESS + 1);
        _expectStale(requestedAt);
        executor.getBalance();

        _deliverReject(newId); // resolving the NEW recall does not clear the cancelled clock
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1);
        _expectStale(requestedAt);
        executor.getBalance();

        router.deliverHeld(1); // the cancelled recall's own late return does
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
        assertEq(executor.getBalance(), 100e18);
    }

    /// @notice Cancel + re-request just before the timeout, three times. The anchor must stay on the FIRST
    ///         recall: kills "anchor on the newest recall", which the rest of the suite does not catch.
    function testShouldKeepClockAnchoredOnFirstRecallAcrossCancelReRequestLoop() public {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        uint256 firstAt = block.timestamp;
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 10e18, 0, 0, address(0), 500_000);
        router.deliverHeld(0); // the first recall's RETURN_TRANSFER is dispatched and held in transit
        uint256 last = firstAt;
        for (uint256 i; i < 3; ++i) {
            vm.warp(last + STALENESS - 10);
            executor.cancelPendingReturn(REMOTE_CHAIN);
            executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 1e18, 0, 0, address(0), 500_000);
            assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), firstAt, "anchor stays on the first recall");
            // the newest CANCELLED recall is the one just replaced
            assertEq(executor.cancelledRecallLatestAt(REMOTE_CHAIN), last, "guard anchor follows the newest cancelled");
            last = block.timestamp;
        }
        vm.warp(firstAt + STALENESS + 1); // the active recall is young, the first cancelled one is stale
        _expectStale(firstAt);
        executor.getBalance();
    }

    /// @notice IL-9595 (reverses the IL-8590 "not re-anchored" pin): two cancelled recalls; the OLDER one resolves
    ///         first. The clock moves to the newer recall's `createdAt` (it does not clear: kills "clear on the first
    ///         resolution"), and NAV no longer trips on the resolved recall's window, only on the newer one's.
    function testShouldReanchorClockOnNextUnresolvedRecallWhenOldestResolves() public {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        uint256 firstAt = block.timestamp;
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 10e18, 0, 0, address(0), 500_000);
        router.deliverHeld(0); // first RETURN_TRANSFER held at index 1
        executor.cancelPendingReturn(REMOTE_CHAIN);
        vm.warp(firstAt + STALENESS / 2);
        uint256 secondAt = block.timestamp;
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 1e18, 0, 0, address(0), 500_000); // request held at index 2
        executor.cancelPendingReturn(REMOTE_CHAIN);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), firstAt, "oldest anchors while both are unresolved");

        router.deliverHeld(1); // the first recall's late return lands
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), secondAt, "re-anchored on the oldest unresolved");
        assertEq(executor.cancelledRecallLatestAt(REMOTE_CHAIN), secondAt, "still the newest createdAt");

        vm.warp(firstAt + STALENESS + 1);
        assertEq(executor.getBalance(), 100e18, "the resolved recall no longer closes NAV");
        vm.warp(secondAt + STALENESS);
        assertEq(executor.getBalance(), 100e18, "the unresolved recall's window is still open");
        vm.warp(secondAt + STALENESS + 1);
        _expectStale(secondAt);
        executor.getBalance();
    }

    /// @notice Two cancelled recalls; the NEWER one resolves first. The anchor must stay on the older, still
    ///         unresolved recall (kills "anchor on the next queued entry regardless of its status").
    function testShouldKeepAnchorOnOldestWhenNewerCancelledRecallResolvesFirst() public {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        uint256 firstAt = block.timestamp;
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 10e18, 0, 0, address(0), 500_000);
        router.deliverHeld(0); // first RETURN_TRANSFER held at index 1
        executor.cancelPendingReturn(REMOTE_CHAIN);
        vm.warp(firstAt + STALENESS / 2);
        (bytes32 secondId, ) = _openAndCancel(1e18);

        _deliverReject(secondId);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), firstAt, "older unresolved recall keeps anchoring");
        vm.warp(firstAt + STALENESS + 1);
        _expectStale(firstAt);
        executor.getBalance();

        router.deliverHeld(1); // the older recall's own late return clears the clock
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0);
        assertEq(executor.getBalance(), 100e18);
    }

    /// @notice IL-9595 fuzz: `CAP` cancelled recalls at random spacings (zero allowed: equal `createdAt`), answered
    ///         in a random order. After every answer the anchor is the minimum `createdAt` of the recalls still
    ///         unresolved (0 when none) and NAV closes exactly one second after that anchor's window.
    function testFuzzShouldAnchorOnOldestUnresolvedForAnyAnswerOrder(uint256 seed_) public {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        bytes32[] memory ids = new bytes32[](CAP);
        uint256[] memory createdAt = new uint256[](CAP);
        bool[] memory resolved = new bool[](CAP);
        for (uint256 i; i < CAP; ++i) {
            vm.warp(block.timestamp + (uint256(keccak256(abi.encode(seed_, "gap", i))) % (STALENESS / 8)));
            (ids[i], createdAt[i]) = _openAndCancel(1e18);
        }
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), createdAt[0], "first cancelled anchors");

        uint256[] memory order = _permutation(seed_, CAP);
        for (uint256 k; k < CAP; ++k) {
            _deliverReject(ids[order[k]]);
            resolved[order[k]] = true;
            _assertAnchorIsOldestUnresolved(createdAt, resolved, CAP);
            uint256 anchor = executor.cancelledRecallPendingAt(REMOTE_CHAIN);
            if (anchor != 0) _assertNavClosesRightAfter(anchor);
        }
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0, "clock cleared with the last answer");
        assertEq(executor.getBalance(), 100e18);
    }

    /// @notice IL-9595 fuzz: a random interleaving of manager cancels (up to `CAP` unresolved) and answers to random
    ///         unresolved recalls, so new recalls are appended after resolved entries were dropped from the queue
    ///         head. After every step: the count is the number of unresolved recalls; the anchor is never past an
    ///         unresolved recall and is exactly the oldest unresolved `createdAt` (never 0 while one is open).
    function testFuzzShouldTrackOldestUnresolvedAcrossInterleavedCancelsAndAnswers(uint256 seed_) public {
        uint256 steps = 24;
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        bytes32[] memory ids = new bytes32[](steps);
        uint256[] memory createdAt = new uint256[](steps);
        bool[] memory resolved = new bool[](steps);
        uint256 n;
        uint256 open;
        for (uint256 s; s < steps; ++s) {
            uint256 r = uint256(keccak256(abi.encode(seed_, s)));
            if (open == 0 || (open < CAP && r % 2 == 0)) {
                vm.warp(block.timestamp + ((r >> 8) % 1 hours));
                (ids[n], createdAt[n]) = _openAndCancel(1e18);
                ++n;
                ++open;
            } else {
                uint256 pick = (r >> 8) % open;
                for (uint256 j; j < n; ++j) {
                    if (resolved[j]) continue;
                    if (pick == 0) {
                        _deliverReject(ids[j]);
                        resolved[j] = true;
                        --open;
                        break;
                    }
                    --pick;
                }
            }
            (uint256 oldest, uint256 unresolved) = _oldestUnresolved(createdAt, resolved, n);
            uint256 anchor = executor.cancelledRecallPendingAt(REMOTE_CHAIN);
            assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), unresolved, "count = unresolved cancelled recalls");
            if (unresolved == 0) {
                assertEq(anchor, 0, "clock cleared with the last answer");
            } else {
                assertEq(anchor, oldest, "anchor is exactly the oldest unresolved recall");
            }
        }
    }

    /// @notice IL-9595 (#21): resolved recalls are unlinked from the queue in O(1) when they are answered, so the
    ///         anchor is always the oldest UNRESOLVED recall however many resolved ones sit behind an unresolved
    ///         head. Ten recalls cancelled and answered behind unresolved A; the B timestamps are stale while the
    ///         fresh U is not. Answering A must anchor on U (not on a stale resolved B) and NAV must not revert;
    ///         after U's own deadline NAV trips with U's timestamp.
    function testShouldAnchorOnOldestUnresolvedAfterManyResolvedBehindHead() public {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        (bytes32 aId, ) = _openAndCancel(1e18);
        for (uint256 i; i < 10; ++i) {
            vm.warp(block.timestamp + 1);
            (bytes32 id, ) = _openAndCancel(1e18);
            _deliverReject(id); // resolved behind the unresolved head A
        }
        vm.warp(block.timestamp + STALENESS + 100); // A and every B are now past the staleness window
        (bytes32 uId, uint256 uAt) = _openAndCancel(1e18);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 2);

        _deliverReject(aId);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), uAt, "anchor is the fresh unresolved recall");
        assertEq(executor.getBalance(), 100e18, "stale resolved recalls do not close NAV");

        vm.warp(uAt + STALENESS + 1);
        _expectStale(uAt);
        executor.getBalance();

        _deliverReject(uId);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0);
    }

    /// @notice IL-9595 (#21, replaces the bounded-walk pin): the same shape as above, but a later unresolved recall V
    ///         is answered out of order. Ten resolved behind head A, then U and V unresolved: answering A anchors on
    ///         U at once, answering V (the tail) keeps U, answering U clears the clock.
    function testShouldUnlinkResolvedEntriesInAnyOrder() public {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        (bytes32 headId, uint256 headAt) = _openAndCancel(1e18);
        for (uint256 i; i < 10; ++i) {
            vm.warp(block.timestamp + 1);
            (bytes32 id, ) = _openAndCancel(1e18);
            _deliverReject(id);
        }
        vm.warp(block.timestamp + 1);
        (bytes32 uId, uint256 uAt) = _openAndCancel(1e18);
        vm.warp(block.timestamp + 1);
        (bytes32 vId, ) = _openAndCancel(1e18);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 3);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), headAt);

        _deliverReject(headId);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), uAt, "head answered: anchor on U immediately");

        _deliverReject(vId); // the tail
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), uAt, "tail answer keeps the anchor");

        _deliverReject(uId);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0);
    }

    /// @notice IL-9595: a generation reset (`FORCE_SET_SETTLED` past the guard) empties the queue. The older
    ///         generation's unresolved recall B must not anchor the new generation's clock after C resolves.
    function testShouldEmptyQueueOnGenerationReset() public {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        (bytes32 idA, ) = _openAndCancel(1e18);
        vm.warp(block.timestamp + 1 hours);
        _openAndCancel(1e18); // B: never answered, stays CANCELLED in the old generation
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 2);

        _rescue(
            CcipChainRescue.FORCE_SET_SETTLED,
            (uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) << 192) | (block.timestamp << 128) | 100e18
        );
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0);
        assertEq(executor.cancelledRecallGeneration(REMOTE_CHAIN), 1);

        (bytes32 idC, uint256 cAt) = _openAndCancel(1e18);
        vm.warp(block.timestamp + 1 hours);
        (bytes32 idD, uint256 dAt) = _openAndCancel(1e18);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), cAt, "new generation anchors on C");

        _deliverReject(idA); // older generation: ignored
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 2);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), cAt);

        _deliverReject(idC);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), dAt, "re-anchored on D, not on the old B");

        _deliverReject(idD);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0);
    }

    /// @dev Open a recall with its request held (nothing delivered) and cancel it on the manager path.
    function _openAndCancel(uint256 amount_) private returns (bytes32 operationId, uint256 createdAt) {
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, amount_, 0, 0, address(0), 500_000);
        operationId = executor.activeReturn(REMOTE_CHAIN);
        createdAt = block.timestamp;
        executor.cancelPendingReturn(REMOTE_CHAIN);
    }

    /// @dev Minimum `createdAt` over the unresolved recalls (0 when none) and their number.
    function _oldestUnresolved(
        uint256[] memory createdAt_,
        bool[] memory resolved_,
        uint256 n_
    ) private pure returns (uint256 oldest, uint256 open) {
        for (uint256 i; i < n_; ++i) {
            if (resolved_[i]) continue;
            if (open == 0 || createdAt_[i] < oldest) oldest = createdAt_[i];
            ++open;
        }
    }

    function _assertAnchorIsOldestUnresolved(
        uint256[] memory createdAt_,
        bool[] memory resolved_,
        uint256 n_
    ) private view {
        (uint256 oldest, uint256 open) = _oldestUnresolved(createdAt_, resolved_, n_);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), open, "count = unresolved cancelled recalls");
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), oldest, "anchor = oldest unresolved createdAt");
    }

    /// @dev NAV is live at `anchor_ + STALENESS` and reverts `TransferStale(anchor_)` one second later.
    function _assertNavClosesRightAfter(uint256 anchor_) private {
        uint256 snap = vm.snapshotState();
        vm.warp(anchor_ + STALENESS);
        assertEq(executor.getBalance(), 100e18, "live at the end of the anchor's window");
        vm.warp(anchor_ + STALENESS + 1);
        _expectStale(anchor_);
        executor.getBalance();
        vm.revertToState(snap);
    }

    /// @dev Fisher-Yates permutation of `0..n_-1` driven by `seed_`.
    function _permutation(uint256 seed_, uint256 n_) private pure returns (uint256[] memory order) {
        order = new uint256[](n_);
        for (uint256 i; i < n_; ++i) order[i] = i;
        for (uint256 i = n_; i > 1; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed_, "perm", i))) % i;
            (order[i - 1], order[j]) = (order[j], order[i - 1]);
        }
    }
}
