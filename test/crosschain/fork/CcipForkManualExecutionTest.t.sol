// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CcipForkBase, CcipForkMessage, ICcipRouterFork, ICcipOffRampV2} from "./CcipForkBase.sol";
import {CcipMsgType} from "../../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipClient} from "../../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipExecutorTransferLib} from "../../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";

interface ICcipOnRampV2Fork {
    struct DynamicConfig {
        address feeQuoter;
        bool reentrancyGuardEntered;
        address feeAggregator;
    }

    function typeAndVersion() external view returns (string memory);
    function getDynamicConfig() external view returns (DynamicConfig memory);
}

interface ICcipFeeQuoterV2Fork {
    function resolveLegacyArgs(uint64 destChainSelector_, bytes calldata extraArgs_)
        external
        view
        returns (bytes memory tokenReceiver, uint32 gasLimit, bytes memory executorArgs);
}

/// @title CcipForkManualExecutionTest
/// @notice IL-8458 / Codex O-14, item "skip / manuallyExecute": failure and recovery semantics of the live CCIP 2.0
///         OffRamp and of the dispatcher's ordered response queue, on pinned Ethereum / Arbitrum forks.
/// @dev CCIP 2.0 has no separate `manuallyExecute`: `OffRamp.execute` is permissionless and re-executes a message in
///      FAILURE state, optionally with a higher `gasLimitOverride`. These tests drive that real state machine
///      (UNTOUCHED -> FAILURE -> SUCCESS, `NoStateProgressMade`, `SkippedAlreadyExecutedMessage`,
///      `InvalidGasLimitOverride`). The one thing mocked is the CCV (committee) signature check, which a fork cannot
///      reproduce; message authenticity is therefore not under test here, only execution semantics.
contract CcipForkManualExecutionTest is CcipForkBase {
    uint8 internal constant UNTOUCHED = 0;
    uint8 internal constant SUCCESS = 2;
    uint8 internal constant FAILURE = 3;
    uint32 internal constant OVERRIDE_GAS_LIMIT = 6_000_000; // == MESSAGE_GAS_LIMIT

    bytes4 internal constant NO_STATE_PROGRESS = bytes4(keccak256("NoStateProgressMade(bytes32,bytes)"));
    bytes4 internal constant ALREADY_EXECUTED =
        bytes4(keccak256("SkippedAlreadyExecutedMessage(bytes32,uint64,uint64)"));
    bytes4 internal constant INVALID_OVERRIDE = bytes4(keccak256("InvalidGasLimitOverride(uint32,uint32)"));

    /// @dev A fork backend of its own (see `CcipForkBase._forkBlocks`).
    function _forkBlocks() internal pure override returns (uint256, uint256) {
        return (ETHEREUM_FORK_BLOCK + 3, ARBITRUM_FORK_BLOCK + 3);
    }

    function setUp() public {
        _deployStack();
    }

    function _deliver(CcipForkMessage memory m_, address destRouter_, string memory label_) internal override {
        if (m_.tokenAmount != 0) {
            (bool success,,) = _routeViaRouter(m_, destRouter_, m_.ccipReceiveGasLimit);
            assertTrue(success, label_);
            return;
        }
        assertEq(_executeOnOffRamp(m_, destRouter_, 0), SUCCESS, label_);
    }

    // =============================================================================================================
    // Manual execution with a gas-limit override
    // =============================================================================================================

    /// @notice A message whose handler runs out of gas under its own limit fails on the real OffRamp with no state
    ///         change; the same message is then executed again with a higher `gasLimitOverride` and succeeds.
    function testShouldReexecuteAnOutOfGasMessageWithAGasLimitOverride() public {
        _lifecycleCreateDispatcher();
        vm.selectFork(ethFork);
        _startCapture();
        // The manager can no longer under-gas a send (IL-8593); a too-low route policy synced by the factory
        // (50_000 message and token limits, route enabled) is what makes the handler run out of gas.
        vm.prank(address(factory));
        executor.syncRoutePolicy(
            ARBITRUM_CHAIN_ID, FEE_TOKEN, 50_000 | uint256(50_000) << 96 | uint256(1) << 192, MAX_FEE
        );
        executor.requestRemoteBalance(ARBITRUM_CHAIN_ID, MAX_FEE, FEE_TOKEN, 0); // 0 = route policy
        CcipForkMessage memory request = _sendFromExecutor();
        assertEq(request.ccipReceiveGasLimit, 50_000);

        vm.selectFork(arbFork);
        ICcipOffRampV2 offRamp = ICcipOffRampV2(request.offRamp);
        uint64 versionBefore = dispatcher.stateVersion();
        _startCapture();
        assertEq(_executeOnOffRamp(request, ARBITRUM_ROUTER, 0), FAILURE, "out of gas -> FAILURE");
        assertEq(_sent(ARBITRUM_ROUTER, ETHEREUM_SELECTOR).length, 0, "no response on failure");
        assertEq(dispatcher.stateVersion(), versionBefore, "receiver state rolled back");
        assertFalse(dispatcher.processedCcipMessage(request.messageId), "message not consumed");

        // Same parameters again: no progress, the OffRamp reverts instead of recording a second FAILURE.
        (address[] memory ccvs, bytes[] memory results) = _mockCcvs(offRamp, request.encoded);
        vm.expectPartialRevert(NO_STATE_PROGRESS);
        offRamp.execute(request.encoded, ccvs, results, 0);
        // An override below the message's own limit is refused.
        vm.expectRevert(abi.encodeWithSelector(INVALID_OVERRIDE, uint32(50_000), uint32(40_000)));
        offRamp.execute(request.encoded, ccvs, results, 40_000);

        // Manual execution with an override: succeeds, the receiver runs once and replies.
        _startCapture();
        assertEq(_executeOnOffRamp(request, ARBITRUM_ROUTER, OVERRIDE_GAS_LIMIT), SUCCESS, "override -> SUCCESS");
        CcipForkMessage memory report = _single(_sent(ARBITRUM_ROUTER, ETHEREUM_SELECTOR));
        assertEq(uint8(_type(report)), uint8(CcipMsgType.BALANCE_REPORT));
        assertEq(dispatcher.stateVersion(), versionBefore, "a balance request is value-neutral: no version bump");

        // A successful message can never run again.
        vm.expectPartialRevert(ALREADY_EXECUTED);
        offRamp.execute(request.encoded, ccvs, results, OVERRIDE_GAS_LIMIT);

        _deliverAndCollect(report, "executor BALANCE_REPORT");
        assertEq(executor.lastRemoteStateVersion(ARBITRUM_CHAIN_ID), versionBefore, "the late report moves no frontier");
    }

    /// @notice A receiver-side revert (the destination factory cannot pay for its DEPLOYMENT_ACK) fails the whole
    ///         CREATE_DISPATCHER atomically; after the budget is topped up, re-executing the same message deploys
    ///         the dispatcher and sends the ACK.
    function testShouldReexecuteCreateDispatcherAfterTheFactoryBudgetIsRestored() public {
        _warmExecutorStorage();
        _startCapture();
        factory.requestDispatcher(address(executor), ARBITRUM_CHAIN_ID, new address[](0), MAX_FEE);
        CcipForkMessage memory create = _sendFromExecutor();

        vm.selectFork(arbFork);
        vm.deal(address(factory), 0);
        _startCapture();
        assertEq(_executeOnOffRamp(create, ARBITRUM_ROUTER, 0), FAILURE, "unpaid ACK -> FAILURE");
        assertEq(_sent(ARBITRUM_ROUTER, ETHEREUM_SELECTOR).length, 0);
        assertEq(address(dispatcher).code.length, 0, "deployment rolled back with the failed ACK");
        assertFalse(factory.isDispatcher(address(dispatcher)));

        vm.deal(address(factory), 1 ether);
        _startCapture();
        assertEq(_executeOnOffRamp(create, ARBITRUM_ROUTER, 0), SUCCESS, "re-executed after the fix");
        CcipForkMessage memory ack = _single(_sent(ARBITRUM_ROUTER, ETHEREUM_SELECTOR));
        assertTrue(address(dispatcher).code.length != 0, "dispatcher deployed");
        _deliverAndCollect(ack, "factory DEPLOYMENT_ACK");
        assertTrue(executor.isDispatcherReady(ARBITRUM_CHAIN_ID));
    }

    // =============================================================================================================
    // The dispatcher's ordered response queue
    // =============================================================================================================

    /// @notice A response the dispatcher cannot pay for stays queued (the inbound handler still succeeds); the
    ///         permissionless `flushResponse` sends it through the real OnRamp once the budget is restored.
    function testShouldHoldAnUnpaidResponseUntilFlushed() public {
        _lifecycleCreateDispatcher();
        vm.selectFork(arbFork);
        vm.deal(address(dispatcher), 0);

        vm.selectFork(ethFork);
        _startCapture();
        executor.requestRemoteBalance(ARBITRUM_CHAIN_ID, MAX_FEE, FEE_TOKEN, MESSAGE_GAS_LIMIT);
        CcipForkMessage[] memory none = _deliverAndCollect(_sendFromExecutor(), "dispatcher BALANCE_REQUEST (unpaid)");
        assertEq(none.length, 0, "nothing sent without a fee budget");
        uint64 head = dispatcher.responseQueueHead();
        assertTrue(head != 0, "response queued");

        vm.deal(address(dispatcher), 1 ether);
        _startCapture();
        vm.prank(makeAddr("anyone"));
        dispatcher.flushResponse();
        CcipForkMessage memory report = _single(_sent(ARBITRUM_ROUTER, ETHEREUM_SELECTOR));
        assertEq(uint8(_type(report)), uint8(CcipMsgType.BALANCE_REPORT));
        assertEq(dispatcher.responseQueueHead(), 0, "queue drained");
        uint64 version = dispatcher.stateVersion();

        _deliverAndCollect(report, "executor BALANCE_REPORT (flushed)");
        assertEq(executor.lastRemoteStateVersion(ARBITRUM_CHAIN_ID), version, "evidence only: frontier stays in sync");
    }

    /// @notice A token-bearing response that cannot be delivered is dropped by the timelocked
    ///         `scheduleSkipStuckResponse` / `executeSkipStuckResponse`, which puts its tokens back into idle without
    ///         changing the dispatcher's accounted balance.
    function testShouldSkipAStuckTokenResponseAndRecreditIdle() public {
        _lifecycleCreateDispatcher();
        uint256 delivered = _lifecycleSendAsset();
        vm.selectFork(arbFork);
        vm.deal(address(dispatcher), 0);

        vm.selectFork(ethFork);
        _startCapture();
        executor.requestAssetsFromDispatcher(ARBITRUM_CHAIN_ID, RECALL_AMOUNT, 0, MAX_FEE, FEE_TOKEN, MESSAGE_GAS_LIMIT);
        assertEq(_deliverAndCollect(_sendFromExecutor(), "dispatcher RETURN_REQUEST (unpaid)").length, 0);
        uint64 head = dispatcher.responseQueueHead();
        assertEq(dispatcher.queuedTokenAmount(), RECALL_AMOUNT, "recalled tokens held in the queue");
        assertEq(dispatcher.trackedIdle(), delivered - RECALL_AMOUNT);
        uint256 accounted = dispatcher.accountedBalance();

        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = dispatcher.scheduleSkipStuckResponse(head);
        vm.warp(block.timestamp + dispatcher.RESCUE_DELAY());
        vm.prank(RESCUE_ADMIN);
        dispatcher.executeSkipStuckResponse(rescueId, head);

        assertEq(dispatcher.responseQueueHead(), 0, "stuck head dropped");
        assertEq(dispatcher.queuedTokenAmount(), 0);
        assertEq(dispatcher.trackedIdle(), delivered, "tokens re-credited to idle");
        assertEq(dispatcher.accountedBalance(), accounted, "accounted balance unchanged");
        assertEq(IERC20(ARBITRUM_USDC).balanceOf(address(dispatcher)), delivered, "tokens never left");
    }

    // =============================================================================================================
    // IL-8496: CCIP 2.0 does not order the dispatcher -> executor lane; the executor orders it itself
    // =============================================================================================================

    /// @notice IL-8496 (found as a known issue by this suite). On the live CCIP 2.0 lanes (OnRamp / OffRamp /
    ///         FeeQuoter 2.0.0) `allowOutOfOrderExecution = false` is accepted and ignored, and `OffRamp.execute`
    ///         is permissionless with no per-sender ordering, so dispatcher responses can execute in any order.
    ///         The executor now reverts `StateVersionGap` on a response ahead of its frontier: the real OffRamp
    ///         records it as FAILURE with nothing applied, and a permissionless re-execution succeeds once the
    ///         earlier response has landed. The chain is never blocked and the frontier ends contiguous.
    /// @dev Before the fix the later response SUCCEEDED on the gap, blocked the chain and left the frontier one
    ///      version short for good (it could not be replayed).
    function testReversedDispatcherResponsesApplyThroughReexecution() public {
        _lifecycleCreateDispatcher();
        _lifecycleSendAsset(); // settled > 0, so a blocked chain would fail NAV closed

        // 1. The ordering flag has no effect on the live FeeQuoter: `false` resolves exactly like `true`.
        vm.selectFork(arbFork);
        address onRamp = ICcipRouterFork(ARBITRUM_ROUTER).getOnRamp(ETHEREUM_SELECTOR);
        assertEq(ICcipOnRampV2Fork(onRamp).typeAndVersion(), "OnRamp 2.0.0");
        ICcipFeeQuoterV2Fork feeQuoter = ICcipFeeQuoterV2Fork(ICcipOnRampV2Fork(onRamp).getDynamicConfig().feeQuoter);
        (bytes memory r0, uint32 g0, bytes memory e0) =
            feeQuoter.resolveLegacyArgs(ETHEREUM_SELECTOR, _extraArgs(false));
        (bytes memory r1, uint32 g1, bytes memory e1) = feeQuoter.resolveLegacyArgs(ETHEREUM_SELECTOR, _extraArgs(true));
        assertEq(keccak256(abi.encode(r0, g0, e0)), keccak256(abi.encode(r1, g1, e1)), "ordering flag has no effect");

        // 2. Two consecutive VALUE-MOVING dispatcher responses (TRANSFER_SETTLED, versions v - 1 and v). A balance
        //    report carries no version since IL-8257, so it cannot be reordered into a gap.
        CcipForkMessage memory first = _heldSettle();
        CcipForkMessage memory second = _heldSettle();
        vm.selectFork(arbFork);
        uint64 v = dispatcher.stateVersion();

        // 3. Executed in reverse on the real Ethereum OffRamp: the later one FAILS on the gap, changing nothing.
        vm.selectFork(ethFork);
        assertEq(executor.lastRemoteStateVersion(ARBITRUM_CHAIN_ID), v - 2);
        assertEq(_executeOnOffRamp(second, ETHEREUM_ROUTER, 0), FAILURE, "later response fails on the gap");
        assertEq(executor.lastRemoteStateVersion(ARBITRUM_CHAIN_ID), v - 2, "nothing applied");
        assertFalse(executor.chainBlocked(ARBITRUM_CHAIN_ID), "a reordering does not block the chain");

        // 4. The earlier one lands, then a permissionless re-execution of the later one succeeds.
        assertEq(_executeOnOffRamp(first, ETHEREUM_ROUTER, 0), SUCCESS, "earlier response executes");
        assertEq(_executeOnOffRamp(second, ETHEREUM_ROUTER, 0), SUCCESS, "re-execution of the later response");
        assertEq(executor.lastRemoteStateVersion(ARBITRUM_CHAIN_ID), v, "frontier contiguous");
        assertFalse(executor.chainBlocked(ARBITRUM_CHAIN_ID));

        // 5. The next response is contiguous again.
        CcipForkMessage memory third = _heldSettle();
        vm.selectFork(ethFork);
        assertEq(_executeOnOffRamp(third, ETHEREUM_ROUTER, 0), SUCCESS);
        assertEq(executor.lastRemoteStateVersion(ARBITRUM_CHAIN_ID), v + 1);
    }

    /// @dev An outbound transfer from Ethereum, executed on Arbitrum; returns the (undelivered) TRANSFER_SETTLED.
    function _heldSettle() private returns (CcipForkMessage memory settle) {
        vm.selectFork(ethFork);
        deal(ETHEREUM_USDC, address(executor), SEND_AMOUNT);
        _startCapture();
        executor.sendAssetToDispatcher(ARBITRUM_CHAIN_ID, SEND_AMOUNT, MAX_FEE, FEE_TOKEN, TOKEN_GAS_LIMIT);
        settle = _single(_deliverAndCollect(_sendFromExecutor(), "dispatcher OUTBOUND_TRANSFER"));
        assertEq(uint8(_type(settle)), uint8(CcipMsgType.TRANSFER_SETTLED));
    }

    function _extraArgs(bool allowOutOfOrder_) private pure returns (bytes memory) {
        return CcipClient.argsToBytes(
            CcipClient.GenericExtraArgsV2({gasLimit: MESSAGE_GAS_LIMIT, allowOutOfOrderExecution: allowOutOfOrder_})
        );
    }
}
