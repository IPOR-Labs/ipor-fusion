// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CcipClient, ICcipRouterClient} from "../../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipReturnRejectReason} from "../../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipMsgType} from "../../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipForkBase, CcipForkMessage} from "./CcipForkBase.sol";

/// @notice CCIP 2.0 token pool surface used to read and set the outbound limiter of the live Arbitrum USDC pool.
interface ICcipTokenPoolFork {
    struct TokenBucket {
        uint128 tokens;
        uint32 lastUpdated;
        bool isEnabled;
        uint128 capacity;
        uint128 rate;
    }

    struct RateLimitConfig {
        bool isEnabled;
        uint128 capacity;
        uint128 rate;
    }

    struct RateLimitConfigArgs {
        uint64 remoteChainSelector;
        bool customBlockConfirmation;
        RateLimitConfig outboundRateLimiterConfig;
        RateLimitConfig inboundRateLimiterConfig;
    }

    function typeAndVersion() external view returns (string memory);
    function owner() external view returns (address);
    function setRateLimitConfig(RateLimitConfigArgs[] calldata args_) external;
    function getCurrentRateLimiterState(
        uint64 remoteChainSelector_,
        bool customBlockConfirmation_
    ) external view returns (TokenBucket memory outbound, TokenBucket memory inbound);
}

/// @notice The USDC pool proxy of Arbitrum: resolves the pool that serves a lane.
interface IUsdcPoolProxyFork {
    function typeAndVersion() external view returns (string memory);
}

interface ITokenAdminRegistryFork {
    function getPool(address token_) external view returns (address);
}

