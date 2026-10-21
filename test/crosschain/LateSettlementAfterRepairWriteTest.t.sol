// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";
import {LzComposeBuilder} from "./mocks/MockStargatePool.sol";
import {CrosschainMessages, OutboundTransfer} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {Observation} from "../../contracts/crosschain/interfaces/ICrosschainDispatcher.sol";
import {ResolveOutcome, CcipChainRescue} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

/// @title StargateLateSettlementAfterRepairWriteTest
/// @notice IL-8619 review. A `DROP_FROM_NAV` outbound that reaches the dispatcher only AFTER the frontier-repair
///         latch-clearing approval or a force-set must be credited when its `TRANSFER_SETTLED` arrives: both writes
///         are bound to the executor's frontier, so their balance was read before the transfer was credited and
///         cannot contain it. A real executor against a real dispatcher, payloads relayed by hand; every write is
///         honest (the dispatcher's `observation()` at the executor's frontier). On 0fba15dc both tests fail at
///         "late credit lost": the settlement is skipped (`LateSettlementAlreadyAttested`) and NAV stays at S.
contract StargateLateSettlementAfterRepairWriteTest is StargateTwoSidedBase {
    bytes32 internal constant ALREADY_ATTESTED = keccak256("LateSettlementAlreadyAttested(uint256,bytes32,uint64)");

    function setUp() public {
        _twoSidedSetUp();
        _bringUpBothSides();
        _bridgeToDispatcher(100e6); // S = 100e6 on both sides
        _attestDispatcher();
    }

    /// @dev README "Lost TRANSFER_SETTLED" procedure, step by step. A's settlement is lost for good; B has not reached
    ///      the dispatcher yet. Repair, A -> DELIVERED_TO_SETTLED, B -> DROP_FROM_NAV ("if it has not arrived"), the
    ///      honest latch-clearing approval of 110e6, then B lands.
    function testLateSettleAfterLatchClearingApprovalIsCredited() public {
        (bytes32 idA, bytes32 guidA,) = _sendAsset(10e6, 0);
        _composeToDispatcher(idA, guidA, 10e6);
        relayCursor = endpoint.sentCount(); // A's TRANSFER_SETTLED is lost for good
        (bytes32 idB, bytes32 guidB,) = _sendAsset(50e6, 0); // B is still in the bridge

        _advance(dispatcher.stateVersion()); // frontier repair: chain blocked, latch armed
        _resolve(idA, ResolveOutcome.DELIVERED_TO_SETTLED);
        _resolve(idB, ResolveOutcome.DROP_FROM_NAV);
        _attestDispatcher(); // the latch-clearing approval, at the frontier
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "the approval lifted the block");

        _assertLateCreditBooked(idB, guidB, 50e6);
    }

    /// @dev Reject + honest force-set at the frontier while B is still in the bridge, then B lands.
    function testLateSettleAfterForceSetIsCredited() public {
        (bytes32 idB, bytes32 guidB,) = _sendAsset(50e6, 0); // B is still in the bridge
        _resolve(idB, ResolveOutcome.DROP_FROM_NAV);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _proposeDispatcher();
        vm.prank(approver);
        executor.rejectAndBlockProposal(pid);
        _forceSetDispatcher();
        _attestDispatcher(); // restores the NAV clock after the rescue delay

        _assertLateCreditBooked(idB, guidB, 50e6);
    }

    /// @dev The transfer reaches the dispatcher only now; its authenticated TRANSFER_SETTLED is relayed back.
    function _assertLateCreditBooked(bytes32 id_, bytes32 guid_, uint256 amount_) internal {
        uint64 writeVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        uint256 before = executor.settledRemoteBalance(REMOTE_CHAIN);
        assertEq(dispatcher.stateVersion(), writeVersion, "the write was read at the frontier");
        assertEq(before, dispatcher.observation().trackedIdle, "the write priced the dispatcher exactly");

        vm.recordLogs();
        _composeToDispatcher(id_, guid_, amount_);
        _relayAll();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(dispatcher.stateVersion(), writeVersion, "the transfer was credited after the write");
        assertEq(dispatcher.observation().trackedIdle, before + amount_, "the dispatcher holds the transfer");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), dispatcher.stateVersion(), "settle consumed");
        assertEq(
            executor.settledRemoteBalance(REMOTE_CHAIN),
            dispatcher.observation().trackedIdle,
            "late credit lost: executor settled != dispatcher balance"
        );
        assertEq(executor.getBalance(), before + amount_, "NAV == true remote balance");
        assertEq(_count(logs, ALREADY_ATTESTED), 0, "no LateSettlementAlreadyAttested");
    }

    function _composeToDispatcher(bytes32 id_, bytes32 guid_, uint256 amount_) internal {
        usdc.mint(address(dispatcher), amount_);
        bytes memory envelope = CrosschainMessages.encodeOutboundTransfer(OutboundTransfer({transferId: id_}));
        bytes memory composeMsg = LzComposeBuilder.build(address(dispatcher), LOCAL_EID, amount_, envelope);
        endpoint.deliverCompose(address(dispatcher), address(pool), guid_, composeMsg);
    }

    function _proposeDispatcher() internal returns (uint256) {
        Observation memory ob = dispatcher.observation();
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: ob.trackedIdle,
            stateVersion: ob.stateVersion,
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: ob.trackedPositionSetHash
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        return executor.proposalCount();
    }

    function _attestDispatcher() internal {
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _proposeDispatcher();
        vm.prank(approver);
        executor.approveBalance(pid);
    }

    function _forceSetDispatcher() internal {
        Observation memory ob = dispatcher.observation();
        assertEq(ob.stateVersion, executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), "force-set read at frontier");
        vm.prank(admin);
        uint256 rescueId =
            executor.scheduleForceSetSettledBalance(REMOTE_CHAIN, ob.trackedIdle, ob.stateVersion, _markFsObs(), false);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(rescueId, REMOTE_CHAIN, ob.trackedIdle, ob.stateVersion, fsObs, false);
    }

    function _advance(uint64 newVersion_) internal {
        bytes32 id = bytes32((uint256(REMOTE_CHAIN) << 64) | uint256(newVersion_));
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, ResolveOutcome.ADVANCE_STATE_FRONTIER);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, id, ResolveOutcome.ADVANCE_STATE_FRONTIER);
    }

    function _resolve(bytes32 id_, ResolveOutcome outcome_) internal {
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id_, outcome_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, id_, outcome_);
    }

    function _count(Vm.Log[] memory logs_, bytes32 topic_) internal view returns (uint256 n) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(executor) && logs_[i].topics[0] == topic_) ++n;
        }
    }
}

