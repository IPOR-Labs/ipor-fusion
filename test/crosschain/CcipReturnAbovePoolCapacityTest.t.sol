// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {
    CcipCrosschainDispatcher,
    CcipReturnRejectReason
} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

contract CapToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipReturnAbovePoolCapacityTest
/// @notice IL-8553: a recall above the local token pool's outbound rate-limit CAPACITY can never be sent, so the
///         dispatcher answers it `RETURN_REJECTED(ABOVE_POOL_CAPACITY)` before any value moves instead of parking
///         it at the head of the response queue forever. A transient `TokenRateLimitReached`, any other send
///         failure, and a recall behind an occupied queue head keep the queue-and-retry behaviour.
contract CcipReturnAbovePoolCapacityTest is Test {
    event ReturnAboveLocalPoolCapacity(bytes32 operationId, uint256 amount, uint256 capacity, uint64 responseId);

    error TokenMaxCapacityExceeded(uint256 capacity, uint256 requested, address tokenAddress);
    error TokenRateLimitReached(uint256 minWaitInSeconds, uint256 available, address tokenAddress);

    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    uint256 internal constant CAPACITY = 50e18;
    uint256 internal constant RECALL = 60e18;

    bytes32 internal constant CAPACITY_EVENT_TOPIC = keccak256("ReturnAboveLocalPoolCapacity(bytes32,uint256,uint256,uint64)");
    bytes32 internal constant SKIPPED_TOPIC = keccak256("ResponseSkipped(uint64,uint256)");
    bytes32 internal constant DISPATCHER_REJECTED_TOPIC = keccak256("ReturnRejected(bytes32,uint8,uint64)");
    bytes32 internal constant EXECUTOR_REJECTED_TOPIC = keccak256("ReturnRejected(uint256,bytes32,uint8)");

    MockCcipRouter internal router;
    CapToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new CapToken();
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

    // ------------------------------------------------------------------ helpers

    function _fund() internal {
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 500_000);
        _attestBalance(100e18);
    }

    function _attestBalance(uint256 balance_) internal {
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

    function _capacityRevert() internal view returns (bytes memory) {
        return abi.encodeWithSelector(TokenMaxCapacityExceeded.selector, CAPACITY, RECALL, address(token));
    }

    function _recall() internal {
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, RECALL, RECALL, 0, address(0), 500_000);
    }

    // ------------------------------------------------------------------ tests

    function testShouldRejectRecallAboveLocalPoolCapacityWithoutMovingValue() public {
        _fund();
        uint256 idleBefore = dispatcher.trackedIdle();
        uint64 versionBefore = dispatcher.stateVersion();
        uint256 queuedBefore = dispatcher.queuedTokenAmount();
        uint64 tailBefore = dispatcher.responseQueueTail();
        uint256 navBefore = executor.getBalance();
        uint256 settledBefore = executor.settledRemoteBalance(REMOTE_CHAIN);
        uint256 accountedBefore = dispatcher.accountedBalance();
        assertEq(dispatcher.responseQueueHead(), 0, "queue starts empty");

        router.setFailSendWith(address(dispatcher), _capacityRevert());
        vm.recordLogs();
        _recall();

        assertEq(dispatcher.trackedIdle(), idleBefore, "idle untouched");
        assertEq(dispatcher.stateVersion(), versionBefore, "no version bump without a value-moving response");
        assertEq(dispatcher.queuedTokenAmount(), queuedBefore, "no queue credit");
        assertEq(dispatcher.accountedBalance(), accountedBefore, "accounted balance unchanged");
        assertEq(dispatcher.responseQueueHead(), 0, "rejection delivered, queue drained");
        assertEq(
            dispatcher.responseQueueTail(),
            tailBefore + 2,
            "two ids consumed: the dropped RETURN_TRANSFER N, then RETURN_REJECTED N+1 (no id reuse)"
        );
        assertEq(token.balanceOf(address(dispatcher)), 100e18, "no token left the dispatcher");

        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "recall slot freed");
        assertEq(executor.getBalance(), navBefore, "NAV unchanged");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), settledBefore, "settled unchanged");
        assertEq(executor.idleLedger(), 0, "nothing credited home");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawDispatcherReject;
        bool sawExecutorReject;
        bool sawCapacityEvent;
        bool sawSkipped;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(dispatcher) && logs[i].topics[0] == CAPACITY_EVENT_TOPIC) {
                (, uint256 amount, uint256 capacity, uint64 droppedId) =
                    abi.decode(logs[i].data, (bytes32, uint256, uint256, uint64));
                assertEq(droppedId, tailBefore + 1, "event carries the dropped response id");
                assertEq(amount, RECALL, "event amount");
                assertEq(capacity, CAPACITY, "event capacity");
                sawCapacityEvent = true;
            }
            if (logs[i].emitter == address(dispatcher) && logs[i].topics[0] == SKIPPED_TOPIC) {
                (uint64 skippedId, uint256 skippedAmount) = abi.decode(logs[i].data, (uint64, uint256));
                assertEq(skippedId, tailBefore + 1, "ResponseSkipped id");
                assertEq(skippedAmount, RECALL, "ResponseSkipped amount");
                sawSkipped = true;
            }
            if (logs[i].emitter == address(dispatcher) && logs[i].topics[0] == DISPATCHER_REJECTED_TOPIC) {
                (, uint8 reason,) = abi.decode(logs[i].data, (bytes32, uint8, uint64));
                assertEq(reason, uint8(CcipReturnRejectReason.ABOVE_POOL_CAPACITY), "dispatcher reason");
                sawDispatcherReject = true;
            }
            if (logs[i].emitter == address(executor) && logs[i].topics[0] == EXECUTOR_REJECTED_TOPIC) {
                (uint256 chainId,, uint8 reason) = abi.decode(logs[i].data, (uint256, bytes32, uint8));
                assertEq(chainId, REMOTE_CHAIN);
                assertEq(reason, uint8(CcipReturnRejectReason.ABOVE_POOL_CAPACITY), "executor reason");
                sawExecutorReject = true;
            }
        }
        assertTrue(sawCapacityEvent, "dispatcher emitted ReturnAboveLocalPoolCapacity");
        assertTrue(sawSkipped, "dispatcher emitted ResponseSkipped for the dropped entry");
        assertTrue(sawDispatcherReject, "dispatcher emitted ReturnRejected");
        assertTrue(sawExecutorReject, "executor emitted ReturnRejected");
    }

    /// @notice The rejected recall must not leave a gap: the next, smaller recall carries the next contiguous
    ///         `stateVersion`, so the executor's frontier advances and the value comes home.
    function testShouldKeepFrontierContiguousAfterCapacityReject() public {
        _fund();
        router.setFailSendWith(address(dispatcher), _capacityRevert());
        _recall();
        assertEq(executor.idleLedger(), 0, "rejected recall credited nothing");

        router.setFailSendWith(address(dispatcher), "");
        uint256 smaller = 50e18;
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, smaller, smaller, 0, address(0), 500_000);
        if (dispatcher.responseQueueHead() != 0) dispatcher.flushResponse();

        assertEq(
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            dispatcher.stateVersion(),
            "executor frontier equals the dispatcher version (no gap)"
        );
        assertEq(executor.idleLedger(), smaller, "recalled amount credited home");
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "return finalized");
    }

    function testShouldStillQueueRecallOnTransientRateLimit() public {
        _fund();
        uint256 idleBefore = dispatcher.trackedIdle();
        uint64 versionBefore = dispatcher.stateVersion();

        router.setFailSendWith(
            address(dispatcher),
            abi.encodeWithSelector(TokenRateLimitReached.selector, 30, 10e18, address(token))
        );
        _recall();

        assertEq(dispatcher.trackedIdle(), idleBefore - RECALL, "idle debited");
        assertEq(dispatcher.stateVersion(), versionBefore + 1, "version bumped");
        assertEq(dispatcher.queuedTokenAmount(), RECALL, "value parked in the queue");
        assertEq(dispatcher.responseQueueHead(), dispatcher.responseQueueTail(), "return queued at the head");
        assertTrue(dispatcher.responseQueueHead() != 0);
        assertTrue(executor.activeReturn(REMOTE_CHAIN) != bytes32(0), "recall still active");

        router.setFailSendWith(address(dispatcher), "");
        dispatcher.flushResponse();
        assertEq(dispatcher.queuedTokenAmount(), 0);
        assertEq(dispatcher.responseQueueHead(), 0);
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "return finalized");
        assertEq(executor.idleLedger(), RECALL, "credited home");
    }

    function testShouldStillQueueRecallOnOtherSendFailure() public {
        _fund();
        uint256 idleBefore = dispatcher.trackedIdle();
        uint64 versionBefore = dispatcher.stateVersion();

        router.setFailSend(address(dispatcher), true);
        _recall();

        assertEq(dispatcher.trackedIdle(), idleBefore - RECALL, "idle debited");
        assertEq(dispatcher.stateVersion(), versionBefore + 1, "version bumped");
        assertEq(dispatcher.queuedTokenAmount(), RECALL, "value parked in the queue");
        assertEq(dispatcher.responseQueueHead(), dispatcher.responseQueueTail());
        assertTrue(dispatcher.responseQueueHead() != 0);

        router.setFailSend(address(dispatcher), false);
        dispatcher.flushResponse();
        assertEq(executor.idleLedger(), RECALL, "credited home");
    }

    /// @notice A recall that lands BEHIND an occupied queue head is never attempted, so the capacity failure is
    ///         not observed and the recall is committed and queued exactly as before. This residual (a stuck head
    ///         shielding an over-capacity recall) is the TP-M-05 territory, not closed by IL-8553.
    function testShouldNotRejectWhenQueueHeadIsOccupied() public {
        _fund();
        uint256 idleBefore = dispatcher.trackedIdle();
        uint64 versionBefore = dispatcher.stateVersion();

        router.setFailSend(address(dispatcher), true);
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 500_000);
        uint64 stuckHead = dispatcher.responseQueueHead();
        assertTrue(stuckHead != 0, "BALANCE_REPORT stuck at the head");

        router.setFailSendWith(address(dispatcher), _capacityRevert());
        _recall();

        assertEq(dispatcher.responseQueueHead(), stuckHead, "head unchanged");
        assertEq(dispatcher.responseQueueTail(), stuckHead + 1, "recall queued behind it");
        assertEq(dispatcher.trackedIdle(), idleBefore - RECALL, "idle debited");
        assertEq(dispatcher.stateVersion(), versionBefore + 1, "version bumped");
        assertEq(dispatcher.queuedTokenAmount(), RECALL, "value parked in the queue");
        assertTrue(executor.activeReturn(REMOTE_CHAIN) != bytes32(0), "recall still active");
    }
}
