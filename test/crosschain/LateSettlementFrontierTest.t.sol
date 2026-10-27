// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

/// @title LateSettlementFrontierTest
/// @notice Regression tests for audit `version_frontier_stall_bricks_inbound_message_lane`.
///
///         `_onTransferSettled` used to short-circuit on `rec.settled` BEFORE calling
///         `_advanceVersionFrontier`. `OutboundRecord.settled` is also set by the timelocked
///         `applyForceResolve` rescue, so a genuinely DELAYED (not lost) TRANSFER_SETTLED landing
///         after the rescue executed without consuming the state version the dispatcher had
///         allocated for it. LayerZero marks such a message executed, so it can never be replayed,
///         and the strictly contiguous frontier stays one behind forever: every later
///         version-bearing message reverts with `StateVersionGap`, `propose()` can no longer attest
///         the true remote state, and after `STALENESS_MAX` the fail-closed NAV pre-hook freezes the
///         whole PlasmaVault.
///
///         The fix consumes the version first and skips only the accounting, mirroring
///         `_onCommandAck` and the `rec.finalized` branch of `_onReturnStarted`.
contract LateSettlementFrontierTest is CrosschainTestBase {
    event TransferSettlementConsumedWithoutAccounting(uint256 srcChainId, bytes32 transferId, uint64 stateVersion);

    function setUp() public {
        _baseSetUp();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _forceResolve(bytes32 id_, ResolveOutcome outcome_) internal {
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id_, outcome_);
        vm.warp(block.timestamp + RESCUE_DELAY + 1);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, id_, outcome_);
    }

    /// @dev Deliver a settlement without aborting the test when the executor reverts, so a bricked
    ///      lane can be asserted on rather than crashing the run.
    function _trySettle(bytes32 transferId_, bytes32 guid_, uint256 amountSD_, uint64 version_)
        internal
        returns (bool delivered)
    {
        try this.externalDeliverTransferSettled(transferId_, guid_, amountSD_, version_) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev `try` needs an external call; the base helper is internal.
    function externalDeliverTransferSettled(
        bytes32 transferId_,
        bytes32 guid_,
        uint256 amountReceivedSD_,
        uint64 stateVersion_
    ) external {
        _deliverTransferSettled(transferId_, guid_, amountReceivedSD_, stateVersion_);
    }

    // ------------------------------------------------------------------
    // Regression: the late receipt must consume its version
    // ------------------------------------------------------------------

    function testLateSettlementAfterForceResolveConsumesVersionAndKeepsLaneAlive() public {
        _readyDispatcher();
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 0, "precondition: frontier == 0");

        // Bridge out; the dispatcher will allocate remote state version 1 for this settlement.
        (bytes32 transferId, bytes32 guid,) = _sendAsset(100e6, 0);
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 100e6, "outbound in flight recorded");

        // The receipt is slow, so the admin force-resolves the transfer while it is still in flight.
        _forceResolve(transferId, ResolveOutcome.DELIVERED_TO_SETTLED);
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "outbound cleared by force-resolve");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "value moved into settled by the rescue");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 0, "force-resolve consumes no remote version");

        // The delayed authenticated receipt lands. It must consume version 1 and must NOT re-apply
        // the accounting the rescue already applied.
        vm.expectEmit(false, false, false, true);
        emit TransferSettlementConsumedWithoutAccounting(REMOTE_CHAIN, transferId, 1);
        assertTrue(_trySettle(transferId, guid, 100e6, 1), "late receipt executes");

        assertEq(
            executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN),
            1,
            "late TRANSFER_SETTLED must consume the state version the dispatcher allocated for it"
        );
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "no double credit on top of the rescue");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "in-flight untouched by the late receipt");

        // The lane is still usable: the next version-bearing message (version 2) applies normally.
        (bytes32 transferId2, bytes32 guid2,) = _sendAsset(50e6, 0);
        assertTrue(_trySettle(transferId2, guid2, 50e6, 2), "inbound lane must stay alive");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 2, "frontier advanced by the next message");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 150e6, "the next settlement credits normally");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "the next settlement clears its own in-flight");
    }

    /// @notice DROP_FROM_NAV is the other rescue outcome that sets `settled`. The late receipt must
    ///         still consume its version; since IL-8619 it credits the genuine delivery once.
    function testLateSettlementAfterDropFromNavConsumesVersionAndCreditsOnce() public {
        _readyDispatcher();
        (bytes32 transferId, bytes32 guid,) = _sendAsset(100e6, 0);

        _forceResolve(transferId, ResolveOutcome.DROP_FROM_NAV);
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "outbound dropped by the rescue");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "dropped value is not settled");

        assertTrue(_trySettle(transferId, guid, 100e6, 1), "late receipt executes");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 1, "version consumed");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "IL-8619: the genuine delivery is credited");

        (bytes32 transferId2, bytes32 guid2,) = _sendAsset(50e6, 0);
        assertTrue(_trySettle(transferId2, guid2, 50e6, 2), "inbound lane must stay alive");
    }

    // ------------------------------------------------------------------
    // The guard must not disturb the normal flows
    // ------------------------------------------------------------------

    /// @notice Happy path: a normal settlement still applies its accounting, and a genuine LayerZero
    ///         re-delivery of it is still a silent no-op that consumes no extra version.
    function testNormalSettlementAppliesOnceAndDuplicateIsSilentNoOp() public {
        _readyDispatcher();
        (bytes32 transferId, bytes32 guid,) = _sendAsset(100e6, 0);

        _deliverTransferSettled(transferId, guid, 99e6, 1);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 1, "frontier advanced once");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 99e6, "actual received amount credited");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "in-flight cleared");

        // Re-delivery of the exact same authenticated message: an older duplicate, applied nothing.
        _deliverTransferSettled(transferId, guid, 99e6, 1);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 1, "duplicate consumes no extra version");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 99e6, "duplicate does not double credit");

        // And the lane still accepts the next real message.
        (bytes32 transferId2, bytes32 guid2,) = _sendAsset(50e6, 0);
        _deliverTransferSettled(transferId2, guid2, 50e6, 2);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 2, "lane alive after a duplicate");
    }

    /// @notice A settlement naming a record that does not exist must still be rejected with
    ///         `TransferNotFound`, and must never be able to move this chain's frontier. The check sits above
    ///         the frontier advance as part of the fix, so pin it. The different-chain rejection
    ///         (`WrongSourceChain`) is pinned separately in `StargateTransferSettledIdentityTest`.
    function testSettlementForAnUnknownRecordStillReverts() public {
        _readyDispatcher();
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.TransferNotFound.selector, keccak256("no-such-transfer"))
        );
        this.externalDeliverTransferSettled(keccak256("no-such-transfer"), keccak256("g"), 1e6, 1);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 0, "frontier untouched by a bogus record");
    }
}