/// @title CcipLateSettlementAfterRepairWriteTest
/// @notice The CCIP twin, a real dispatcher behind the mock router. The skip stays only for a settlement whose version
///         is not above the write's (`CcipFrontierRepairOpenOutboundTest.testDropFromNavThenAttestThenLateSettleIsNotCreditedAgain`).
///         On 0fba15dc both tests fail at "late credit lost".
contract CcipLateSettlementAfterRepairWriteTest is CcipExecutorFixture {
    bytes32 internal constant ALREADY_ATTESTED = keccak256("LateSettlementAlreadyAttested(uint256,bytes32,uint64)");

    function setUp() public {
        _fixtureSetUp();
        _bridge(100e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(100e18);
    }

    /// @dev README "Lost TRANSFER_SETTLED" procedure: A is credited by the dispatcher but its response is dropped for
    ///      good; B is sent but not executed on the dispatcher chain. Repair, A -> credited, B -> dropped, the honest
    ///      latch-clearing approval of 110e18, then B is executed.
    function testLateSettleAfterLatchClearingApprovalIsCredited() public {
        router.setFailSend(address(dispatcher), true);
        vm.recordLogs();
        _bridge(10e18);
        bytes32 opA = _captureOperationId();
        uint64 stuck = dispatcher.responseQueueHead();
        vm.prank(RESCUE_ADMIN);
        uint256 skipId = dispatcher.scheduleSkipStuckResponse(stuck);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        dispatcher.executeSkipStuckResponse(skipId, stuck);
        router.setFailSend(address(dispatcher), false);
        (bytes32 opB, uint256 idxB) = _holdOutbound(50e18);

        _advance(dispatcher.stateVersion()); // frontier repair: chain blocked, latch armed
        _resolveOutbound(opA, true);
        _resolveOutbound(opB, false);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(dispatcher.accountedBalance()); // the latch-clearing approval, at the frontier
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "the approval lifted the block");

        _assertLateCreditBooked(idxB, 50e18);
    }

    /// @dev Reject + honest FORCE_SET_SETTLED at the frontier while B is not executed, then B is executed.
    function testLateSettleAfterForceSetIsCredited() public {
        (bytes32 opB, uint256 idxB) = _holdOutbound(50e18);
        _resolveOutbound(opB, false);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(dispatcher.accountedBalance());
        vm.prank(APPROVER);
        executor.rejectBalanceAndBlock(pid);
        assertEq(dispatcher.stateVersion(), executor.lastRemoteStateVersion(REMOTE_CHAIN), "read at the frontier");
        uint256 arg = (uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) << 192) | (block.timestamp << 128)
            | dispatcher.accountedBalance();
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);

        _assertLateCreditBooked(idxB, 50e18);
    }

    /// @dev The held token message is executed on the dispatcher chain only now; its response follows at once.
    function _assertLateCreditBooked(uint256 heldIndex_, uint256 amount_) internal {
        uint64 writeVersion = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        uint256 before = executor.settledRemoteBalance(REMOTE_CHAIN);
        assertEq(dispatcher.stateVersion(), writeVersion, "the write was read at the frontier");
        assertEq(before, dispatcher.accountedBalance(), "the write priced the dispatcher exactly");

        vm.recordLogs();
        router.deliverHeld(heldIndex_);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(dispatcher.stateVersion(), writeVersion, "the transfer was credited after the write");
        assertEq(dispatcher.accountedBalance(), before + amount_, "the dispatcher holds the transfer");
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), dispatcher.stateVersion(), "settle consumed");
        assertEq(
            executor.settledRemoteBalance(REMOTE_CHAIN),
            dispatcher.accountedBalance(),
            "late credit lost: executor settled != dispatcher balance"
        );
        assertEq(executor.getBalance(), dispatcher.accountedBalance(), "NAV == true remote balance");
        assertEq(_count(logs, ALREADY_ATTESTED), 0, "no LateSettlementAlreadyAttested");
    }

    /// @dev An outbound whose token message has left the executor but is NOT executed on the dispatcher chain yet.
    function _holdOutbound(uint256 amount_) internal returns (bytes32 operationId, uint256 heldIndex) {
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        vm.recordLogs();
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 500_000);
        operationId = _captureOperationId();
        heldIndex = router.heldCount() - 1;
        router.setHoldTokenMessages(false);
        router.setAutoDeliver(true);
    }

    function _resolveOutbound(bytes32 operationId_, bool credit_) internal {
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleForceResolveOutbound(operationId_, credit_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeForceResolveOutbound(rescueId, operationId_, credit_);
    }

    function _advance(uint64 newVersion_) internal {
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion_);
    }

    function _count(Vm.Log[] memory logs_, bytes32 topic_) internal view returns (uint256 n) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(executor) && logs_[i].topics[0] == topic_) ++n;
        }
    }
}
