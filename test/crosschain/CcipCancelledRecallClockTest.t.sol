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
///         any time (IL-8496).
contract CcipCancelledRecallClockTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    uint256 internal constant STALENESS = 1 days;

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

    /// @notice Two cancelled recalls; the OLDER one resolves first. The clock must stay (anchored on the older
    ///         createdAt, documented as not re-anchored). Kills "clear on the first resolution".
    function testShouldKeepClockUntilLastCancelledRecallResolves() public {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        uint256 firstAt = block.timestamp;
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 10e18, 0, 0, address(0), 500_000);
        router.deliverHeld(0); // first RETURN_TRANSFER held at index 1
        executor.cancelPendingReturn(REMOTE_CHAIN);
        vm.warp(firstAt + STALENESS / 2);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 1e18, 0, 0, address(0), 500_000); // request held at index 2
        executor.cancelPendingReturn(REMOTE_CHAIN);
        router.deliverHeld(1); // the first recall's late return lands
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), firstAt, "not re-anchored");
        assertEq(executor.cancelledRecallLatestAt(REMOTE_CHAIN), firstAt + STALENESS / 2, "still the newest createdAt");
        vm.warp(firstAt + STALENESS + 1);
        _expectStale(firstAt);
        executor.getBalance();
    }
}
