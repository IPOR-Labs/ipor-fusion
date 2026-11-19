// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CcipClient, ICcipRouterClient} from "../../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipCrosschainDispatcher} from "../../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipMessages, CcipMsgType} from "../../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipForkBase, CcipForkMessage} from "./CcipForkBase.sol";
import {ICcipTokenPoolFork, ITokenAdminRegistryFork} from "./CcipReturnAbovePoolCapacityForkTest.t.sol";

/// @title CcipExpiredReturnForkBase
/// @notice IL-9621: shared helpers of the fork suites of `flushExpiredReturn()` over the REAL Arbitrum Router, OnRamp
///         and USDC token pool, and the real Ethereum Router and OffRamp on the executor side.
/// @dev The USDC lane to Ethereum has no outbound limiter at the pinned block, so the limiter is set by the pool owner
///      (prank), as in `CcipReturnAbovePoolCapacityForkTest`. The capacity is above the recall and a send of another
///      account takes most of the bucket, so the recall meets `TokenRateLimitReached` (not `TokenMaxCapacityExceeded`)
///      and stays queued at the head. The refill rate is 1 base unit per second, far below the missing amount at any
///      deadline. No statement is made about the inbound limiter. Needs ETHEREUM_PROVIDER_URL and
///      ARBITRUM_PROVIDER_URL (archive nodes). Each concrete suite overrides `_forkBlocks` with blocks that no other
///      suite uses (a shared backend would let one suite's `vm.warp` reach another).
abstract contract CcipExpiredReturnForkBase is CcipForkBase {
    /// @dev The error the live pool returns when the bucket holds less than the amount.
    error TokenRateLimitReached(uint256 minWaitInSeconds, uint256 available, address tokenAddress);

    /// @dev OnRamp 2.0.0 token admin registry of Arbitrum, resolves USDC -> pool proxy.
    address internal constant ARBITRUM_TOKEN_ADMIN_REGISTRY = 0x39AE1032cF4B334a1Ed41cdD0833bdD7c7E7751E;
    /// @dev The CCTP-through-CCV pool behind the proxy for the Ethereum lane (`CCTPThroughCCVTokenPool 2.0.0`).
    address internal constant ARBITRUM_USDC_LANE_POOL = 0x1B8535F5055fF11B3d8f3f74091bdaDB44DFbA14;

    /// @dev Amount of every recall of these suites (USDC, 6 decimals).
    uint256 internal constant RECALL = 15e6;
    /// @dev Outbound capacity set on the lane pool: above `RECALL`, so the recall is limited by the bucket content.
    uint128 internal constant POOL_CAPACITY = 20e6;
    /// @dev What another account sends first: leaves `POOL_CAPACITY - DRAIN` = 10 USDC, below `RECALL`.
    uint256 internal constant DRAIN = 10e6;
    /// @dev The `EXPIRED_RETURN_ATTEMPT_GAS` budget (a private constant of the dispatcher, pinned here by value).
    uint256 internal constant ATTEMPT_BUDGET = 2_000_000;
    /// @dev `InsufficientGasForExpiredReturn.required` = budget + budget / 32.
    uint256 internal constant ATTEMPT_REQUIRED = 2_062_500;
    /// @dev The cold-gas rule of `CcipForkGasTest`: measured * 1.3 <= limit.
    uint256 internal constant MARGIN_NUMERATOR = 13;
    uint256 internal constant MARGIN_DENOMINATOR = 10;

    bytes32 internal constant UNWOUND_TOPIC = keccak256("ReturnExpiredUnwound(bytes32,uint256,uint64)");

    /// @dev Router `gasUsed` and the message gas limit of the last message `_deliver` routed.
    uint256 internal lastGasUsed;
    uint256 internal lastGasLimit;

    function setUp() public {
        _deployStack();
    }

    /// @dev Suites that prove the executor side on the real OffRamp override this.
    function _useOffRamp() internal pure virtual returns (bool) {
        return false;
    }

    function _deliver(CcipForkMessage memory m_, address destRouter_, string memory label_) internal override {
        if (_useOffRamp() && m_.tokenAmount == 0) {
            assertEq(_executeOnOffRamp(m_, destRouter_, 0), 2, string.concat(label_, ": OffRamp execution SUCCESS"));
            lastGasUsed = 0;
            lastGasLimit = m_.ccipReceiveGasLimit;
            return;
        }
        (bool success, bytes memory ret, uint256 gasUsed) = _routeViaRouter(m_, destRouter_, m_.ccipReceiveGasLimit);
        if (!success) {
            emit log_named_bytes(label_, ret);
            fail();
        }
        lastGasUsed = gasUsed;
        lastGasLimit = m_.ccipReceiveGasLimit;
    }

    // ------------------------------------------------------------------ limiter

    /// @dev Sets (or switches off) the outbound limiter of the live lane pool through its owner (both finality modes).
    function _setLaneLimiter(bool enabled_) internal returns (ICcipTokenPoolFork pool) {
        vm.selectFork(arbFork);
        pool = ICcipTokenPoolFork(ARBITRUM_USDC_LANE_POOL);
        ICcipTokenPoolFork.RateLimitConfig memory outbound = ICcipTokenPoolFork.RateLimitConfig({
            isEnabled: enabled_,
            capacity: enabled_ ? POOL_CAPACITY : 0,
            rate: enabled_ ? 1 : 0
        });
        ICcipTokenPoolFork.RateLimitConfig memory off = ICcipTokenPoolFork.RateLimitConfig({
            isEnabled: false,
            capacity: 0,
            rate: 0
        });
        ICcipTokenPoolFork.RateLimitConfigArgs[] memory args = new ICcipTokenPoolFork.RateLimitConfigArgs[](2);
        args[0] = ICcipTokenPoolFork.RateLimitConfigArgs(ETHEREUM_SELECTOR, false, outbound, off);
        args[1] = ICcipTokenPoolFork.RateLimitConfigArgs(ETHEREUM_SELECTOR, true, outbound, off);
        vm.prank(pool.owner());
        pool.setRateLimitConfig(args);
        (ICcipTokenPoolFork.TokenBucket memory bucket, ) = pool.getCurrentRateLimiterState(ETHEREUM_SELECTOR, false);
        assertEq(bucket.isEnabled, enabled_, "outbound limiter state");
    }

    function _tokenMessage(uint256 amount_) internal view returns (CcipClient.EVM2AnyMessage memory) {
        CcipClient.EVMTokenAmount[] memory tokens = new CcipClient.EVMTokenAmount[](1);
        tokens[0] = CcipClient.EVMTokenAmount({token: ARBITRUM_USDC, amount: amount_});
        return
            CcipClient.EVM2AnyMessage({
                receiver: abi.encode(address(executor)),
                data: "",
                tokenAmounts: tokens,
                feeToken: address(0),
                extraArgs: CcipClient.argsToBytes(
                    CcipClient.GenericExtraArgsV2({gasLimit: TOKEN_GAS_LIMIT, allowOutOfOrderExecution: true})
                )
            });
    }

    /// @dev Limits the lane pool and lets another account use up most of the bucket through the real Router: the
    ///      bucket then holds less than `RECALL`, so a recall of `RECALL` is refused with `TokenRateLimitReached`.
    function _limitAndDrainLane() internal {
        _setLaneLimiter(true);
        address drainer = makeAddr("IL-9621-other-sender");
        CcipClient.EVM2AnyMessage memory message = _tokenMessage(DRAIN);
        uint256 fee = ICcipRouterClient(ARBITRUM_ROUTER).getFee(ETHEREUM_SELECTOR, message);
        deal(ARBITRUM_USDC, drainer, DRAIN);
        vm.deal(drainer, fee);
        vm.startPrank(drainer);
        IERC20(ARBITRUM_USDC).approve(ARBITRUM_ROUTER, DRAIN);
        ICcipRouterClient(ARBITRUM_ROUTER).ccipSend{value: fee}(ETHEREUM_SELECTOR, message);
        vm.stopPrank();
        (ICcipTokenPoolFork.TokenBucket memory bucket, ) = ICcipTokenPoolFork(ARBITRUM_USDC_LANE_POOL)
            .getCurrentRateLimiterState(ETHEREUM_SELECTOR, false);
        emit log_named_uint("lane bucket tokens after the other sender", bucket.tokens);
        assertLt(bucket.tokens, RECALL, "the bucket holds less than the recall");
        assertGe(bucket.capacity, RECALL, "capacity is above the recall");
    }

    /// @dev The exact revert bytes the live Router/OnRamp/pool return for a token send of `amount_` from the dispatcher
    ///      (snapshot, nothing persists).
    function _probeRawRevert(uint256 amount_) internal returns (bytes memory ret) {
        uint256 snap = vm.snapshotState();
        vm.startPrank(address(dispatcher));
        IERC20(ARBITRUM_USDC).approve(ARBITRUM_ROUTER, amount_);
        bool ok;
        (ok, ret) = ARBITRUM_ROUTER.call{value: MAX_FEE}(
            abi.encodeCall(ICcipRouterClient.ccipSend, (ETHEREUM_SELECTOR, _tokenMessage(amount_)))
        );
        vm.stopPrank();
        assertFalse(ok, "the real send meets the limiter");
        assertTrue(vm.revertToState(snap));
    }

    // ------------------------------------------------------------------ recall

    /// @dev Requests a recall on Ethereum (data-only message through the real OnRamp).
    /// @return request The captured `RETURN_REQUEST`.
    /// @return operationId The executor's recall operation.
    /// @return deadline The request deadline the executor stamped (its clock + the transfer staleness).
    function _requestRecall() internal returns (CcipForkMessage memory request, bytes32 operationId, uint256 deadline) {
        vm.selectFork(ethFork);
        deadline = block.timestamp + 1 days;
        _startCapture();
        executor.requestAssetsFromDispatcher(ARBITRUM_CHAIN_ID, RECALL, 0, MAX_FEE, FEE_TOKEN, MESSAGE_GAS_LIMIT);
        request = _sendFromExecutor();
        assertEq(uint8(_type(request)), uint8(CcipMsgType.RETURN_REQUEST), "RETURN_REQUEST sent");
        operationId = executor.activeReturn(ARBITRUM_CHAIN_ID);
        assertTrue(operationId != bytes32(0), "recall slot taken");
    }

    /// @dev Delivers a `RETURN_REQUEST` to the Arbitrum dispatcher. The limiter must make it stay queued.
    function _deliverRequest(CcipForkMessage memory request_, uint256 deadline_) internal returns (uint64 queuedId) {
        vm.selectFork(arbFork);
        uint64 tail = dispatcher.responseQueueTail();
        _deliver(request_, ARBITRUM_ROUTER, "dispatcher RETURN_REQUEST");
        assertEq(dispatcher.responseQueueTail(), tail + 1, "one response queued");
        queuedId = tail + 1;
        assertEq(dispatcher.queuedReturnDeadline(queuedId), deadline_, "the request deadline is kept with the entry");
    }

    /// @dev Moves the Arbitrum clock to the first second past `deadline_` (never backwards).
    function _warpPastDeadline(uint256 deadline_) internal {
        vm.selectFork(arbFork);
        uint256 target = deadline_ + 1;
        if (target < block.timestamp) target = block.timestamp;
        vm.warp(target);
    }

    function _unwound(
        Vm.Log[] memory logs_
    ) internal view returns (bool found, bytes32 operationId, uint256 amount, uint64 responseId) {
        for (uint256 i; i < logs_.length; ++i) {
            if (
                logs_[i].emitter == address(dispatcher) &&
                logs_[i].topics.length == 1 &&
                logs_[i].topics[0] == UNWOUND_TOPIC
            ) {
                (operationId, amount, responseId) = abi.decode(logs_[i].data, (bytes32, uint256, uint64));
                return (true, operationId, amount, responseId);
            }
        }
    }

    function _returnPayload(
        CcipForkMessage memory m_
    ) internal pure returns (bytes32 operationId, uint256 amount, uint256 balance, uint64 version) {
        (CcipMsgType messageType, bytes memory payload) = CcipMessages.decode(m_.data);
        require(messageType == CcipMsgType.RETURN_TRANSFER, "RETURN_TRANSFER expected");
        (operationId, amount, balance, version) = abi.decode(payload, (bytes32, uint256, uint256, uint64));
    }

    function _assertWithinMargin(string memory label_) internal {
        emit log_named_uint(string.concat(label_, ": gasUsed"), lastGasUsed);
        emit log_named_uint(string.concat(label_, ": gas limit of the message"), lastGasLimit);
        assertGt(lastGasUsed, 0, string.concat(label_, ": gas measured"));
        assertLe(
            lastGasUsed * MARGIN_NUMERATOR,
            lastGasLimit * MARGIN_DENOMINATOR,
            string.concat(label_, ": measured gas * 1.3 exceeds the message gas limit")
        );
    }

    /// @dev Sets up the Ethereum executor, the Arbitrum dispatcher with 100 USDC idle, a limited and drained lane and
    ///      one recall queued at the dispatcher head (blocked by `TokenRateLimitReached`). Leaves Arbitrum selected.
    function _blockedRecall()
        internal
        returns (CcipForkMessage memory request, bytes32 operationId, uint256 deadline, uint64 head)
    {
        _lifecycleCreateDispatcher();
        _lifecycleSendAsset();
        vm.selectFork(arbFork);
        _limitAndDrainLane();
        (request, operationId, deadline) = _requestRecall();
        head = _deliverRequest(request, deadline);
        assertEq(dispatcher.responseQueueHead(), head, "the recall is the queue head");
    }
}

