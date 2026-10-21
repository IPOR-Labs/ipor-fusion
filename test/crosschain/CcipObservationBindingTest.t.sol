// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ValueNeutralToken} from "./CcipValueNeutralVersionTest.t.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher, CcipObservation} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipExecutorAttestationLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipChainRescue} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

/// @title CcipObservationBindingTest
/// @notice IL-8604 (TP-M-26) / IL-8584 (TP-M-06): a balance proposal must describe the dispatcher state AFTER the
///         executor applied the last value-moving response. A queued `RETURN_TRANSFER` is versioned when it is
///         enqueued and credited locally when it is delivered, so an observation taken before that credit shares
///         the post-credit `stateVersion` yet still counts the returned value. `propose` and `approve` therefore
///         require `remoteTimestamp > lastValueMovingReceiptAt(chainId)`.
contract CcipObservationBindingTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;

    MockCcipRouter internal router;
    ValueNeutralToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new ValueNeutralToken();
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
            RESCUE_ADMIN,
            GUARDIAN,
            RESCUE_DELAY
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
        vm.warp(1_700_000_000);
        vm.roll(1_000);
    }

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: RESCUE_ADMIN,
                rescueGuardian: GUARDIAN,
                balanceProposer: address(this),
                balanceApprover: APPROVER,
                rescueDelay: RESCUE_DELAY,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            });
    }

    // ------------------------------------------------------------------ helpers

    bytes32 private trackedHash;

    function _frontier() private view returns (uint64) {
        return executor.lastRemoteStateVersion(REMOTE_CHAIN);
    }

    function _proposeAt(uint256 balance_, uint64 version_, uint64 observedAt_) private returns (uint256) {
        // No external call before `proposeBalance`: an armed `expectRevert` would be consumed by it.
        return executor.proposeBalance(
            REMOTE_CHAIN,
            balance_,
            version_,
            uint64(block.number),
            observedAt_,
            uint64(block.timestamp + 1 days),
            trackedHash
        );
    }

    function _bridge(uint256 amount_) private {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 500_000);
    }

    /// @dev 100e18 bridged and settled (version 1), attested once, cadence limiter elapsed.
    function _baseline() private {
        trackedHash = dispatcher.observation().trackedPositionSetHash;
        _bridge(100e18);
        vm.warp(block.timestamp + 1);
        uint256 id = _proposeAt(100e18, 1, uint64(block.timestamp));
        vm.prank(APPROVER);
        executor.approveBalance(id);
        vm.warp(block.timestamp + 1 hours);
    }

    function _expectPredates(uint64 observedAt_, uint64 receiptAt_) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.ObservationPredatesValueMovingReceipt.selector,
                REMOTE_CHAIN,
                observedAt_,
                receiptAt_
            )
        );
    }

    // ------------------------------------------------------------------ tests

    function testShouldRejectProposalObservedBeforeQueuedReturnWasCredited() public {
        _baseline();
        uint64 observedAt = uint64(block.timestamp); // observation of the dispatcher before the return is flushed

        // Recall: the dispatcher queues RETURN_TRANSFER (version 2); the mock router delivers it at once.
        vm.warp(block.timestamp + 10);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 15e18, 15e18, 0, address(0), 500_000);
        uint64 receiptAt = uint64(block.timestamp);
        assertEq(_frontier(), 2, "return credited");
        assertEq(executor.lastValueMovingReceiptAt(REMOTE_CHAIN), receiptAt, "receipt time recorded");

        // Proposed AFTER the credit, at the current version and epoch, but observed before the flush.
        vm.warp(block.timestamp + 1 hours);
        _expectPredates(observedAt, receiptAt);
        _proposeAt(100e18, 2, observedAt); // the stale pre-flush figure
        // Observed at the very receipt time is not enough either: strictly later is required.
        _expectPredates(receiptAt, receiptAt);
        _proposeAt(100e18, 2, receiptAt);
    }

    function testShouldRejectProposalObservedBeforeTransferSettled() public {
        _baseline();
        uint64 observedAt = uint64(block.timestamp);
        vm.warp(block.timestamp + 10);
        _bridge(10e18);
        uint64 receiptAt = uint64(block.timestamp);
        assertEq(_frontier(), 2, "settle credited");

        vm.warp(block.timestamp + 1 hours);
        _expectPredates(observedAt, receiptAt);
        _proposeAt(110e18, 2, observedAt);
    }

    function testShouldAcceptProposalObservedAfterValueMovingReceipt() public {
        _baseline();
        vm.warp(block.timestamp + 10);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 15e18, 15e18, 0, address(0), 500_000);
        uint64 receiptAt = uint64(block.timestamp);

        vm.warp(block.timestamp + 1 hours);
        uint256 id = _proposeAt(85e18, 2, receiptAt + 1);
        vm.prank(APPROVER);
        executor.approveBalance(id);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 85e18, "settled == remote balance");
        assertEq(executor.getBalance(), 100e18, "NAV exact: 85 remote + 15 home");
    }

    /// @notice The epoch void still happens first for a proposal that was already pending when the receipt landed.
    ///         (The approve-time check in the lib is defence in depth: the receipt time is written together with
    ///         the epoch bump, which supersedes the active proposal, so a pending proposal cannot reach it.)
    function testShouldStillVoidViaEpochWhenReceiptLandsAfterPropose() public {
        _baseline();
        uint256 id = _proposeAt(100e18, 1, uint64(block.timestamp));
        vm.warp(block.timestamp + 10);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 15e18, 15e18, 0, address(0), 500_000);
        assertEq(executor.activeProposalId(REMOTE_CHAIN), 0, "proposal voided");
        vm.prank(APPROVER);
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorAttestationLib.ProposalNotActive.selector, id));
        executor.approveBalance(id);
    }

    /// @notice A force-set must be observed AT the frontier: one above it could match at execute after a queued
    ///         `RETURN_TRANSFER` lands, re-counting the returned tokens.
    function testShouldRejectForceSetScheduledAboveFrontier() public {
        _baseline();
        uint64 frontier = _frontier();
        uint256 arg = (uint256(frontier + 1) << 192) | (block.timestamp << 128) | 85e18;
        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainExecutor.ForceSetStateVersionMismatch.selector,
                REMOTE_CHAIN,
                frontier,
                frontier + 1
            )
        );
        executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);

        // At the frontier it schedules fine.
        vm.prank(RESCUE_ADMIN);
        arg = (uint256(frontier) << 192) | (block.timestamp << 128) | 85e18;
        executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
    }

    /// @dev IL-8604 R1: 100 bridged, a recall of 8 queued in the dispatcher at version 2 (frontier still 1), then
    ///      the return lands 20 minutes after the read. Returns the pre-flush read time and the receipt time.
    function _recallQueuedThenLanded() private returns (uint64 readAt, uint64 receiptAt, uint256 preFlushArg) {
        _baseline();
        router.setFailSend(address(dispatcher), true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 8e18, 8e18, 0, address(0), 500_000);
        assertEq(_frontier(), 1, "return still queued");
        assertEq(dispatcher.stateVersion(), 2, "queued return already versioned");
        assertEq(dispatcher.accountedBalance(), 100e18, "queued return still counted remotely");
        readAt = uint64(block.timestamp);
        preFlushArg = (uint256(dispatcher.stateVersion()) << 192) | (uint256(readAt) << 128) | 100e18;

        // While the frontier is behind the read version, the existing version binding refuses it.
        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainExecutor.ForceSetStateVersionMismatch.selector, REMOTE_CHAIN, 1, 2)
        );
        executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, preFlushArg);

        vm.warp(block.timestamp + 20 minutes);
        router.setFailSend(address(dispatcher), false);
        dispatcher.flushResponse();
        receiptAt = uint64(block.timestamp);
        assertEq(_frontier(), 2, "return landed");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 92e18, "settled debited");
        assertEq(executor.idleLedger(), 8e18, "recalled tokens credited");
    }

    /// @notice IL-8604 R1: version equality binds the version, not the read. The pre-flush read now carries the
    ///         frontier version, yet counts the returned tokens; scheduling it would set settled to 100 (NAV 108).
    function testShouldRefuseForceSetScheduleObservedBeforeQueuedReturnLanded() public {
        (uint64 readAt, uint64 receiptAt, uint256 preFlushArg) = _recallQueuedThenLanded();

        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.ObservationPredatesValueMovingReceipt.selector,
                REMOTE_CHAIN,
                readAt,
                receiptAt
            )
        );
        executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, preFlushArg);
        assertEq(receiptAt, readAt + 20 minutes, "receipt 20 minutes after the read");
    }

    /// @notice The rule is strict, as in `propose`: a read in the very second of the receipt is refused.
    function testShouldRefuseForceSetScheduleObservedAtReceiptSecond() public {
        (, uint64 receiptAt,) = _recallQueuedThenLanded();

        uint256 arg = (uint256(_frontier()) << 192) | (uint256(receiptAt) << 128) | 92e18;
        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.ObservationPredatesValueMovingReceipt.selector,
                REMOTE_CHAIN,
                receiptAt,
                receiptAt
            )
        );
        executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
    }

    /// @notice A read taken after the receipt schedules and executes; settled 92, idle 8, NAV 100.
    function testShouldScheduleAndExecuteForceSetObservedAfterReceipt() public {
        _recallQueuedThenLanded();

        vm.warp(block.timestamp + 1);
        assertEq(dispatcher.accountedBalance(), 92e18, "fresh read excludes the returned tokens");
        uint256 arg = (uint256(_frontier()) << 192) | (block.timestamp << 128) | dispatcher.accountedBalance();
        vm.prank(RESCUE_ADMIN);
        uint256 id = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(id, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 92e18, "settled == remote balance");
        assertEq(executor.idleLedger(), 8e18, "recalled tokens counted once");
        assertEq(executor.getBalance(), 100e18, "NAV exact");
    }

    function testShouldStampReceiptOnForceResolveOutboundForceSetAndLateCredit() public {
        _baseline();
        router.setAutoDeliver(false);

        // (a) crediting force-resolve of an outbound that never reached the dispatcher
        vm.recordLogs();
        _bridge(10e18);
        bytes32 op1 = _sentOperationId(vm.getRecordedLogs());
        vm.warp(block.timestamp + 10);
        vm.prank(RESCUE_ADMIN);
        uint256 id = executor.scheduleForceResolveOutbound(op1, true);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeForceResolveOutbound(id, op1, true);
        assertEq(executor.lastValueMovingReceiptAt(REMOTE_CHAIN), block.timestamp, "force-resolve outbound stamped");

        // (c) late credit for an outbound force-resolved WITHOUT credit
        vm.recordLogs();
        _bridge(10e18);
        bytes32 op2 = _sentOperationId(vm.getRecordedLogs());
        vm.warp(block.timestamp + 10);
        vm.prank(RESCUE_ADMIN);
        id = executor.scheduleForceResolveOutbound(op2, false);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeForceResolveOutbound(id, op2, false);
        vm.warp(block.timestamp + 10);
        uint64 before = executor.lastValueMovingReceiptAt(REMOTE_CHAIN);
        // Build the message before the prank: any external call in between would consume it.
        CcipClient.Any2EVMMessage memory lateSettle = CcipClient.Any2EVMMessage({
            messageId: keccak256("late-settle"),
            sourceChainSelector: DISPATCHER_SELECTOR,
            sender: abi.encode(address(dispatcher)),
            data: CcipMessages.encode(
                CcipMsgType.TRANSFER_SETTLED,
                abi.encode(op2, uint256(10e6), uint256(10e6), uint64(_frontier() + 1))
            ),
            destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
        });
        vm.prank(address(router));
        executor.ccipReceive(lateSettle);
        assertEq(executor.lastValueMovingReceiptAt(REMOTE_CHAIN), block.timestamp, "late credit stamped");
        assertGt(block.timestamp, before, "late credit moved the stamp");

        // (b) settled force-set at the frontier
        vm.warp(block.timestamp + 10);
        uint256 arg = (uint256(_frontier()) << 192) | (block.timestamp << 128) | 50e18;
        vm.prank(RESCUE_ADMIN);
        id = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(id, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        assertEq(executor.lastValueMovingReceiptAt(REMOTE_CHAIN), block.timestamp, "force-set stamped");
    }

    function _sentOperationId(Vm.Log[] memory logs_) private view returns (bytes32 operationId) {
        for (uint256 i; i < logs_.length; ++i) {
            if (
                logs_[i].emitter == address(executor)
                    && logs_[i].topics[0] == CcipCrosschainExecutor.AssetSent.selector
            ) {
                (, operationId, , ) = abi.decode(logs_[i].data, (uint256, bytes32, bytes32, uint256));
                return operationId;
            }
        }
        revert("AssetSent not emitted");
    }
}
