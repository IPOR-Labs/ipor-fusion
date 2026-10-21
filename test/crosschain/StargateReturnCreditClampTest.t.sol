// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

/// @title StargateReturnCreditClampTest
/// @notice IL-8293 (duplicate of IL-8264 M-09, `unbounded_peer_reported_credit_into_nav`). An inbound
///         `RETURN_STARTED` debited `settledRemoteBalance` by the accounted bound but booked the peer-reported
///         `amountReceivedSD` into `returnInFlight` verbatim, so a non-conforming dispatcher could inflate the
///         executor's NAV without limit until the compose landed. The credit is now clamped to the settled
///         debit that the same message applied, so recall metadata can never raise NAV.
contract StargateReturnCreditClampTest is CrosschainTestBase {
    bytes32 internal constant RETURN_CREDIT_CLAMPED_TOPIC =
        keccak256("ReturnCreditClamped(uint256,bytes32,uint256,uint256)");

    event ReturnMetadataApplied(
        uint256 srcChainId,
        bytes32 requestId,
        bytes32 guid,
        uint256 amountSentSD,
        uint256 debitedSD,
        uint256 inFlightCreditSD,
        uint64 stateVersion
    );
    event ReturnFinalized(uint256 srcChainId, bytes32 requestId, uint256 idleCreditSD);

    function setUp() public {
        _baseSetUp();
        _readyDispatcher();
        _settle100(); // settled = 100e6, frontier = 2
    }

    /// @notice Regression: the PoC shape. A 40e6 recall, an honest `amountSentSD` and a 1e9 reported credit.
    function testInflatedReturnCreditShouldNotRaiseNav() public {
        (bytes32 requestId,, uint256 maxAccountedSD) = _requestAssets(40e6, 0);
        assertEq(maxAccountedSD, 40e6, "precondition: recall bound");
        uint256 navBefore = executor.getBalanceByChain(REMOTE_CHAIN);

        vm.recordLogs();
        _deliverReturnStarted(requestId, RGUID, 40e6, 1e9, 2);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "settled debited by the accounted bound");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 40e6, "credit clamped to the accounted debit");
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), navBefore, "metadata must not raise chain NAV");
        _assertClamped(requestId, 1e9, 40e6);
    }

    /// @notice Regression: the bound is the debit actually applied, not `maxAccountedSD`. Settled is attested
    ///         down to 90e6 after a 100e6 recall was requested, so the message can only debit 90e6; crediting
    ///         up to `maxAccountedSD` (100e6) would still raise NAV by 10e6.
    function testCreditShouldBeBoundedBySettledDebitWhenAttestedBelowRecallBound() public {
        (bytes32 requestId,, uint256 maxAccountedSD) = _requestAssets(100e6, 0);
        assertEq(maxAccountedSD, 100e6, "precondition: recall bound");
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(90e6, 1);
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 90e6, "precondition: settled attested down");

        vm.recordLogs();
        _deliverReturnStarted(requestId, RGUID, 100e6, 100e6, 2);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "only the attested 90e6 is debited");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 90e6, "credit bounded by the settled debit");
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 90e6, "metadata must not raise chain NAV");
        _assertClamped(requestId, 100e6, 90e6);
    }

    /// @notice The clamped figure is what the compose removes: finalization does not underflow and the real
    ///         delivered amount is recognised as idle.
    function testComposeAfterClampedMetadataShouldCreditDeliveredAmount() public {
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        _deliverReturnStarted(requestId, RGUID, 40e6, 1e9, 2);

        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);

        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "expected credit fully removed");
        assertEq(executor.idleLedger(), 40e6, "delivered amount credited as idle");
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 60e6, "remaining settled only");
    }

    /// @notice The clamped figure is what `DROP_FROM_NAV` removes: the rescue does not underflow.
    function testDropFromNavAfterClampedMetadataShouldClearReturnInFlight() public {
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        _deliverReturnStarted(requestId, RGUID, 40e6, 1e9, 2);

        vm.prank(admin);
        uint256 resolveId = executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.DROP_FROM_NAV);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(resolveId, requestId, ResolveOutcome.DROP_FROM_NAV);

        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "dropped credit fully removed");
    }

    /// @notice Control: an honest recall that loses a route fee books the reported credit unchanged.
    function testHonestReturnWithRouteFeeShouldBookReportedCredit() public {
        (bytes32 requestId,,) = _requestAssets(40e6, 0);

        vm.recordLogs();
        _deliverReturnStarted(requestId, RGUID, 40e6, 39_990_000, 2);

        assertEq(executor.returnInFlight(REMOTE_CHAIN), 39_990_000, "reported credit booked as is");
        assertFalse(_clampEmitted(), "no clamp on an honest lane");
    }

    /// @notice IL-8464 (B-03), order (a) without a clamp: the event carries the guid, the settled debit and the
    ///         in-flight credit, and the credit equals the `returnInFlight` delta.
    function testShouldEmitDebitAndInFlightCreditOnMetadataFirst() public {
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        uint256 inFlightBefore = executor.returnInFlight(REMOTE_CHAIN);

        vm.expectEmit(false, false, false, true, address(executor));
        emit ReturnMetadataApplied(REMOTE_CHAIN, requestId, RGUID, 40e6, 40e6, 39_990_000, 2);
        _deliverReturnStarted(requestId, RGUID, 40e6, 39_990_000, 2);

        assertEq(executor.returnInFlight(REMOTE_CHAIN) - inFlightBefore, 39_990_000, "delta equals the event credit");
    }

    /// @notice IL-8464 (B-03), order (a) with a clamp: the event reports the clamped credit, not the reported one.
    function testShouldEmitClampedInFlightCreditOnMetadataFirst() public {
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        uint256 inFlightBefore = executor.returnInFlight(REMOTE_CHAIN);

        vm.expectEmit(false, false, false, true, address(executor));
        emit ReturnMetadataApplied(REMOTE_CHAIN, requestId, RGUID, 40e6, 40e6, 40e6, 2);
        _deliverReturnStarted(requestId, RGUID, 40e6, 1e9, 2);

        assertEq(executor.returnInFlight(REMOTE_CHAIN) - inFlightBefore, 40e6, "delta equals the clamped credit");
    }

    /// @notice IL-8464 (B-03), order (b): compose first, so the metadata books nothing into `returnInFlight`
    ///         (`inFlightCreditSD == 0`) and the actual credit is carried by `ReturnFinalized` in the same tx.
    function testShouldEmitZeroInFlightCreditOnComposeFirst() public {
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);

        vm.expectEmit(false, false, false, true, address(executor));
        emit ReturnFinalized(REMOTE_CHAIN, requestId, 40e6);
        vm.expectEmit(false, false, false, true, address(executor));
        emit ReturnMetadataApplied(REMOTE_CHAIN, requestId, RGUID, 40e6, 40e6, 0, 2);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);

        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "nothing booked in flight");
        assertEq(executor.idleLedger(), 40e6, "actual credit went straight to idle");
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _attest(uint256 settledLD_, uint64 stateVersion_) internal {
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: settledLD_,
            stateVersion: stateVersion_,
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        uint256 proposalId = executor.proposalCount();
        vm.prank(approver);
        executor.approveBalance(proposalId);
    }

    function _assertClamped(bytes32 requestId_, uint256 reported_, uint256 credited_) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == RETURN_CREDIT_CLAMPED_TOPIC) {
                assertEq(logs[i].emitter, address(executor), "emitted by the executor");
                (uint256 chainId, bytes32 requestId, uint256 reported, uint256 credited) =
                    abi.decode(logs[i].data, (uint256, bytes32, uint256, uint256));
                assertEq(chainId, REMOTE_CHAIN, "clamp chain");
                assertEq(requestId, requestId_, "clamp request");
                assertEq(reported, reported_, "clamp reported");
                assertEq(credited, credited_, "clamp credited");
                return;
            }
        }
        revert("ReturnCreditClamped not emitted");
    }

    function _clampEmitted() internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == RETURN_CREDIT_CLAMPED_TOPIC) return true;
        }
        return false;
    }
}