/// @title CcipExpiredReturnReleaseForkTest
/// @notice IL-9621 K13: with the REAL outbound pool limiter used up by another sender the recall stands at the queue
///         head on `TokenRateLimitReached`; before its deadline nothing can release it, after it `flushExpiredReturn`
///         sends it without tokens through the real OnRamp and the executor (delivered through the real OffRamp)
///         closes the recall with nothing received and nothing debited.
contract CcipExpiredReturnReleaseForkTest is CcipExpiredReturnForkBase {
    /// @dev A fork backend of its own (see `CcipForkBase._forkBlocks`).
    function _forkBlocks() internal pure override returns (uint256, uint256) {
        return (ETHEREUM_FORK_BLOCK + 30, ARBITRUM_FORK_BLOCK + 30);
    }

    function _useOffRamp() internal pure override returns (bool) {
        return true;
    }

    /// @dev Dispatcher values before the release.
    uint256 internal idleQueued;
    uint256 internal usdcBefore;
    uint256 internal accountedBefore;
    uint64 internal versionBefore;

    function testShouldReleaseTheRecallBlockedByTheRealPoolRateLimit() public {
        (, bytes32 operationId, uint256 deadline, uint64 head) = _blockedRecall();
        idleQueued = dispatcher.trackedIdle();
        usdcBefore = IERC20(ARBITRUM_USDC).balanceOf(address(dispatcher));
        versionBefore = dispatcher.stateVersion();
        accountedBefore = dispatcher.accountedBalance();
        assertEq(dispatcher.queuedTokenAmount(), RECALL, "the recall tokens are held in the queue bucket");

        // The live transport returns the pool's own limiter error (not the capacity error) for this send.
        bytes memory raw = _probeRawRevert(RECALL);
        emit log_named_bytes("raw revert bytes of the real send", raw);
        assertEq(bytes4(raw), TokenRateLimitReached.selector, "the pool reports TokenRateLimitReached");

        // Before the deadline (also in its last second) nobody can release it.
        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainDispatcher.ReturnNotExpired.selector, head, deadline));
        dispatcher.flushExpiredReturn();

        _warpPastDeadline(deadline);
        vm.recordLogs();
        assertTrue(dispatcher.flushExpiredReturn(), "released without tokens");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertUnwoundEvent(logs, operationId, head);
        _assertDispatcherAfterRelease(head);
        CcipForkMessage memory zero = _single(_captured(logs, ARBITRUM_ROUTER, ETHEREUM_SELECTOR));
        _assertZeroReturnAndDeliver(zero, operationId);
    }

    function _assertUnwoundEvent(Vm.Log[] memory logs_, bytes32 operationId_, uint64 head_) internal view {
        (bool found, bytes32 loggedOperation, uint256 loggedAmount, uint64 loggedId) = _unwound(logs_);
        assertTrue(found, "ReturnExpiredUnwound emitted");
        assertEq(loggedOperation, operationId_, "event operation");
        assertEq(loggedAmount, RECALL, "event amount");
        assertEq(loggedId, head_, "event response id");
    }

    function _assertDispatcherAfterRelease(uint64 head_) internal view {
        assertEq(dispatcher.responseQueueHead(), 0, "queue drained");
        assertEq(dispatcher.queuedReturnDeadline(head_), 0, "deadline removed with the entry");
        assertEq(dispatcher.queuedTokenAmount(), 0, "queue bucket empty");
        assertEq(dispatcher.trackedIdle(), idleQueued + RECALL, "the tokens are idle again");
        assertEq(dispatcher.stateVersion(), versionBefore, "no new version");
        assertEq(dispatcher.accountedBalance(), accountedBefore, "accounted balance unchanged");
        assertEq(IERC20(ARBITRUM_USDC).balanceOf(address(dispatcher)), usdcBefore, "no USDC left the dispatcher");
    }

    /// @dev The same response left through the real OnRamp without tokens; the executor takes it and closes the recall.
    function _assertZeroReturnAndDeliver(CcipForkMessage memory zero_, bytes32 operationId_) internal {
        assertEq(uint8(_type(zero_)), uint8(CcipMsgType.RETURN_TRANSFER), "RETURN_TRANSFER sent");
        assertEq(zero_.tokenAmount, 0, "no tokens on the released return");
        (bytes32 sentOperation, uint256 sentAmount, , uint64 sentVersion) = _returnPayload(zero_);
        assertEq(sentOperation, operationId_, "same operation");
        assertEq(sentAmount, 0, "zero amount");
        assertEq(sentVersion, versionBefore, "same version");

        vm.selectFork(ethFork);
        uint256 settledBefore = executor.settledRemoteBalance(ARBITRUM_CHAIN_ID);
        uint256 idleLedgerBefore = executor.idleLedger();
        _deliver(zero_, ETHEREUM_ROUTER, "executor RETURN_TRANSFER (zero)");
        assertEq(executor.activeReturn(ARBITRUM_CHAIN_ID), bytes32(0), "recall closed on the executor");
        assertEq(executor.settledRemoteBalance(ARBITRUM_CHAIN_ID), settledBefore, "settled unchanged");
        assertEq(executor.idleLedger(), idleLedgerBefore, "nothing credited to idle");
        assertEq(executor.lastRemoteStateVersion(ARBITRUM_CHAIN_ID), sentVersion, "frontier at the return version");
    }
}

