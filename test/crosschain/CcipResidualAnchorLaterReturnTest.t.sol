// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";

import {CcipExecutorFixture} from "test/crosschain/CcipExecutorFixture.sol";
import {
    CcipAttestationState,
    CcipExecutorAttestationLib
} from "contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";
import {CrosschainConstants} from "contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "contracts/crosschain/lib/CrosschainErrors.sol";

/// @title CcipResidualAnchorLaterReturnTest
/// @notice IL-9134 (Codex ccip-exec C-001): a later authenticated return at `settled == 0` must move the residual
///         anchor to the dispatcher's authenticated balance instead of leaving the stale residual of the first
///         return in place. End-to-end on the real executor and dispatcher (port of the audit PoC).
/// @dev Attestation order matters (Codex #1): once a non-zero balance is approved, `settled != 0` and the relative
///      limiter (`bigChangeBps` = 2_000) fires before the anchor band, so every above-band proposal is made while
///      `settled` is still zero, before any truthful approval, and the cases are isolated by state snapshots.
contract CcipResidualAnchorLaterReturnTest is CcipExecutorFixture {
    bytes32 private constant ANCHOR_UPDATED_TOPIC = keccak256("AttestationAnchorUpdated(uint256,uint256)");

    function setUp() public {
        vm.warp(365 days);
        _fixtureSetUp();
    }

    /// @dev Supply 100, attest 80, stall the response lane, recall R1 = 80 (reported balance 20), cancel R1
    ///      locally, recall R2 = `r2_` and flush both: they land in version order, R2 at `settled == 0`.
    function _reachLaterReturnAtZeroSettled(uint256 r2_) internal returns (Vm.Log[] memory logs) {
        _bridge(100e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(80e18);

        router.setFailSend(address(dispatcher), true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 80e18, 0, 0, address(0), 500_000);
        executor.cancelPendingReturn(REMOTE_CHAIN);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, r2_, 0, 0, address(0), 500_000);

        router.setFailSend(address(dispatcher), false);
        vm.recordLogs();
        dispatcher.flushResponse(2);
        logs = vm.getRecordedLogs();

        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), 3, "both returns applied");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "settled is zero");
    }

    function _lastAnchorEvent(Vm.Log[] memory logs_) internal view returns (bool seen, uint256 principal) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter != address(executor) || logs_[i].topics[0] != ANCHOR_UPDATED_TOPIC) continue;
            (uint256 chainId, uint256 p) = abi.decode(logs_[i].data, (uint256, uint256));
            if (chainId == REMOTE_CHAIN) {
                seen = true;
                principal = p;
            }
        }
    }

    function _approveExpectingBandRevert(uint256 proposed_, uint256 anchor_) internal {
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(proposed_);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                anchor_,
                proposed_,
                CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS
            )
        );
        vm.prank(APPROVER);
        executor.approveBalance(pid);
    }

    function testShouldClearResidualAnchorWhenLaterReturnEmptiesDispatcher() public {
        Vm.Log[] memory logs = _reachLaterReturnAtZeroSettled(20e18);

        assertEq(executor.idleLedger(), 100e18, "all 100 are back home");
        assertEq(dispatcher.accountedBalance(), 0, "remote holds nothing");
        assertEq(executor.attestationNetPrincipal(REMOTE_CHAIN), 0, "net principal is zero");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 0, "stale residual anchor cleared");
        (bool seen, uint256 principal) = _lastAnchorEvent(logs);
        assertTrue(seen, "AttestationAnchorUpdated emitted");
        assertEq(principal, 0, "R2 reported a zero balance");
        assertEq(executor.getBalance(), 100e18, "NAV is the idle only");

        // Phantom value cannot be written from the zero baseline (made at settled == 0, before any approval).
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(24e18);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnanchoredAttestation.selector, REMOTE_CHAIN, 24e18));
        vm.prank(APPROVER);
        executor.approveBalance(pid);
        assertEq(executor.getBalance(), 100e18, "NAV unchanged");

        // A truthful zero attestation still passes.
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(0);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "zero to zero approved");
        assertEq(executor.getBalance(), 100e18, "NAV after zero approval");
    }

    function testShouldRejectAboveBandAttestationAfterLaterPartialReturn() public {
        _reachLaterReturnAtZeroSettled(15e18);

        assertEq(dispatcher.accountedBalance(), 5e18, "remote holds the 5 residual");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 5e18, "anchor follows the reported balance");
        assertEq(
            executor.getBalance(),
            95e18,
            "NAV is the 95 at home, the residual is not in it before it is attested"
        );

        // Above the band (every case at settled == 0, isolated by snapshots).
        uint256 snap = vm.snapshotState();
        _approveExpectingBandRevert(6e18 + 1, 5e18);
        vm.revertToState(snap);
        _approveExpectingBandRevert(24e18, 5e18);
        vm.revertToState(snap);
        _approveExpectingBandRevert(20e18, 5e18);
    }

    function testShouldApproveTruthfulResidualAfterLaterPartialReturn() public {
        _reachLaterReturnAtZeroSettled(15e18);
        uint256 snap = vm.snapshotState();

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(5e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 5e18, "truthful residual approved");

        vm.revertToState(snap);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(6e18); // upper edge of the band
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 6e18, "upper band edge approved");
    }
}

