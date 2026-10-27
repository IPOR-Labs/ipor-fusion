// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {CcipExecutorFixture} from "test/crosschain/CcipExecutorFixture.sol";
import {CcipAppBase} from "contracts/crosschain/ccip/base/CcipAppBase.sol";
import {CcipMessages, CcipMsgType} from "contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CrosschainErrors} from "contracts/crosschain/lib/CrosschainErrors.sol";

/// @title CcipReturnTransferGapTest
/// @notice IL-9135 (Codex ccip-exec C-002): no CCIP test delivered a token-bearing `RETURN_TRANSFER` with a state
///         version gap. Recall A is dispatched and then cancelled locally, recall B is active; both
///         `RETURN_TRANSFER`s are held in the router (`setAutoDeliver(false)` + `setHoldTokenMessages(true)`).
///         Delivering B first must revert `StateVersionGap` before any write (the version check runs ahead of the
///         debit, the credit and the anchor update), the OffRamp keeps B executable, and A then B each apply
///         exactly once.
contract CcipReturnTransferGapTest is CcipExecutorFixture {
    /// @dev Raised when the recorded logs hold no `CcipMessageReceived` event from the executor.
    error CcipMessageReceivedNotEmitted();

    uint256 private constant AMOUNT_A = 30e18;
    uint256 private constant AMOUNT_B = 20e18;
    bytes32 private constant MESSAGE_RECEIVED_TOPIC = keccak256("CcipMessageReceived(bytes32,uint256,address)");

    bytes32 private opA;
    bytes32 private opB;
    uint256 private idxA;
    uint256 private idxB;
    uint64 private versionAfterSupply;

    function setUp() public {
        vm.warp(365 days);
        _fixtureSetUp();
    }

    /// @dev Supply 100 and attest it, recall A (30) and dispatch its held `RETURN_TRANSFER`, cancel A, recall B (20)
    ///      and dispatch its held `RETURN_TRANSFER`. Indexes of the two held responses are read from the held
    ///      envelopes, not assumed.
    function _reachCancelledAAndActiveB() private {
        _bridge(100e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(100e18);
        versionAfterSupply = executor.lastRemoteStateVersion(REMOTE_CHAIN);

        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);

        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, AMOUNT_A, AMOUNT_A, 0, address(0), 500_000);
        opA = executor.activeReturn(REMOTE_CHAIN);
        router.deliverHeld(router.heldCount() - 1); // the request reaches the dispatcher, RETURN_TRANSFER A is held
        executor.cancelPendingReturn(REMOTE_CHAIN);

        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, AMOUNT_B, AMOUNT_B, 0, address(0), 500_000);
        opB = executor.activeReturn(REMOTE_CHAIN);
        router.deliverHeld(router.heldCount() - 1);

        bool foundA;
        bool foundB;
        for (uint256 i; i < router.heldCount(); ++i) {
            (CcipMsgType t, bytes memory inner) = CcipMessages.decode(router.heldData(i));
            if (t != CcipMsgType.RETURN_TRANSFER) continue;
            (bytes32 op, , , uint64 version) = abi.decode(inner, (bytes32, uint256, uint256, uint64));
            if (op == opA) {
                idxA = i;
                foundA = true;
                assertEq(version, versionAfterSupply + 1, "A carries the next version");
            } else if (op == opB) {
                idxB = i;
                foundB = true;
                assertEq(version, versionAfterSupply + 2, "B carries the version after A");
            }
        }
        assertTrue(foundA && foundB, "both RETURN_TRANSFERs are held");
        assertTrue(opA != opB, "distinct operations");
    }

    function testShouldRejectGappedReturnTransferWithoutAnyWriteThenApplyBothOnce() public {
        _reachCancelledAAndActiveB();

        uint256 idleBefore = executor.idleLedger();
        uint256 settledBefore = executor.settledRemoteBalance(REMOTE_CHAIN);
        uint256 anchorBefore = executor.attestationAnchorPrincipal(REMOTE_CHAIN);
        uint256 tokensBefore = token.balanceOf(address(executor));
        uint64 versionBefore = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        uint32 cancelledBefore = executor.cancelledRecallCount(REMOTE_CHAIN);
        assertEq(versionBefore, versionAfterSupply, "no return applied yet");
        assertEq(cancelledBefore, 1, "A is cancelled");

        // B first: version 3 while the frontier expects 2.
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.StateVersionGap.selector,
                REMOTE_CHAIN,
                uint64(versionAfterSupply + 1),
                uint64(versionAfterSupply + 2)
            )
        );
        router.deliverHeld(idxB);

        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), versionBefore, "frontier unchanged");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), settledBefore, "settled unchanged");
        assertEq(executor.idleLedger(), idleBefore, "idle ledger unchanged");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), anchorBefore, "anchor unchanged");
        assertEq(token.balanceOf(address(executor)), tokensBefore, "token balance unchanged");
        assertEq(executor.activeReturn(REMOTE_CHAIN), opB, "B stays the active recall");
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), cancelledBefore, "cancelled count unchanged");

        // A lands (version 2): the late return of the cancelled recall is applied once.
        router.deliverHeld(idxA);
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), versionAfterSupply + 1, "A advances the frontier");
        assertEq(executor.idleLedger(), idleBefore + AMOUNT_A, "A credited exactly once");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), settledBefore - AMOUNT_A, "A debited exactly once");
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0, "A resolved");

        // B again (version 3): now contiguous.
        vm.recordLogs();
        router.deliverHeld(idxB);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), versionAfterSupply + 2, "B advances the frontier");
        assertEq(executor.idleLedger(), idleBefore + AMOUNT_A + AMOUNT_B, "B credited exactly once");
        assertEq(
            executor.settledRemoteBalance(REMOTE_CHAIN),
            settledBefore - AMOUNT_A - AMOUNT_B,
            "B debited exactly once"
        );
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "recall B resolved");
        assertEq(token.balanceOf(address(executor)), tokensBefore, "tokens were already in the executor");

        // Third delivery of B: replay protection by message id.
        bytes32 messageId = _receivedMessageId(logs);
        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipMessageAlreadyProcessed.selector, messageId));
        router.deliverHeld(idxB);
        assertEq(executor.idleLedger(), idleBefore + AMOUNT_A + AMOUNT_B, "no double credit");
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), versionAfterSupply + 2, "frontier unchanged");
    }

    function _receivedMessageId(Vm.Log[] memory logs_) private view returns (bytes32 messageId) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(executor) && logs_[i].topics[0] == MESSAGE_RECEIVED_TOPIC) {
                (messageId, , ) = abi.decode(logs_[i].data, (bytes32, uint256, address));
                return messageId;
            }
        }
        revert CcipMessageReceivedNotEmitted();
    }
}