/// @title CcipExpiredReturnPassThroughForkTest
/// @notice IL-9621: the same blocked recall, but the pool owner lifts the limiter before the deadline passes.
///         `flushExpiredReturn` then sends the return with its tokens through the real OnRamp and pool and returns
///         `false`; nothing is rewritten and the executor credits the tokens.
contract CcipExpiredReturnPassThroughForkTest is CcipExpiredReturnForkBase {
    /// @dev A fork backend of its own (see `CcipForkBase._forkBlocks`).
    function _forkBlocks() internal pure override returns (uint256, uint256) {
        return (ETHEREUM_FORK_BLOCK + 31, ARBITRUM_FORK_BLOCK + 31);
    }

    /// @dev Dispatcher values before the flush.
    uint256 internal idleQueued;
    uint256 internal usdcBefore;
    uint64 internal versionBefore;

    function testShouldSendTheExpiredReturnWithItsTokensWhenTheLimiterLetsItThrough() public {
        (, bytes32 operationId, uint256 deadline, uint64 head) = _blockedRecall();
        idleQueued = dispatcher.trackedIdle();
        versionBefore = dispatcher.stateVersion();
        usdcBefore = IERC20(ARBITRUM_USDC).balanceOf(address(dispatcher));

        _setLaneLimiter(false);
        _warpPastDeadline(deadline);
        vm.recordLogs();
        assertFalse(dispatcher.flushExpiredReturn(), "sent with its tokens, not unwound");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool found, , , ) = _unwound(logs);
        assertFalse(found, "no ReturnExpiredUnwound");
        assertEq(dispatcher.responseQueueHead(), 0, "queue drained");
        assertEq(dispatcher.queuedReturnDeadline(head), 0, "deadline removed with the entry");
        assertEq(dispatcher.queuedTokenAmount(), 0, "queue bucket empty");
        assertEq(dispatcher.trackedIdle(), idleQueued, "idle untouched, the tokens left");
        assertEq(dispatcher.stateVersion(), versionBefore, "no new version");
        assertEq(
            usdcBefore - IERC20(ARBITRUM_USDC).balanceOf(address(dispatcher)),
            RECALL,
            "the recall left the dispatcher with the message"
        );
        _assertTokenReturnAndDeliver(_single(_captured(logs, ARBITRUM_ROUTER, ETHEREUM_SELECTOR)), operationId);
    }

    /// @dev The return left through the real OnRamp and pool with its tokens; the executor credits them.
    function _assertTokenReturnAndDeliver(CcipForkMessage memory back_, bytes32 operationId_) internal {
        assertEq(uint8(_type(back_)), uint8(CcipMsgType.RETURN_TRANSFER), "RETURN_TRANSFER sent");
        assertEq(back_.destToken, ETHEREUM_USDC, "the real pool maps the tokens to Ethereum USDC");
        assertGt(back_.tokenAmount, 0, "tokens ride the message");
        (bytes32 sentOperation, uint256 sentAmount, , ) = _returnPayload(back_);
        assertEq(sentOperation, operationId_, "same operation");
        assertEq(sentAmount, RECALL, "full amount");

        vm.selectFork(ethFork);
        uint256 idleLedgerBefore = executor.idleLedger();
        _deliver(back_, ETHEREUM_ROUTER, "executor RETURN_TRANSFER (tokens)");
        assertEq(executor.activeReturn(ARBITRUM_CHAIN_ID), bytes32(0), "recall closed on the executor");
        assertEq(executor.idleLedger(), idleLedgerBefore + back_.tokenAmount, "the tokens are credited to idle");
    }
}