/// @title CcipResidualAnchorLaterReturnHarnessTest
/// @notice Boundary tests of the IL-9134 rule on `CcipExecutorAttestationLib.applyReturnDebit` at `settled == 0`
///         (external call into the linked library, state owned by this contract).
contract CcipResidualAnchorLaterReturnHarnessTest is Test {
    uint256 private constant CHAIN = 8453;
    bytes32 private constant ANCHOR_UPDATED_TOPIC = keccak256("AttestationAnchorUpdated(uint256,uint256)");

    CcipAttestationState internal state;
    mapping(uint256 => uint256) internal settled;

    function _apply(uint256 sentSD_, uint256 remoteBalanceSD_) internal returns (uint256 debit, Vm.Log[] memory logs) {
        vm.recordLogs();
        debit = CcipExecutorAttestationLib.applyReturnDebit(
            state,
            settled,
            CHAIN,
            bytes32(uint256(1)),
            sentSD_,
            0,
            remoteBalanceSD_
        );
        logs = vm.getRecordedLogs();
    }

    function _anchorEvents(Vm.Log[] memory logs_) internal pure returns (uint256 count, uint256 last) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].topics[0] != ANCHOR_UPDATED_TOPIC) continue;
            ++count;
            (, last) = abi.decode(logs_[i].data, (uint256, uint256));
        }
    }

    function testShouldZeroAnchorWhenLaterReturnLeavesOnlyDust() public {
        state.anchorPrincipal[CHAIN] = 20e18;
        (, Vm.Log[] memory logs) = _apply(5e18, CrosschainConstants.ATTESTATION_ZERO_DUST_SD);
        assertEq(state.anchorPrincipal[CHAIN], 0, "dust balance zeroes the anchor");
        (uint256 count, uint256 last) = _anchorEvents(logs);
        assertEq(count, 1, "one anchor event");
        assertEq(last, 0, "event carries zero");
    }

    function testShouldFollowReportedBalanceJustAboveDust() public {
        state.anchorPrincipal[CHAIN] = 20e18;
        uint256 remote = CrosschainConstants.ATTESTATION_ZERO_DUST_SD + 1;
        (, Vm.Log[] memory logs) = _apply(5e18, remote);
        assertEq(state.anchorPrincipal[CHAIN], remote, "non-dust balance becomes the anchor");
        (, uint256 last) = _anchorEvents(logs);
        assertEq(last, remote, "event carries the new anchor");
    }

    function testShouldNotRaiseAnchorOnLaterReturn() public {
        state.anchorPrincipal[CHAIN] = 5e18;
        (, Vm.Log[] memory logs) = _apply(5e18, 9e18);
        assertEq(state.anchorPrincipal[CHAIN], 5e18, "anchor never rises above its previous value");
        (, uint256 last) = _anchorEvents(logs);
        assertEq(last, 5e18, "event carries the capped anchor");
    }

    function testShouldKeepAnchorOnZeroAmountReturnAtZeroSettled() public {
        state.anchorPrincipal[CHAIN] = 5e18;
        (uint256 debit, Vm.Log[] memory logs) = _apply(0, 0);
        assertEq(debit, 0, "no debit");
        assertEq(state.anchorPrincipal[CHAIN], 5e18, "anchor untouched");
        (uint256 count, ) = _anchorEvents(logs);
        assertEq(count, 0, "no anchor event");
    }

    function testShouldKeepSettledAndDebitZero() public {
        state.anchorPrincipal[CHAIN] = 20e18;
        state.netPrincipal[CHAIN] = 30e18;
        (uint256 debit, ) = _apply(12e18, 8e18);
        assertEq(debit, 0, "nothing to debit");
        assertEq(settled[CHAIN], 0, "settled stays zero");
        assertEq(state.netPrincipal[CHAIN], 18e18, "net principal reduced by the declared amount as before");
        assertEq(state.anchorPrincipal[CHAIN], 8e18, "anchor follows the reported balance");
    }
}