/// @title CcipReturnAbovePoolCapacityForkTest
/// @notice IL-9156 / ccip-disp C-011: the IL-8553 pool-capacity unwind over the REAL Arbitrum Router, OnRamp and
///         USDC token pool. The unit suite injects the `TokenMaxCapacityExceeded` bytes through a mock router, so it
///         cannot show that the live transport lets the pool's own revert reach `_returnAssets` unchanged. Here a
///         recall above the lane's outbound limiter meets an empty queue on a fork.
/// @dev The USDC lane to Ethereum has no outbound limiter configured at the pinned block (capacity 0, disabled), so
///      the limiter is set by the pool owner (prank), which is also what an operator would do. Needs
///      ETHEREUM_PROVIDER_URL and ARBITRUM_PROVIDER_URL (archive nodes).
contract CcipReturnAbovePoolCapacityForkTest is CcipForkBase {
    /// @dev A send failure of at least 100 bytes whose selector is NOT `TokenMaxCapacityExceeded` (4 + 4 * 32 = 132 B).
    error ForkOtherSendFailure(bytes32 a, bytes32 b, bytes32 c, bytes32 d);

    /// @dev OnRamp 2.0.0 token admin registry of Arbitrum (OnRamp static config), resolves USDC -> pool proxy.
    address internal constant ARBITRUM_TOKEN_ADMIN_REGISTRY = 0x39AE1032cF4B334a1Ed41cdD0833bdD7c7E7751E;
    /// @dev The CCTP-through-CCV pool behind the proxy for the Ethereum lane (`CCTPThroughCCVTokenPool 2.0.0`).
    address internal constant ARBITRUM_USDC_LANE_POOL = 0x1B8535F5055fF11B3d8f3f74091bdaDB44DFbA14;
    bytes4 internal constant TOKEN_MAX_CAPACITY_EXCEEDED = 0x1a76572a;
    uint128 internal constant POOL_CAPACITY = 10e6;

    bytes32 internal constant CAPACITY_EVENT_TOPIC =
        keccak256("ReturnAboveLocalPoolCapacity(bytes32,uint256,uint256,uint64)");
    bytes32 internal constant SKIPPED_TOPIC = keccak256("ResponseSkipped(uint64,uint256)");
    bytes32 internal constant QUEUED_TOPIC = keccak256("ReturnQueued(bytes32,uint256,uint64)");
    bytes32 internal constant DISPATCHER_REJECTED_TOPIC = keccak256("ReturnRejected(bytes32,uint8,uint64)");
    bytes32 internal constant EXECUTOR_REJECTED_TOPIC = keccak256("ReturnRejected(uint256,bytes32,uint8)");

    /// @dev A fork backend of its own (see `CcipForkBase._forkBlocks`).
    function _forkBlocks() internal pure override returns (uint256, uint256) {
        return (ETHEREUM_FORK_BLOCK + 20, ARBITRUM_FORK_BLOCK + 20);
    }

    function setUp() public {
        _deployStack();
    }

    function _deliver(CcipForkMessage memory m_, address destRouter_, string memory label_) internal override {
        if (m_.tokenAmount != 0) {
            (bool success, bytes memory ret, ) = _routeViaRouter(m_, destRouter_, m_.ccipReceiveGasLimit);
            if (!success) {
                emit log_named_bytes(label_, ret);
                fail();
            }
            return;
        }
        uint8 state = _executeOnOffRamp(m_, destRouter_, 0);
        assertEq(state, 2, string.concat(label_, ": OffRamp execution state SUCCESS"));
    }

    /// @dev Sets the outbound (and inbound) limiter of the live lane pool through its owner; returns the pool.
    function _limitLanePool() internal returns (ICcipTokenPoolFork pool) {
        address proxy = ITokenAdminRegistryFork(ARBITRUM_TOKEN_ADMIN_REGISTRY).getPool(ARBITRUM_USDC);
        emit log_named_address("USDC pool proxy", proxy);
        emit log_named_string("USDC pool proxy version", IUsdcPoolProxyFork(proxy).typeAndVersion());
        pool = ICcipTokenPoolFork(ARBITRUM_USDC_LANE_POOL);
        emit log_named_string("lane pool version", pool.typeAndVersion());
        ICcipTokenPoolFork.RateLimitConfig memory limit = ICcipTokenPoolFork.RateLimitConfig({
            isEnabled: true,
            capacity: POOL_CAPACITY,
            rate: 1
        });
        ICcipTokenPoolFork.RateLimitConfig memory off = ICcipTokenPoolFork.RateLimitConfig({
            isEnabled: false,
            capacity: 0,
            rate: 0
        });
        ICcipTokenPoolFork.RateLimitConfigArgs[] memory args = new ICcipTokenPoolFork.RateLimitConfigArgs[](2);
        args[0] = ICcipTokenPoolFork.RateLimitConfigArgs(ETHEREUM_SELECTOR, false, limit, off);
        args[1] = ICcipTokenPoolFork.RateLimitConfigArgs(ETHEREUM_SELECTOR, true, limit, off);
        (ICcipTokenPoolFork.TokenBucket memory before_, ) = pool.getCurrentRateLimiterState(ETHEREUM_SELECTOR, false);
        emit log_named_uint("outbound capacity before (default finality)", before_.capacity);
        emit log_named_uint("outbound enabled before", before_.isEnabled ? 1 : 0);
        vm.prank(pool.owner());
        pool.setRateLimitConfig(args);
        (ICcipTokenPoolFork.TokenBucket memory outbound, ) = pool.getCurrentRateLimiterState(ETHEREUM_SELECTOR, false);
        assertTrue(outbound.isEnabled, "outbound limiter enabled");
        assertEq(outbound.capacity, POOL_CAPACITY, "outbound capacity set");
        emit log_named_uint("outbound capacity after", outbound.capacity);
    }

    /// @dev The exact revert bytes the live Router/OnRamp/pool return for a token send above the capacity, as the
    ///      dispatcher would see them (the send is made from the dispatcher address with its own USDC).
    function _probeRawRevert(uint256 amount_) internal returns (bytes memory ret) {
        CcipClient.EVMTokenAmount[] memory tokens = new CcipClient.EVMTokenAmount[](1);
        tokens[0] = CcipClient.EVMTokenAmount({token: ARBITRUM_USDC, amount: amount_});
        CcipClient.EVM2AnyMessage memory message = CcipClient.EVM2AnyMessage({
            receiver: abi.encode(address(executor)),
            data: "",
            tokenAmounts: tokens,
            feeToken: address(0),
            extraArgs: CcipClient.argsToBytes(
                CcipClient.GenericExtraArgsV2({gasLimit: TOKEN_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });
        vm.startPrank(address(dispatcher));
        IERC20(ARBITRUM_USDC).approve(ARBITRUM_ROUTER, amount_);
        bool ok;
        (ok, ret) = ARBITRUM_ROUTER.call{value: MAX_FEE}(
            abi.encodeCall(ICcipRouterClient.ccipSend, (ETHEREUM_SELECTOR, message))
        );
        vm.stopPrank();
        assertFalse(ok, "the real send above the capacity reverts");
    }

    function testShouldUnwindARecallAboveTheRealUsdcPoolCapacity() public {
        _lifecycleCreateDispatcher();
        uint256 delivered = _lifecycleSendAsset();
        assertGt(delivered, RECALL_AMOUNT, "idle above the recall");

        // Recall is requested on Ethereum (data-only message through the real OnRamp).
        vm.selectFork(ethFork);
        _startCapture();
        executor.requestAssetsFromDispatcher(
            ARBITRUM_CHAIN_ID,
            RECALL_AMOUNT,
            0,
            MAX_FEE,
            FEE_TOKEN,
            MESSAGE_GAS_LIMIT
        );
        CcipForkMessage memory request = _sendFromExecutor();
        assertEq(uint8(_type(request)), uint8(CcipMsgType.RETURN_REQUEST));
        bytes32 operationId = executor.activeReturn(ARBITRUM_CHAIN_ID);
        assertTrue(operationId != bytes32(0), "recall slot taken");

        // The recall is delivered to the dispatcher on Arbitrum with the live lane limited below the amount.
        vm.selectFork(arbFork);
        _limitLanePool();
        uint256 idleBefore = dispatcher.trackedIdle();
        uint64 versionBefore = dispatcher.stateVersion();
        uint64 tailBefore = dispatcher.responseQueueTail();
        uint256 queuedBefore = dispatcher.queuedTokenAmount();
        uint256 usdcBefore = IERC20(ARBITRUM_USDC).balanceOf(address(dispatcher));
        assertEq(dispatcher.responseQueueHead(), 0, "queue starts empty");

        // What the dispatcher's send meets on the live transport (snapshot, nothing persists).
        uint256 snap = vm.snapshotState();
        bytes memory raw = _probeRawRevert(RECALL_AMOUNT);
        emit log_named_bytes("raw revert bytes of the real send", raw);
        assertTrue(raw.length >= 100, "at least 100 bytes");
        assertEq(bytes4(raw), TOKEN_MAX_CAPACITY_EXCEEDED, "pool error reaches the caller unwrapped");
        assertTrue(vm.revertToState(snap));

        vm.recordLogs();
        _deliver(request, ARBITRUM_ROUTER, "dispatcher RETURN_REQUEST (above capacity)");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(dispatcher.trackedIdle(), idleBefore, "idle untouched");
        assertEq(dispatcher.stateVersion(), versionBefore, "no version bump");
        assertEq(dispatcher.queuedTokenAmount(), queuedBefore, "no queue credit");
        assertEq(dispatcher.responseQueueHead(), 0, "queue drained");
        assertEq(dispatcher.responseQueueTail(), tailBefore + 2, "two ids consumed: dropped return, then rejection");
        assertEq(IERC20(ARBITRUM_USDC).balanceOf(address(dispatcher)), usdcBefore, "no USDC left the dispatcher");
        assertTrue(dispatcher.processedOperation(operationId), "operation marked processed");

        bool sawCapacity;
        bool sawSkipped;
        bool sawRejected;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(dispatcher) || logs[i].topics.length != 1) continue;
            if (logs[i].topics[0] == CAPACITY_EVENT_TOPIC) {
                (, uint256 amount, uint256 capacity, uint64 droppedId) = abi.decode(
                    logs[i].data,
                    (bytes32, uint256, uint256, uint64)
                );
                assertEq(amount, RECALL_AMOUNT, "event amount");
                assertEq(capacity, POOL_CAPACITY, "event capacity is the live pool capacity");
                assertEq(droppedId, tailBefore + 1, "event carries the dropped response id");
                sawCapacity = true;
            } else if (logs[i].topics[0] == SKIPPED_TOPIC) {
                (uint64 skippedId, uint256 skippedAmount) = abi.decode(logs[i].data, (uint64, uint256));
                assertEq(skippedId, tailBefore + 1, "ResponseSkipped id");
                assertEq(skippedAmount, RECALL_AMOUNT, "ResponseSkipped amount");
                sawSkipped = true;
            } else if (logs[i].topics[0] == DISPATCHER_REJECTED_TOPIC) {
                (, uint8 reason, ) = abi.decode(logs[i].data, (bytes32, uint8, uint64));
                assertEq(reason, uint8(CcipReturnRejectReason.ABOVE_POOL_CAPACITY), "dispatcher reason");
                sawRejected = true;
            } else {
                assertTrue(logs[i].topics[0] != QUEUED_TOPIC, "the recall was not queued");
            }
        }
        assertTrue(sawCapacity, "ReturnAboveLocalPoolCapacity emitted");
        assertTrue(sawSkipped, "ResponseSkipped emitted");
        assertTrue(sawRejected, "dispatcher ReturnRejected emitted");

        // The rejection leaves through the real OnRamp (no token) and reaches the executor.
        CcipForkMessage[] memory sent = _captured(logs, ARBITRUM_ROUTER, ETHEREUM_SELECTOR);
        CcipForkMessage memory rejection = _single(sent);
        assertEq(uint8(_type(rejection)), uint8(CcipMsgType.RETURN_REJECTED), "RETURN_REJECTED sent");
        assertEq(rejection.tokenAmount, 0, "no tokens on the rejection");

        vm.selectFork(ethFork);
        vm.recordLogs();
        _deliver(rejection, ETHEREUM_ROUTER, "executor RETURN_REJECTED");
        Vm.Log[] memory executorLogs = vm.getRecordedLogs();
        assertEq(executor.activeReturn(ARBITRUM_CHAIN_ID), bytes32(0), "executor recall record cleared");
        bool sawExecutorReject;
        for (uint256 i; i < executorLogs.length; ++i) {
            if (executorLogs[i].emitter == address(executor) && executorLogs[i].topics[0] == EXECUTOR_REJECTED_TOPIC) {
                (, , uint8 reason) = abi.decode(executorLogs[i].data, (uint256, bytes32, uint8));
                assertEq(reason, uint8(CcipReturnRejectReason.ABOVE_POOL_CAPACITY), "executor reason");
                sawExecutorReject = true;
            }
        }
        assertTrue(sawExecutorReject, "executor ReturnRejected emitted");
    }

    /// @dev Pins the selector half of the capacity branch in `_returnAssets`: a send that fails with a LONG (>= 100 B)
    ///      revert of another selector must keep the recall queued (the transient/other-failure path), not unwind it.
    ///      The Router's `ccipSend` is the call `dispatchResponseSelf` makes inside the dispatcher's
    ///      `try this.dispatchResponseSelf(..)`, so mocking its revert is what `_tryDispatchHead` catches.
    ///      Without the `bytes4(reason) == TOKEN_MAX_CAPACITY_EXCEEDED_SELECTOR` check the 132-byte reason would
    ///      take the capacity branch and this test would see `ReturnAboveLocalPoolCapacity`, a dropped head and a
    ///      `RETURN_REJECTED` instead of a queued recall.
    function testShouldKeepARecallQueuedWhenTheSendFailsWithALongNonCapacityRevert() public {
        _lifecycleCreateDispatcher();
        uint256 delivered = _lifecycleSendAsset();
        assertGt(delivered, RECALL_AMOUNT, "idle above the recall");

        vm.selectFork(ethFork);
        _startCapture();
        executor.requestAssetsFromDispatcher(
            ARBITRUM_CHAIN_ID,
            RECALL_AMOUNT,
            0,
            MAX_FEE,
            FEE_TOKEN,
            MESSAGE_GAS_LIMIT
        );
        CcipForkMessage memory request = _sendFromExecutor();
        assertEq(uint8(_type(request)), uint8(CcipMsgType.RETURN_REQUEST));
        bytes32 operationId = executor.activeReturn(ARBITRUM_CHAIN_ID);

        vm.selectFork(arbFork);
        uint256 idleBefore = dispatcher.trackedIdle();
        uint64 versionBefore = dispatcher.stateVersion();
        uint64 tailBefore = dispatcher.responseQueueTail();
        uint256 queuedBefore = dispatcher.queuedTokenAmount();
        assertEq(dispatcher.responseQueueHead(), 0, "queue starts empty");

        bytes memory failure = abi.encodeWithSelector(
            ForkOtherSendFailure.selector,
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            bytes32(uint256(4))
        );
        assertGe(failure.length, 100, "at least 100 bytes");
        assertTrue(bytes4(failure) != TOKEN_MAX_CAPACITY_EXCEEDED, "not the capacity selector");
        vm.mockCallRevert(ARBITRUM_ROUTER, abi.encodeWithSelector(ICcipRouterClient.ccipSend.selector), failure);

        vm.recordLogs();
        _deliver(request, ARBITRUM_ROUTER, "dispatcher RETURN_REQUEST (other send failure)");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The recall stands and waits at the head for a retry; the pool-capacity unwind did not happen.
        uint256 amountSD = idleBefore - dispatcher.trackedIdle();
        assertGt(amountSD, 0, "trackedIdle stays debited");
        assertEq(dispatcher.queuedTokenAmount(), queuedBefore + amountSD, "queue credited with the recall");
        assertEq(dispatcher.stateVersion(), versionBefore + 1, "version committed");
        assertEq(dispatcher.responseQueueHead(), tailBefore + 1, "recall is still the queue head");
        assertEq(dispatcher.responseQueueTail(), tailBefore + 1, "only one id consumed, no rejection queued");
        assertTrue(dispatcher.processedOperation(operationId), "operation marked processed");

        bool sawQueued;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(dispatcher) || logs[i].topics.length != 1) continue;
            bytes32 topic = logs[i].topics[0];
            assertTrue(topic != CAPACITY_EVENT_TOPIC, "no capacity unwind");
            assertTrue(topic != SKIPPED_TOPIC, "head not dropped");
            assertTrue(topic != DISPATCHER_REJECTED_TOPIC, "recall not rejected");
            if (topic == QUEUED_TOPIC) {
                (, uint256 amount, uint64 responseId) = abi.decode(logs[i].data, (bytes32, uint256, uint64));
                assertEq(amount, RECALL_AMOUNT, "queued amount");
                assertEq(responseId, tailBefore + 1, "queued response id");
                sawQueued = true;
            }
        }
        assertTrue(sawQueued, "ReturnQueued emitted");
    }
}
