// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MsgType, ReturnRejectReason} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainMessages, ReturnRejected} from "../../contracts/crosschain/lib/CrosschainMessages.sol";

/// @title RecallBelowFloorTest
/// @notice IL-8119 regression cover, driven with a REAL executor against a REAL dispatcher and hand-relayed
///         payloads (`StargateTwoSidedBase`), so the recall lane can be pushed into the clamp-below-floor
///         state that used to leave a stuck, retained `RETURN_ASSETS_REQUEST` packet.
/// @dev Setup shared by every test: bridge 100e6 to the dispatcher, deploy 60e6 of it into the remote
///      vault, leaving `trackedIdle == 40e6` while the executor still accounts `settledRemoteBalance ==
///      100e6` (the vault-side move is invisible to the source chain).
contract RecallBelowFloorTest is StargateTwoSidedBase {
    function setUp() public {
        _twoSidedSetUp();
        _bringUpBothSides();
        _allowRemoteVault();
        _bridgeToDispatcher(100e6);

        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(60e6));
        _relayAll();

        // Setup assertion (distinct from the regression assertions below): if this fails, the fixture
        // itself is broken, not the fix.
        assertEq(dispatcher.trackedIdle(), 40e6, "setup: 40e6 left idle after a 60e6 remote deposit");
    }

    /// @dev Relay the next queued message, catching a revert instead of letting it propagate, so the test
    ///      fails on its own assertion (`reverted`) rather than on the propagated revert message. Mirrors
    ///      `StargateTwoSidedBase._relayAt` addressing.
    function _relayNextCatching() internal returns (bool reverted) {
        MockLzEndpoint.SentMessage memory m = endpoint.sentAt(relayCursor);
        if (m.dstEid == REMOTE_EID) {
            try endpoint.deliverLz(
                address(dispatcher), LOCAL_EID, bytes32(uint256(uint160(address(dispatcher)))), m.guid, m.message
            ) {
                reverted = false;
            } catch {
                reverted = true;
            }
        } else {
            try endpoint.deliverLz(
                address(executor), REMOTE_EID, bytes32(uint256(uint160(address(executor)))), m.guid, m.message
            ) {
                reverted = false;
            } catch {
                reverted = true;
            }
        }
        relayCursor++;
    }

    function _decodeLastSent() internal view returns (MsgType msgType, bytes memory data) {
        MockLzEndpoint.SentMessage memory m = endpoint.sentAt(endpoint.sentCount() - 1);
        return CrosschainMessages.decodeEnvelope(m.message);
    }

    /// @notice T1: request=100e6/floor=99e6 clamps to sendLD=40e6 (bound by trackedIdle) on the dispatcher.
    ///         Pre-fix that forwards floor 99e6 unscaled to the pool, which reverts and retains the packet
    ///         (fails on the `reverted` assertion below). Post-fix the dispatcher rejects terminally,
    ///         releases the executor's slot with no warp needed, and a re-sized recall then succeeds.
    function testShouldRejectRecallBelowFloorAndFreeTheExecutorSlot() public {
        // `_bridgeToDispatcher` in setUp already routed one send through the shared pool mock (executor ->
        // dispatcher); compare against that baseline rather than an absolute 0.
        uint256 sendCountBefore = pool.sendCount();
        (bytes32 requestId,,) = _requestAssets(100e6, 99e6);

        bool reverted = _relayNextCatching();
        assertFalse(reverted, "RETURN_ASSETS_REQUEST reverted on the dispatcher: packet would be retained by LayerZero");

        assertTrue(dispatcher.recallConsumed(requestId), "recall consumed (terminal)");
        assertEq(dispatcher.trackedIdle(), 40e6, "no value moved: the clamp-below-floor case never reaches the pool");
        assertEq(pool.sendCount(), sendCountBefore, "pool never called on the rejected recall");

        (MsgType mt, bytes memory data) = _decodeLastSent();
        assertEq(uint8(mt), uint8(MsgType.RETURN_REJECTED), "authenticated rejection sent to the executor");
        ReturnRejected memory rej = CrosschainMessages.decodeReturnRejected(data);
        assertEq(rej.requestId, requestId);
        assertEq(uint8(rej.reason), uint8(ReturnRejectReason.BELOW_MINIMUM));

        // Deliver the rejection to the executor and prove the slot is freed immediately (no staleness wait).
        _relayNext();
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "rejection released the reserved capacity");
        assertEq(executor.inFlightSince(REMOTE_CHAIN), 0, "staleness slot cleared");

        (bytes32 requestId2,,) = _requestAssets(40e6, 39e6); // no vm.warp: would revert ActiveReturnRequestExists pre-fix
        _relayNext();
        assertTrue(dispatcher.recallConsumed(requestId2), "second, correctly-sized recall is accepted");
        assertEq(pool.lastSend().amountLD, 40e6, "floor forwarded un-scaled: send amount");
        assertEq(pool.lastSend().minAmountLD, 39e6, "floor forwarded un-scaled: min amount");
        assertEq(dispatcher.trackedIdle(), 0, "the freed idle was fully returned");

        (MsgType mt2,) = _decodeLastSent();
        assertEq(uint8(mt2), uint8(MsgType.RETURN_STARTED), "return metadata sent on the successful recall");
    }

    /// @notice T2 (non-regression guard, passes both pre- and post-fix): a clamped send that still MEETS
    ///         the floor must keep forwarding the floor un-scaled, proving the fix does not scale it down.
    function testShouldStillForwardUnscaledFloorWhenClampedSendMeetsIt() public {
        _requestAssets(100e6, 40e6);
        _relayNext();

        assertEq(pool.lastSend().amountLD, 40e6, "clamped send amount");
        assertEq(pool.lastSend().minAmountLD, 40e6, "floor forwarded un-scaled, unchanged by the clamp");
        assertEq(dispatcher.trackedIdle(), 0);

        (MsgType mt,) = _decodeLastSent();
        assertEq(uint8(mt), uint8(MsgType.RETURN_STARTED));
    }

    /// @notice T3: boundary at one whole asset unit (1e6) above tracked idle. This harness runs 6 local and
    ///         6 shared decimals (`CrosschainTestBase._baseSetUp`), so the conversion rate is 1 and the
    ///         smallest representable step is `1`; `1e6` is used to keep the amounts readable alongside the
    ///         other tests. Fails pre-fix (the pool reverts on `40e6 < 41e6`); the mirror request one unit
    ///         lower succeeds.
    function testShouldRejectRecallWhenFloorExceedsTrackedIdleByOneUnit() public {
        (bytes32 requestId,,) = _requestAssets(100e6, 40e6 + 1e6);
        bool reverted = _relayNextCatching();
        assertFalse(reverted, "RETURN_ASSETS_REQUEST reverted on the dispatcher at the boundary");
        assertTrue(dispatcher.recallConsumed(requestId));
        assertEq(dispatcher.trackedIdle(), 40e6, "boundary rejection moves no value");
        (MsgType mt, bytes memory data) = _decodeLastSent();
        assertEq(uint8(mt), uint8(MsgType.RETURN_REJECTED));
        assertEq(uint8(CrosschainMessages.decodeReturnRejected(data).reason), uint8(ReturnRejectReason.BELOW_MINIMUM));

        _relayNext(); // free the slot on the executor
        (bytes32 requestId2,,) = _requestAssets(100e6, 40e6);
        _relayNext();
        assertTrue(dispatcher.recallConsumed(requestId2), "one unit lower, the mirror request is accepted");
        assertEq(pool.lastSend().amountLD, 40e6);
        assertEq(pool.lastSend().minAmountLD, 40e6);
    }
}