/// @title CcipExpiredReturnBudgetForkTest
/// @notice IL-9621 D4 calibration: the attempt budget `EXPIRED_RETURN_ATTEMPT_GAS` (2,000,000) has to be at least twice
///         the cold cost of a SUCCESSFUL token-bearing send over the real Router, OnRamp and USDC pool. Measured as
///         the gas of the self-call `dispatchResponseSelf` (the attempt itself) and of the whole
///         `flushExpiredReturn`, each as a transaction of its own (isolate mode, every address and slot cold).
/// @dev The measurement of an isolated transaction includes its intrinsic gas, which makes it an upper bound of what
///      the attempt costs inside `flushExpiredReturn`, where the head slot is already warm.
/// forge-config: default.isolate = true
contract CcipExpiredReturnBudgetForkTest is CcipExpiredReturnForkBase {
    /// @dev A fork backend of its own (see `CcipForkBase._forkBlocks`).
    function _forkBlocks() internal pure override returns (uint256, uint256) {
        return (ETHEREUM_FORK_BLOCK + 32, ARBITRUM_FORK_BLOCK + 32);
    }

    function testShouldKeepTwiceTheColdCostOfASuccessfulTokenSendWithinTheAttemptBudget() public {
        (, , uint256 deadline, uint64 head) = _blockedRecall();
        _setLaneLimiter(false);
        _warpPastDeadline(deadline);
        uint256 usdcBefore = IERC20(ARBITRUM_USDC).balanceOf(address(dispatcher));

        uint256 snap = vm.snapshotState();
        vm.prank(address(dispatcher));
        dispatcher.dispatchResponseSelf(head);
        uint256 attemptGas = vm.lastCallGas().gasTotalUsed;
        assertEq(
            usdcBefore - IERC20(ARBITRUM_USDC).balanceOf(address(dispatcher)),
            RECALL,
            "the measured attempt is a successful send with tokens"
        );
        assertTrue(vm.revertToState(snap));

        assertFalse(dispatcher.flushExpiredReturn(), "the whole call also sends with tokens");
        uint256 flushGas = vm.lastCallGas().gasTotalUsed;
        assertEq(
            usdcBefore - IERC20(ARBITRUM_USDC).balanceOf(address(dispatcher)),
            RECALL,
            "flushExpiredReturn sent the tokens"
        );

        emit log_named_uint("cold successful token attempt (dispatchResponseSelf)", attemptGas);
        emit log_named_uint("x 2", attemptGas * 2);
        emit log_named_uint("whole flushExpiredReturn (cold)", flushGas);
        emit log_named_uint("EXPIRED_RETURN_ATTEMPT_GAS (B)", ATTEMPT_BUDGET);
        assertGt(attemptGas, 100_000, "a real token send was measured");
        assertLe(attemptGas * 2, ATTEMPT_BUDGET, "cold cost of a successful token-bearing attempt x 2 <= B");
        assertLe(flushGas, ATTEMPT_BUDGET + 200_000, "the whole call stays close to the budget");
    }
}

