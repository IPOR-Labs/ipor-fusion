// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";
import {CcipChainRescue} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

/// @title CcipLateSettleShortfallTest
/// @notice IL-8581 follow-up: a late `TRANSFER_SETTLED` that credits nothing (the balance was already attested after a
///         non-crediting force-resolve, IL-8619, or already credited by a crediting force-resolve) must still report a
///         pool fee / missed `minDelivered` floor. The events are observability only: no `settled` write, no block.
contract CcipLateSettleShortfallTest is CcipExecutorFixture {
    bytes32 internal constant SHORTFALL = keccak256("SettledCreditShortfall(uint256,bytes32,uint256,uint256)");
    bytes32 internal constant BELOW_MIN = keccak256("SettledBelowMinDelivered(uint256,bytes32,uint256,uint256)");
    bytes32 internal constant ALREADY_ATTESTED = keccak256("LateSettlementAlreadyAttested(uint256,bytes32,uint64)");
    bytes32 internal constant ASSET_SETTLED = keccak256("AssetSettled(uint256,bytes32,uint256)");
    bytes32 internal constant INBOUND_IGNORED = keccak256("InboundMessageIgnored(uint256,uint8,bytes32)");

    bytes32 internal operationId;

    function setUp() public {
        _fixtureSetUp();
        _bridge(100e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(100e18);
    }

    // ---- IL-8619 path: force-set after a non-crediting resolve ----

    function testShouldEmitShortfallOnAlreadyAttestedLateSettleWithPoolFee() public {
        uint256 settleIndex = _openHeldOutbound(1_000, 0); // 10e18 sent, 9e18 delivered
        uint256 settledBefore = _attestedAfterDrop();

        vm.recordLogs();
        router.deliverHeld(settleIndex);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_count(logs, ALREADY_ATTESTED), 1, "IL-8619 path taken");
        assertEq(_count(logs, SHORTFALL), 1, "one shortfall event");
        assertEq(_count(logs, BELOW_MIN), 0, "no floor set");
        assertEq(_count(logs, ASSET_SETTLED), 0, "nothing credited");
        _assertTwoWords(_find(logs, SHORTFALL), 10e18, 9e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), settledBefore, "NAV unchanged by the late settle");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "chain not blocked");
    }

    function testShouldEmitBelowMinDeliveredOnAlreadyAttestedLateSettle() public {
        uint256 settleIndex = _openHeldOutbound(1_000, 9_500_000_000_000_000_001); // floor above the 9e18 delivered
        uint256 settledBefore = _attestedAfterDrop();

        vm.recordLogs();
        router.deliverHeld(settleIndex);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_count(logs, ALREADY_ATTESTED), 1, "IL-8619 path taken");
        assertEq(_count(logs, SHORTFALL), 1, "shortfall too");
        assertEq(_count(logs, BELOW_MIN), 1, "floor missed");
        _assertTwoWords(_find(logs, BELOW_MIN), 9_500_000_000_000_000_001, 9e18);
        assertEq(_count(logs, ASSET_SETTLED), 0, "nothing credited");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), settledBefore, "NAV unchanged by the late settle");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "chain not blocked");
    }

    function testShouldEmitNoShortfallOnAlreadyAttestedLateSettleWithFullDelivery() public {
        uint256 settleIndex = _openHeldOutbound(0, 10e18);
        uint256 settledBefore = _attestedAfterDrop();

        vm.recordLogs();
        router.deliverHeld(settleIndex);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_count(logs, ALREADY_ATTESTED), 1, "IL-8619 path taken");
        assertEq(_count(logs, SHORTFALL), 0, "no shortfall");
        assertEq(_count(logs, BELOW_MIN), 0, "no floor miss");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), settledBefore, "NAV unchanged");
    }

    // ---- "credited" path: late settle after a crediting force-resolve ----

    function testShouldEmitShortfallOnLateSettleAfterCreditingForceResolveWithPoolFee() public {
        uint256 settleIndex = _openHeldOutbound(1_000, 0);
        _resolveOutbound(true);
        uint256 settledBefore = executor.settledRemoteBalance(REMOTE_CHAIN);
        assertEq(settledBefore, 110e18, "crediting resolve booked the full amount");

        vm.recordLogs();
        router.deliverHeld(settleIndex);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_count(logs, SHORTFALL), 1, "one shortfall event");
        assertEq(_count(logs, BELOW_MIN), 0, "no floor set");
        _assertTwoWords(_find(logs, SHORTFALL), 10e18, 9e18);
        assertEq(_count(logs, ASSET_SETTLED), 0, "nothing credited");
        assertEq(_count(logs, ALREADY_ATTESTED), 0, "not the IL-8619 path");
        (, bytes memory ignored) = _findWithTopics(logs, INBOUND_IGNORED);
        (uint8 msgType, bytes32 reason) = abi.decode(_tail(ignored), (uint8, bytes32));
        assertGt(msgType, 0, "ignored message type reported");
        assertEq(reason, bytes32("credited"), "still ignored as credited");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), settledBefore, "settled unchanged by the late settle");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "chain not blocked");
    }

    function testShouldEmitBelowMinDeliveredOnLateSettleAfterCreditingForceResolve() public {
        uint256 settleIndex = _openHeldOutbound(1_000, 9_500_000_000_000_000_001);
        _resolveOutbound(true);

        vm.recordLogs();
        router.deliverHeld(settleIndex);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_count(logs, SHORTFALL), 1, "shortfall too");
        assertEq(_count(logs, BELOW_MIN), 1, "floor missed");
        _assertTwoWords(_find(logs, BELOW_MIN), 9_500_000_000_000_000_001, 9e18);
        assertEq(_count(logs, ASSET_SETTLED), 0, "nothing credited");
    }

    function testShouldEmitNoShortfallOnLateSettleAfterCreditingForceResolveWithFullDelivery() public {
        uint256 settleIndex = _openHeldOutbound(0, 10e18);
        _resolveOutbound(true);
        uint256 settledBefore = executor.settledRemoteBalance(REMOTE_CHAIN);

        vm.recordLogs();
        router.deliverHeld(settleIndex);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_count(logs, SHORTFALL), 0, "no shortfall");
        assertEq(_count(logs, BELOW_MIN), 0, "no floor miss");
        assertEq(_count(logs, ASSET_SETTLED), 0, "nothing credited");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), settledBefore, "settled unchanged");
    }

    // ---- helpers ----

    /// @dev A = 10e18 sent with an optional floor; the pool takes `haircutBps_` on delivery. The TRANSFER_SETTLED
    ///      (next state version, no gap) is held back so it can be delivered at will.
    function _openHeldOutbound(uint256 haircutBps_, uint256 minDelivered_) internal returns (uint256 settleIndex) {
        router.setPoolHaircutBps(haircutBps_);
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        vm.recordLogs();
        token.mint(address(executor), 10e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 10e18, 0, address(0), 500_000, minDelivered_);
        operationId = _captureOperationId();
        router.deliverHeld(router.heldCount() - 1);
        settleIndex = router.heldCount() - 1;
        router.setHoldTokenMessages(false);
        router.setAutoDeliver(true);
        router.setPoolHaircutBps(0);
    }

    /// @dev Non-crediting force-resolve, a frontier repair over the held settlement, then a force-set to the
    ///      dispatcher's true balance read at the repaired frontier: the write already contains the delivered amount
    ///      and the settlement's version is not above it, so the late settle takes the IL-8619 skip branch (the one
    ///      case it is right). Returns the settled balance after the force-set.
    function _attestedAfterDrop() internal returns (uint256) {
        _resolveOutbound(false);
        _advance(dispatcher.stateVersion()); // over the held settlement: frontier == dispatcher version
        vm.warp(block.timestamp + 1); // IL-8604 R1: read strictly after the last value-moving receipt
        uint256 arg = (uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) << 192) |
            (block.timestamp << 128) |
            dispatcher.accountedBalance();
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        return executor.settledRemoteBalance(REMOTE_CHAIN);
    }

    function _advance(uint64 newVersion_) internal {
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion_);
    }

    function _resolveOutbound(bool credit_) internal {
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleForceResolveOutbound(operationId, credit_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeForceResolveOutbound(rescueId, operationId, credit_);
    }

    function _count(Vm.Log[] memory logs_, bytes32 topic_) internal view returns (uint256 n) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(executor) && logs_[i].topics[0] == topic_) ++n;
        }
    }

    function _findWithTopics(Vm.Log[] memory logs_, bytes32 topic_) internal view returns (bool, bytes memory) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(executor) && logs_[i].topics[0] == topic_) return (true, logs_[i].data);
        }
        revert("event not found");
    }

    function _find(Vm.Log[] memory logs_, bytes32 topic_) internal view returns (bytes memory data) {
        (, data) = _findWithTopics(logs_, topic_);
    }

    /// @dev Asserts a non-indexed `(chainId, operationId, a, b)` payload.
    function _assertTwoWords(bytes memory data_, uint256 a_, uint256 b_) internal view {
        (uint256 chainId, bytes32 op, uint256 a, uint256 b) = abi.decode(data_, (uint256, bytes32, uint256, uint256));
        assertEq(chainId, REMOTE_CHAIN, "chainId");
        assertEq(op, operationId, "operationId");
        assertEq(a, a_, "first amount");
        assertEq(b, b_, "received");
    }

    /// @dev `InboundMessageIgnored(chainId, uint8 type, bytes32 reason)`: drop the leading chainId word.
    function _tail(bytes memory data_) internal pure returns (bytes memory out) {
        out = new bytes(data_.length - 32);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data_[i + 32];
        }
    }
}
