// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";
import {CcipExecutorTransferLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";

/// @title CcipTransferStalenessClockTest
/// @notice IL-9136 (ccip-exec C-003): the `oldestPendingAt` clock with several open outbound transfers. Resolving a
///         newer transfer must not move the clock of an older one, resolving the oldest must retime the clock to the
///         oldest remaining record, and with three records the clock must be the minimum of the survivors, not the
///         maximum (with two records one timestamp survives, so min == max there).
contract CcipTransferStalenessClockTest is CcipExecutorFixture {
    uint256 internal constant STALENESS = 1 days;
    uint256 internal constant STEP = 60;

    uint256 internal t0;

    function setUp() public {
        _fixtureSetUp();
        _bridge(100e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(100e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        // Hold the token-bearing sends so each transfer settles only when the test delivers it.
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        t0 = block.timestamp;
    }

    // ---- helpers ----

    /// @dev Opens a 10e18 outbound transfer; returns the index of its held token message.
    function _open() internal returns (uint256 tokenIndex) {
        token.mint(address(executor), 10e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 10e18, 0, address(0), 500_000);
        tokenIndex = router.heldCount() - 1;
    }

    /// @dev Delivers the token message (the dispatcher then sends `TRANSFER_SETTLED`, held) and the settlement.
    ///      Dispatcher state versions follow delivery order, so the settlements arrive without a gap.
    function _settle(uint256 tokenIndex_) internal {
        router.deliverHeld(tokenIndex_);
        router.deliverHeld(router.heldCount() - 1);
    }

    /// @dev `_applyFreshSettle` does not stamp `lastApprovedObservedAt`; an approved observation of the settled
    ///      amount keeps the observation gate healthy so only the transfer clock can fire at the boundaries.
    function _approveSettled() internal {
        uint256 settled = executor.settledRemoteBalance(REMOTE_CHAIN);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(settled);
    }

    function _assertOtherNavGatesHealthy() internal view {
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "chain not blocked");
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "no active recall");
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0, "no cancelled-recall clock");
    }

    /// @dev At exactly `since_ + STALENESS` NAV is readable; one second later it reverts naming `since_`.
    function _assertClockBoundary(uint256 since_) internal {
        _assertOtherNavGatesHealthy();
        vm.warp(since_ + STALENESS);
        assertGt(executor.getBalance(), 0, "readable at the boundary");
        vm.warp(since_ + STALENESS + 1);
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.TransferStale.selector, REMOTE_CHAIN, since_));
        executor.getBalance();
    }

    // ---- tests ----

    function testShouldNotResetOlderRecordClockWhenNewerSettles() public {
        _open();
        vm.warp(t0 + STEP);
        uint256 b = _open();
        assertEq(executor.oldestPendingAt(REMOTE_CHAIN), t0, "clock armed by the first transfer");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 2, "two open records");

        // Deliver B's token first so its settlement is the next state version, then settle it; A stays open.
        _settle(b);
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 1, "one record left");
        assertEq(executor.oldestPendingAt(REMOTE_CHAIN), t0, "older record keeps its clock");
        _approveSettled();

        _assertClockBoundary(t0); // the first transfer is still unresolved
    }

    function testShouldRetimeToNextRecordWhenOldestResolves() public {
        uint256 a = _open();
        vm.warp(t0 + STEP);
        _open();
        assertEq(executor.oldestPendingAt(REMOTE_CHAIN), t0, "clock armed by the first transfer");

        _settle(a);
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 1, "one record left");
        assertEq(executor.oldestPendingAt(REMOTE_CHAIN), t0 + STEP, "clock retimed to the remaining record");
        _approveSettled();

        _assertClockBoundary(t0 + STEP);
    }

    function testShouldKeepOldestOfRemainingRecordsWhenOneOfThreeResolves() public {
        uint256 a = _open();
        vm.warp(t0 + STEP);
        _open();
        vm.warp(t0 + 2 * STEP);
        uint256 c = _open();
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 3, "three open records");
        assertEq(executor.oldestPendingAt(REMOTE_CHAIN), t0, "clock armed by the first transfer");

        // Newest resolves: survivors are t0 and t0 + STEP, the clock must stay at the minimum.
        _settle(c);
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 2, "two records left");
        assertEq(executor.oldestPendingAt(REMOTE_CHAIN), t0, "minimum of the survivors, not the maximum");

        // Oldest resolves next: the clock moves to the remaining older-of-two record.
        _settle(a);
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 1, "one record left");
        assertEq(executor.oldestPendingAt(REMOTE_CHAIN), t0 + STEP, "retimed to the last record");
        _approveSettled();

        _assertClockBoundary(t0 + STEP);
    }
}