/// @title CcipExpiredReturnColdGasForkTest
/// @notice IL-9621 K12 (fork part): cold gas, over the real Router, of the receiver handlers this change touches, each
///         against the gas limit its message carries with the `CcipForkGasTest` margin (measured * 1.3 <= limit):
///         the dispatcher accepting a `RETURN_REQUEST` that stays queued (the deadline write), the executor taking the
///         zero return of an active recall, and the executor taking the zero return of a cancelled recall from the
///         middle of the cancelled list.
/// @dev Every top-level call is a transaction of its own (isolate mode), so every address and slot is cold.
/// forge-config: default.isolate = true
contract CcipExpiredReturnColdGasForkTest is CcipExpiredReturnForkBase {
    /// @dev A fork backend of its own (see `CcipForkBase._forkBlocks`).
    function _forkBlocks() internal pure override returns (uint256, uint256) {
        return (ETHEREUM_FORK_BLOCK + 33, ARBITRUM_FORK_BLOCK + 33);
    }

    /// @dev Releases the queue head after the deadline and returns the zero return it sent.
    function _releaseHead(uint256 deadline_) internal returns (CcipForkMessage memory zero) {
        _warpPastDeadline(deadline_);
        vm.recordLogs();
        assertTrue(dispatcher.flushExpiredReturn(), "released without tokens");
        zero = _single(_captured(vm.getRecordedLogs(), ARBITRUM_ROUTER, ETHEREUM_SELECTOR));
        assertEq(zero.tokenAmount, 0, "no tokens on the released return");
    }

    function testShouldFitTheTouchedHandlersInTheirGasLimitsWhenCold() public {
        // (1) RETURN_REQUEST accepted by the dispatcher and left queued: the deadline write is on this path.
        (CcipForkMessage memory requestA, , uint256 deadlineA, ) = _blockedRecall();
        _assertWithinMargin("dispatcher RETURN_REQUEST (queued, deadline write)");
        // The measured delivery is the one `_blockedRecall` made last.
        assertEq(requestA.ccipReceiveGasLimit, MESSAGE_GAS_LIMIT, "request carries the route message gas limit");

        // (2) The zero return of an ACTIVE recall at the executor.
        CcipForkMessage memory zeroA = _releaseHead(deadlineA);
        assertEq(zeroA.ccipReceiveGasLimit, MESSAGE_GAS_LIMIT, "zero return carries the route message gas limit");
        uint256 arbitrumNow = block.timestamp;
        vm.selectFork(ethFork);
        assertTrue(executor.activeReturn(ARBITRUM_CHAIN_ID) != bytes32(0), "the recall is still active");
        _deliver(zeroA, ETHEREUM_ROUTER, "executor zero RETURN_TRANSFER (active recall)");
        assertEq(executor.activeReturn(ARBITRUM_CHAIN_ID), bytes32(0), "recall closed");
        _assertWithinMargin("executor zero RETURN_TRANSFER (active recall)");
        // The Arbitrum clock is a day ahead now: bring Ethereum to it, or the next requests would carry deadlines the
        // dispatcher has already passed (EXPIRED).
        vm.warp(arbitrumNow);

        // (3) Three recalls, each cancelled right away on the executor; the requests reach the dispatcher in the order
        // 2, 1, 3, so the first return that can be delivered in version order is the one of the MIDDLE recall.
        CcipForkMessage[3] memory requests;
        bytes32[3] memory operations;
        uint256 lastDeadline;
        for (uint256 i; i < 3; ++i) {
            uint256 deadline;
            (requests[i], operations[i], deadline) = _requestRecall();
            executor.cancelPendingReturn(ARBITRUM_CHAIN_ID);
            assertEq(executor.activeReturn(ARBITRUM_CHAIN_ID), bytes32(0), "cancelled, slot free");
            lastDeadline = deadline;
        }
        assertEq(executor.cancelledRecallCount(ARBITRUM_CHAIN_ID), 3, "three cancelled recalls, oldest first");
        uint8[3] memory order = [1, 0, 2];
        for (uint256 i; i < 3; ++i) {
            vm.selectFork(arbFork);
            uint64 tail = dispatcher.responseQueueTail();
            _deliver(requests[order[i]], ARBITRUM_ROUTER, "dispatcher RETURN_REQUEST (cancelled recall)");
            assertEq(dispatcher.responseQueueTail(), tail + 1, "queued behind the earlier recalls");
            assertTrue(dispatcher.queuedReturnDeadline(tail + 1) != 0, "deadline kept");
        }
        CcipForkMessage memory zeroMiddle = _releaseHead(lastDeadline);
        (bytes32 releasedOperation, , , ) = _returnPayload(zeroMiddle);
        assertEq(releasedOperation, operations[1], "the released head is the middle recall");

        vm.selectFork(ethFork);
        _deliver(zeroMiddle, ETHEREUM_ROUTER, "executor zero RETURN_TRANSFER (cancelled, middle of the list)");
        assertEq(executor.cancelledRecallCount(ARBITRUM_CHAIN_ID), 2, "the middle recall left the cancelled list");
        _assertWithinMargin("executor zero RETURN_TRANSFER (cancelled, middle of the list)");
    }
}

