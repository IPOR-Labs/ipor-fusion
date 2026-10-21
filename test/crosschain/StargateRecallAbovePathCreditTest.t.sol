// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MsgType, ReturnRejectReason} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainMessages, ReturnRejected} from "../../contracts/crosschain/lib/CrosschainMessages.sol";

/// @title StargateRecallAbovePathCreditTest
/// @notice IL-8616: Stargate V2 `quoteOFT` silently CAPS the quote at the live path credit
///         (`OFTLimit.maxAmountLD`) while `sendToken` reverts `Path_InsufficientCredit` on the full amount. A
///         recall above the live credit whose floor sits below the capped quote used to pass the IL-8452
///         pre-flight and revert inside `sendToken`, which reverts `lzReceive` and retains the packet. It is now
///         answered `RETURN_REJECTED(ABOVE_PATH_CREDIT)` before any value moves.
/// @dev Same setup as `RecallBelowFloorTest`: `trackedIdle == 40e6` while the executor accounts 100e6.
contract StargateRecallAbovePathCreditTest is StargateTwoSidedBase {
    function setUp() public {
        _twoSidedSetUp();
        _bringUpBothSides();
        _allowRemoteVault();
        _bridgeToDispatcher(100e6);

        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(60e6));
        _relayAll();
        assertEq(dispatcher.trackedIdle(), 40e6, "setup: 40e6 left idle after a 60e6 remote deposit");
    }

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

    function _assertRejectedAbovePathCredit(bytes32 requestId_) internal view {
        (MsgType mt, bytes memory data) = _decodeLastSent();
        assertEq(uint8(mt), uint8(MsgType.RETURN_REJECTED), "authenticated rejection sent to the executor");
        ReturnRejected memory rej = CrosschainMessages.decodeReturnRejected(data);
        assertEq(rej.requestId, requestId_);
        assertEq(uint8(rej.reason), uint8(ReturnRejectReason.ABOVE_PATH_CREDIT));
    }

    function testShouldRejectRecallAboveLivePathCreditInsteadOfReverting() public {
        pool.setPathCredit(10e6);
        uint256 sendCountBefore = pool.sendCount();
        uint64 versionBefore = dispatcher.stateVersion();
        uint256 settledBefore = executor.settledRemoteBalance(REMOTE_CHAIN);
        uint256 idleLedgerBefore = executor.idleLedger();
        (bytes32 requestId,,) = _requestAssets(100e6, 5e6); // clamps to 40e6; floor 5e6 is below the capped quote

        bool reverted = _relayNextCatching();
        assertFalse(reverted, "lzReceive reverted: LayerZero would retain the packet");

        assertTrue(dispatcher.recallConsumed(requestId), "recall consumed (terminal)");
        assertEq(dispatcher.trackedIdle(), 40e6, "no value moved");
        assertEq(dispatcher.stateVersion(), versionBefore, "no version bump");
        assertEq(pool.sendCount(), sendCountBefore, "pool never sent");
        _assertRejectedAbovePathCredit(requestId);

        _relayNext();
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "rejection released the recall slot");
        assertEq(executor.inFlightSince(REMOTE_CHAIN), 0, "staleness slot cleared");
        // `getBalance()` reverts `NavSettledStale` in this harness (no attestation), so NAV is asserted through
        // its two inputs.
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), settledBefore, "settled unchanged");
        assertEq(executor.idleLedger(), idleLedgerBefore, "idle ledger unchanged");
    }

    function testShouldSendRecallWithinPathCredit() public {
        pool.setPathCredit(100e6);
        (bytes32 requestId,,) = _requestAssets(100e6, 40e6);
        bool reverted = _relayNextCatching();
        assertFalse(reverted);

        assertTrue(dispatcher.recallConsumed(requestId));
        assertEq(pool.lastSend().amountLD, 40e6, "full clamped amount sent");
        assertEq(dispatcher.trackedIdle(), 0, "idle returned");
        (MsgType mt,) = _decodeLastSent();
        assertEq(uint8(mt), uint8(MsgType.RETURN_STARTED), "return metadata sent");
    }

    /// @notice The TP-M-38 shape: recall 100, credit 10, floor 9. The capped quote (10) still meets the floor, so
    ///         the IL-8452 floor check alone passes and `sendToken` would revert `Path_InsufficientCredit`.
    function testShouldRejectWhenCappedQuoteStillMeetsFloor() public {
        pool.setPathCredit(10e6);
        (bytes32 requestId,,) = _requestAssets(100e6, 9e6);
        bool reverted = _relayNextCatching();
        assertFalse(reverted, "lzReceive reverted: LayerZero would retain the packet");
        assertTrue(dispatcher.recallConsumed(requestId));
        assertEq(dispatcher.trackedIdle(), 40e6, "no value moved");
        _assertRejectedAbovePathCredit(requestId);
    }

    /// @notice Pins `>` (not `>=`): a send whose amount equals the live credit exactly still goes out.
    function testShouldSendRecallWhenCreditEqualsAmount() public {
        pool.setPathCredit(40e6);
        (bytes32 requestId,,) = _requestAssets(100e6, 40e6); // clamps to 40e6 == credit
        bool reverted = _relayNextCatching();
        assertFalse(reverted);

        assertTrue(dispatcher.recallConsumed(requestId));
        assertEq(pool.lastSend().amountLD, 40e6, "sent in full at the exact credit");
        assertEq(dispatcher.trackedIdle(), 0, "idle returned");
        (MsgType mt,) = _decodeLastSent();
        assertEq(uint8(mt), uint8(MsgType.RETURN_STARTED), "return metadata sent");
    }

    /// @notice The pool charges credit on the amount OUT: a reward can push an in-credit send over the cap.
    function testShouldRejectWhenRewardPushesOutputAboveCredit() public {
        pool.setPathCredit(40e6);
        pool.setNextAmounts(40e6, 41e6); // amount in == credit, amount out (with reward) above it
        uint256 sendCountBefore = pool.sendCount();
        (bytes32 requestId,,) = _requestAssets(100e6, 40e6);
        bool reverted = _relayNextCatching();
        assertFalse(reverted, "lzReceive reverted: LayerZero would retain the packet");

        assertTrue(dispatcher.recallConsumed(requestId));
        assertEq(dispatcher.trackedIdle(), 40e6, "no value moved");
        assertEq(pool.sendCount(), sendCountBefore, "pool never sent");
        _assertRejectedAbovePathCredit(requestId);
    }
}
