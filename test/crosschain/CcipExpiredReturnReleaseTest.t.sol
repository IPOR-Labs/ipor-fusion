// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipExecutorTransferLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

contract ReleaseToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipExpiredReturnReleaseTest
/// @notice IL-9621: a `RETURN_TRANSFER` that cannot leave the dispatcher before its recall deadline (the shared pool
///         rate limit used up by other senders, pool capacity behind a busy head, ...) is released by anyone with
///         `flushExpiredReturn()`: its tokens go back to `trackedIdle` and the same response is sent without them,
///         with its version. The executor closes the recall with nothing received and nothing debited, the frontier
///         stays contiguous and NAV reopens. A return whose tokens can leave is sent as it is.
contract CcipExpiredReturnReleaseTest is Test {
    event ReturnExpiredUnwound(bytes32 operationId, uint256 amount, uint64 responseId);
    event RemoteBalanceUpdated(uint256 chainId, uint256 balance, uint64 stateVersion);

    error TokenMaxCapacityExceeded(uint256 capacity, uint256 requested, address tokenAddress);
    error TokenRateLimitReached(uint256 minWaitInSeconds, uint256 available, address tokenAddress);

    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    uint256 internal constant FUNDED = 100e18;
    uint256 internal constant RECALL = 60e18;
    uint256 internal constant TRANSFER_STALENESS_MAX = 1 days;

    MockCcipRouter internal router;
    ReleaseToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;
    address internal anyone = makeAddr("anyone");

    function setUp() public {
        vm.warp(365 days);
        router = new MockCcipRouter();
        token = new ReleaseToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            18,
            _safety()
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

        token.mint(address(executor), FUNDED);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, FUNDED, 0, address(0), 500_000);
        _attestBalance(FUNDED);
    }

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: address(this),
                balanceApprover: address(0xA33),
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                anchorBandBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: TRANSFER_STALENESS_MAX
            });
    }

    // ------------------------------------------------------------------ helpers

    function _attestBalance(uint256 balance_) internal {
        vm.warp(block.timestamp + 1);
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

    /// @dev Token-bearing sends of the dispatcher revert the way a used-up pool rate limit does; token-less sends
    ///      still go through.
    function _drainBucket() internal {
        router.setFailSendWith(
            address(dispatcher),
            abi.encodeWithSelector(TokenRateLimitReached.selector, 600, 0, address(token))
        );
    }

    /// @return deadline The recall deadline the executor stamps on the request.
    function _recall() internal returns (uint256 deadline) {
        deadline = block.timestamp + TRANSFER_STALENESS_MAX;
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, RECALL, RECALL, 0, address(0), 500_000);
    }

    function _queuedReturn(uint64 id_) internal view returns (bytes32 operationId, uint256 amount, uint64 version) {
        (bytes memory data, , ) = dispatcher.queuedResponse(id_);
        (CcipMsgType messageType, bytes memory payload) = CcipMessages.decode(data);
        assertEq(uint8(messageType), uint8(CcipMsgType.RETURN_TRANSFER), "queued return");
        (operationId, amount, , version) = abi.decode(payload, (bytes32, uint256, uint256, uint64));
    }

    function _navStale() internal view returns (bool) {
        (bool ok, bytes memory err) = address(executor).staticcall(abi.encodeWithSignature("getBalance()"));
        return !ok && bytes4(err) == CcipExecutorTransferLib.TransferStale.selector;
    }

    // ------------------------------------------------------------------ tests

    function testShouldReleaseExpiredReturnWithoutTokensWhenTokensCannotLeave() public {
        _drainBucket();
        uint256 deadline = _recall();
        uint64 head = dispatcher.responseQueueHead();
        (bytes32 operationId, uint256 amount, uint64 version) = _queuedReturn(head);
        assertEq(amount, RECALL);
        assertEq(version, executor.lastRemoteStateVersion(REMOTE_CHAIN) + 1, "return holds frontier + 1");

        vm.warp(deadline);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainDispatcher.ReturnNotExpired.selector, head, deadline));
        dispatcher.flushExpiredReturn();

        vm.warp(deadline + 1);
        assertTrue(_navStale(), "NAV closed on the stale recall");

        vm.expectEmit(address(dispatcher));
        emit ReturnExpiredUnwound(operationId, RECALL, head);
        // The released head carries its queued balance (40) plus the released amount (60), not a fresh current balance.
        vm.expectEmit(address(executor));
        emit RemoteBalanceUpdated(REMOTE_CHAIN, FUNDED, version);
        vm.prank(anyone);
        assertTrue(dispatcher.flushExpiredReturn(), "released without tokens");

        // Dispatcher: the tokens never left, they are idle again; the version stands.
        assertEq(dispatcher.responseQueueHead(), 0, "queue empty");
        assertEq(dispatcher.queuedTokenAmount(), 0);
        assertEq(dispatcher.trackedIdle(), FUNDED, "40 + 60 back in idle");
        assertEq(dispatcher.accountedBalance(), FUNDED, "accounted value unchanged");
        assertEq(dispatcher.stateVersion(), version, "no new version");
        assertEq(token.balanceOf(address(dispatcher)), FUNDED, "tokens still in the dispatcher");

        // Executor: recall closed with nothing received and nothing debited; frontier contiguous; NAV open.
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), version, "version consumed");
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "recall closed");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), FUNDED, "settled keeps the value");
        assertEq(executor.idleLedger(), 0, "nothing credited");
        assertFalse(_navStale(), "NAV open again");
        assertEq(executor.getBalance(), FUNDED, "full value");
    }

    function testShouldSendExpiredReturnAsItIsWhenTokensCanLeave() public {
        _drainBucket();
        uint256 deadline = _recall();
        vm.warp(deadline + 1);
        router.setFailSendWith(address(dispatcher), "");

        vm.prank(anyone);
        assertFalse(dispatcher.flushExpiredReturn(), "sent with its tokens");
        assertEq(executor.idleLedger(), RECALL, "tokens home");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), FUNDED - RECALL);
        assertEq(dispatcher.trackedIdle(), FUNDED - RECALL);
        assertEq(executor.getBalance(), FUNDED);
    }

    function testShouldRefuseAHeadThatIsNotAQueuedReturn() public {
        vm.expectRevert(CcipCrosschainDispatcher.NoQueuedResponse.selector);
        dispatcher.flushExpiredReturn();

        // A stuck BALANCE_REPORT holds the head and the recall queues behind it.
        router.setFailSend(address(dispatcher), true);
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 500_000);
        uint64 reportHead = dispatcher.responseQueueHead();
        uint256 deadline = _recall();
        assertEq(dispatcher.responseQueueTail(), reportHead + 1, "return behind the report");

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainDispatcher.ReturnNotExpired.selector, reportHead, 0));
        dispatcher.flushExpiredReturn();
    }

    function testShouldLeaveTheQueueWhenEvenTheTokenLessSendFails() public {
        _drainBucket();
        uint256 deadline = _recall();
        uint64 head = dispatcher.responseQueueHead();
        vm.warp(deadline + 1);
        router.setFailSend(address(dispatcher), true);

        vm.expectRevert(bytes("forced send failure"));
        dispatcher.flushExpiredReturn();
        (, uint256 amount, ) = _queuedReturn(head);
        assertEq(amount, RECALL, "payload untouched");
        assertEq(dispatcher.responseQueueHead(), head, "head untouched");
        assertEq(dispatcher.queuedTokenAmount(), RECALL);
        assertEq(dispatcher.trackedIdle(), FUNDED - RECALL);
    }

    /// @notice The released return keeps its place and its version, so a settle queued behind it lands right after.
    function testShouldKeepVersionOrderWithASettleQueuedBehind() public {
        _drainBucket();
        uint256 deadline = _recall();
        token.mint(address(executor), 10e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 10e18, 0, address(0), 500_000);
        uint64 frontier = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        assertEq(dispatcher.stateVersion(), frontier + 2, "return N+1 and settle N+2 queued");

        vm.warp(deadline + 1);
        dispatcher.flushExpiredReturn();
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), frontier + 1, "zero return applied");
        dispatcher.flushResponse();
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), frontier + 2, "settle applied after it");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), FUNDED + 10e18, "nothing debited, supply settled");
        assertEq(dispatcher.trackedIdle(), FUNDED + 10e18);
    }

    function testShouldResolveAStaleCancelledRecall() public {
        _drainBucket();
        uint256 deadline = _recall();
        vm.warp(deadline + 1);
        vm.prank(anyone);
        executor.cancelStalePendingReturn(REMOTE_CHAIN);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1);
        assertTrue(_navStale(), "cancel alone keeps NAV closed (IL-8590)");

        vm.prank(anyone);
        dispatcher.flushExpiredReturn();
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0, "late zero return resolves the cancelled recall");
        assertFalse(_navStale(), "NAV open");
        assertEq(executor.getBalance(), FUNDED);
    }

    function testShouldReissueTheRecallAfterARelease() public {
        _drainBucket();
        uint256 deadline = _recall();
        vm.warp(deadline + 1);
        dispatcher.flushExpiredReturn();

        router.setFailSendWith(address(dispatcher), "");
        _recall();
        assertEq(executor.idleLedger(), RECALL, "second recall delivered");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), FUNDED - RECALL);
    }

    /// @notice IL-8816: a return queued behind a busy head that then hits the pool capacity was stuck until the
    ///         timelocked skip plus ADVANCE_FRONTIER; past its deadline it is released the same way.
    function testShouldReleaseAReturnStuckOnCapacityBehindABusyHead() public {
        router.setFailSend(address(dispatcher), true);
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 500_000);
        uint256 deadline = _recall();
        router.setFailSend(address(dispatcher), false);
        router.setFailSendWith(
            address(dispatcher),
            abi.encodeWithSelector(TokenMaxCapacityExceeded.selector, 50e18, RECALL, address(token))
        );
        assertEq(dispatcher.flushResponse(64), 1, "report out, return stuck on capacity");

        vm.warp(deadline + 1);
        assertTrue(dispatcher.flushExpiredReturn(), "released without tokens");
        assertEq(dispatcher.responseQueueHead(), 0);
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0));
        assertEq(executor.getBalance(), FUNDED);
    }

    /// @notice The token-less return is sent with the route's `messageGasLimit`, like `TRANSFER_SETTLED`; its
    ///         executor handler must fit the same budget.
    function testTokenLessReturnFitsTheMessageGasBudget() public {
        // A held TRANSFER_SETTLED, for comparison.
        router.setFailSend(address(dispatcher), true);
        token.mint(address(executor), 10e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 10e18, 0, address(0), 500_000);
        router.setFailSend(address(dispatcher), false);
        router.setAutoDeliver(false);
        dispatcher.flushResponse();
        uint256 g = gasleft();
        router.deliverHeld(0);
        uint256 settleGas = g - gasleft();

        router.setAutoDeliver(true);
        _drainBucket();
        uint256 deadline = _recall();
        vm.warp(deadline + 1);
        router.setAutoDeliver(false);
        dispatcher.flushExpiredReturn();
        assertEq(router.heldCount(), 2, "zero return held");
        g = gasleft();
        router.deliverHeldExact(1, 500_000);
        uint256 zeroReturnGas = g - gasleft();
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "delivered within the message budget");

        emit log_named_uint("TRANSFER_SETTLED delivery gas", settleGas);
        emit log_named_uint("zero RETURN_TRANSFER delivery gas", zeroReturnGas);
        assertLt(zeroReturnGas, 500_000);
    }
}