/// @title CcipExpiredReturnCallerGasForkTest
/// @notice IL-9621 K9 (fork part): a sweep of the caller's gas limit over `flushExpiredReturn` with the REAL Router,
///         OnRamp and USDC pool when the limiter lets the return through. Below the required gas the call reverts with
///         `InsufficientGasForExpiredReturn`; with enough gas it sends with the tokens and returns `false`; at no limit
///         does it return `true`, and a return that is sent really takes the tokens with it.
contract CcipExpiredReturnCallerGasForkTest is CcipExpiredReturnForkBase {
    /// @dev A fork backend of its own (see `CcipForkBase._forkBlocks`).
    function _forkBlocks() internal pure override returns (uint256, uint256) {
        return (ETHEREUM_FORK_BLOCK + 34, ARBITRUM_FORK_BLOCK + 34);
    }

    function testShouldNeverUnwindWhenTheLimiterLetsTheReturnThroughWhateverTheCallerGas() public {
        (, , uint256 deadline, ) = _blockedRecall();
        _setLaneLimiter(false);
        _warpPastDeadline(deadline);
        uint256 usdcBefore = IERC20(ARBITRUM_USDC).balanceOf(address(dispatcher));

        uint256[12] memory limits = [
            uint256(500_000),
            1_000_000,
            2_000_000,
            2_062_499,
            2_062_500,
            2_100_000,
            2_150_000,
            2_500_000,
            3_000_000,
            6_000_000,
            15_000_000,
            30_000_000
        ];
        uint256 sent;
        uint256 refused;
        for (uint256 i; i < limits.length; ++i) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = address(dispatcher).call{gas: limits[i]}(
                abi.encodeCall(CcipCrosschainDispatcher.flushExpiredReturn, ())
            );
            if (ok) {
                assertFalse(abi.decode(ret, (bool)), "never unwound while the limiter lets the return through");
                assertEq(
                    usdcBefore - IERC20(ARBITRUM_USDC).balanceOf(address(dispatcher)),
                    RECALL,
                    "a returned call took the tokens with it"
                );
                ++sent;
            } else {
                assertEq(
                    bytes4(ret),
                    CcipCrosschainDispatcher.InsufficientGasForExpiredReturn.selector,
                    "the only refusal is the gas check"
                );
                assertGt(ret.length, 4, "error arguments present");
                (, uint256 required) = abi.decode(_tail(ret), (uint256, uint256));
                assertEq(required, ATTEMPT_REQUIRED, "required = budget + budget / 32");
                assertEq(
                    IERC20(ARBITRUM_USDC).balanceOf(address(dispatcher)),
                    usdcBefore,
                    "a refused call moved no tokens"
                );
                ++refused;
            }
            emit log_named_uint(ok ? "caller gas limit (sent with tokens)" : "caller gas limit (refused)", limits[i]);
            if (limits[i] < ATTEMPT_REQUIRED) assertFalse(ok, "below the required gas the call reverts");
            if (limits[i] >= 2_500_000) assertTrue(ok, "with plenty of gas the return is sent");
            assertTrue(vm.revertToState(snap));
        }
        assertGt(refused, 0, "the sweep reached the gas check");
        assertGt(sent, 0, "the sweep reached a successful token send");
    }

    function _tail(bytes memory error_) internal pure returns (bytes memory out) {
        out = new bytes(error_.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = error_[i + 4];
        }
    }
}
