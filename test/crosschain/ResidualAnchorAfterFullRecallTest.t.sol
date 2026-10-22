// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {stdStorage, StdStorage} from "forge-std/Test.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CcipExecutorAttestationLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";

/// @title StargateResidualAnchorAfterFullRecallTest
/// @notice IL-8606 / TP-M-28 on the Stargate transport. If the remote shares earn yield after the last
///         attestation, an ordinary REDEEM plus a full recall of the last approved amount leaves that yield
///         tracked on the dispatcher while the executor drains `settled` AND `anchorPrincipal` to zero, which
///         used to forbid any positive attestation (`UnanchoredAttestation`) and any further recall. The
///         dispatcher's authenticated post-debit balance (`ReturnStarted.remoteBalanceSD`) now keeps the
///         anchor at the residual when it exceeds `ATTESTATION_ZERO_DUST_SD`.
contract StargateResidualAnchorAfterFullRecallTest is CrosschainTestBase {
    function setUp() public {
        _baseSetUp();
        _readyDispatcher();
    }

    function _propose(uint256 settledLD_, uint64 stateVersion_) internal returns (uint256 proposalId) {
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
        return executor.proposalCount();
    }

    function _attest(uint256 settledLD_, uint64 stateVersion_) internal {
        uint256 pid = _propose(settledLD_, stateVersion_);
        vm.prank(approver);
        executor.approveBalance(pid);
    }

    /// @dev settle 100, attest 105 (the "last approved amount"), then a full recall of 105 in which the
    ///      dispatcher reports `residual_` still held on its side (yield earned after the attestation).
    function _fullRecallLeavingResidual(uint256 residual_) internal {
        _settle100(); // settled = anchor = 100e6, frontier 1
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(105e6, 1); // last approved amount
        (bytes32 requestId, , ) = _requestAssets(105e6, 0); // maxAccounted = min(105, 105)
        returnStartedRemoteBalanceSD = residual_;
        _deliverReturnStarted(requestId, RGUID, 105e6, 105e6, 2);
        usdc.mint(address(executor), 105e6);
        _deliverReturnCompose(requestId, RGUID, 105e6);
    }

    function testFullRecallLeavingYieldShouldKeepResidualAsAnchorWithoutCreditingSettled() public {
        _fullRecallLeavingResidual(7e6);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "settled drained, the residual is NOT credited");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 7e6, "anchor == dispatcher residual");
        assertEq(executor.getBalance(), 105e6, "NAV is the idle only until the residual is attested");
    }

    function testOrdinaryAttestationShouldPriceTheResidualAndNavFollows() public {
        _fullRecallLeavingResidual(7e6);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(7e6, 2);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 7e6, "residual priced by an ordinary attestation");
        assertEq(executor.getBalance(), 112e6, "NAV = idle 105 + residual 7");
    }

    function testResidualAttestationShouldStayInsideTheAnchorBand() public {
        _fullRecallLeavingResidual(10e6);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(12e6 + 1, 2); // band is 20%: 10e6 * 1.2 = 12e6
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                10e6,
                12e6 + 1,
                2_000
            )
        );
        executor.approveBalance(pid);

        // the band edge itself passes
        _attest(12e6, 2);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 12e6);
    }

    function testZeroToZeroAttestationShouldStayAllowedAndKeepTheResidualAnchor() public {
        _fullRecallLeavingResidual(7e6);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(0, 2);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0);
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 7e6, "anchor kept for a later honest attestation");
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(7e6, 2);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 7e6);
    }

    function testAnotherRecallOfTheResidualShouldBePossibleAfterAttestation() public {
        _fullRecallLeavingResidual(7e6);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(7e6, 2);

        (bytes32 requestId, , uint256 maxAccounted) = _requestAssets(7e6, 0);
        assertEq(maxAccounted, 7e6, "the residual is recallable");
        returnStartedRemoteBalanceSD = 0; // dispatcher is now empty
        _deliverReturnStarted(requestId, RGUID, 7e6, 7e6, 3);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0);
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 0, "nothing left: anchor back to zero");
    }

    function testResidualAtOrBelowDustShouldStillZeroTheAnchor() public {
        _fullRecallLeavingResidual(CrosschainConstants.ATTESTATION_ZERO_DUST_SD);

        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 0, "dust residual: anchor zeroed as before");
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(CrosschainConstants.ATTESTATION_ZERO_DUST_SD, 2);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.UnanchoredAttestation.selector,
                REMOTE_CHAIN,
                CrosschainConstants.ATTESTATION_ZERO_DUST_SD
            )
        );
        executor.approveBalance(pid);
    }

    function testResidualJustAboveDustShouldBeKept() public {
        _fullRecallLeavingResidual(CrosschainConstants.ATTESTATION_ZERO_DUST_SD + 1);
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), CrosschainConstants.ATTESTATION_ZERO_DUST_SD + 1);
    }

    function testNoRemoteBalanceEvidenceKeepsTheLegacyZeroBaseline() public {
        _fullRecallLeavingResidual(0);
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 0);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(50e6, 2);
        vm.prank(approver);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnanchoredAttestation.selector, REMOTE_CHAIN, 50e6));
        executor.approveBalance(pid);
    }

    /// @dev IL-8611: `getBalanceUnchecked()` is the booked value (idle + settled + in-flight) without the gates.
    function testGetBalanceUncheckedShouldReturnTheBookedValueWhereGetBalanceRevertsOnStargate() public {
        _settle100(); // settled 100e6 with no approved observation: getBalance() fails closed
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        executor.getBalance();
        assertEq(executor.getBalanceUnchecked(), 100e6);
    }

    function testPartialRecallIgnoresTheResidualEvidence() public {
        _settle100();
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(105e6, 1);
        (bytes32 requestId, , ) = _requestAssets(50e6, 0);
        returnStartedRemoteBalanceSD = 60e6; // evidence only matters when the bucket is emptied
        _deliverReturnStarted(requestId, RGUID, 50e6, 50e6, 2);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 55e6);
        assertLt(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 60e6, "pro-rata anchor, not the evidence");
    }

    /// @dev B2: a reported residual ABOVE the pre-debit anchor can never raise the anchor.
    function testReportedResidualAbovePreDebitAnchorShouldBeCappedAtThePreDebitAnchor() public {
        _settle100();
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(105e6, 1);
        uint256 preDebitAnchor = executor.attestationAnchorPrincipal(REMOTE_CHAIN);
        (bytes32 requestId, , ) = _requestAssets(105e6, 0);
        returnStartedRemoteBalanceSD = preDebitAnchor + 500e6; // inflated, e.g. a manipulated vault price
        _deliverReturnStarted(requestId, RGUID, 105e6, 105e6, 2);
        usdc.mint(address(executor), 105e6);
        _deliverReturnCompose(requestId, RGUID, 105e6);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0);
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), preDebitAnchor, "anchor == pre-debit anchor");
    }

    /// @dev N4: a credit landing BEFORE the residual is attested caps the anchor at the credited amount
    ///      (`min(R + D, netPrincipal = D)`), so the residual falls out of the band. This is the documented
    ///      reason to attest the residual BEFORE re-supplying.
    function testCreditBeforeResidualAttestationShouldCapTheAnchorAtTheCredit() public {
        _fullRecallLeavingResidual(7e6);
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 7e6);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        (bytes32 transferId, bytes32 guid, ) = _sendAsset(50e6, 0);
        _deliverTransferSettled(transferId, guid, 50e6, 3);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 50e6);
        assertEq(
            executor.attestationAnchorPrincipal(REMOTE_CHAIN),
            50e6,
            "anchor = min(R + D, D) = D, the residual is lost"
        );
    }

    // ------------------------------------------------------------------
    // IL-8792 (#57): a top-up on a (settled 0, anchor R, net N > 0) residual
    // ------------------------------------------------------------------

    /// @dev settle 100, attest `100 - loss_` (an approved loss), a full recall of the attested amount in which the
    ///      dispatcher reports `residual_` (net principal = loss_), then a top-up of `topUp_` that lands before the
    ///      residual is attested. Ends with settled = topUp_, anchor = min(residual_, loss_) + topUp_.
    function _topUpOnResidual(uint256 loss_, uint256 residual_, uint256 topUp_) internal {
        _settle100();
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(100e6 - loss_, 1);
        (bytes32 requestId, , ) = _requestAssets(100e6 - loss_, 0);
        returnStartedRemoteBalanceSD = residual_;
        _deliverReturnStarted(requestId, RGUID, 100e6 - loss_, 100e6 - loss_, 2);
        usdc.mint(address(executor), 100e6 - loss_);
        _deliverReturnCompose(requestId, RGUID, 100e6 - loss_);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        (bytes32 transferId, bytes32 guid, ) = _sendAsset(topUp_, 0);
        _deliverTransferSettled(transferId, guid, topUp_, 3);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
    }

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256) {
        return a_ < b_ ? a_ : b_;
    }

    function _outsideBand(uint256 value_, uint256 anchor_) internal pure returns (bool) {
        uint256 diff = value_ > anchor_ ? value_ - anchor_ : anchor_ - value_;
        return diff * 10_000 > anchor_ * CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS;
    }

    /// @dev #57 numbers: bigChange 10%, (0, R = 8, N = 10) + 5 gives (5, 13); window [4.5; 5.5] vs band [10.4; 15.6].
    function testTopUpOnResidualWithNetPrincipalShouldPriceTheTrueValue() public {
        _topUpOnResidual(10e6, 8e6, 5e6);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 5e6, "top-up credited to settled");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 13e6, "anchor = min(R, N) + c");

        _attest(13e6, 3); // the true remote value; the relative window around settled 5 is disjoint from the band
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 13e6, "true value approved");
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        assertEq(executor.getBalance(), 90e6 + 5e6 + 13e6 - 5e6, "NAV prices the residual: idle 95 - 5 sent + 13");
    }

    function testTopUpOnResidualShouldStillBeBoundedByTheBand() public {
        _topUpOnResidual(10e6, 8e6, 5e6); // anchor 13e6
        uint256 snap = vm.snapshotState();

        uint256 pid = _propose(15.6e6 + 1, 3);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                13e6,
                15.6e6 + 1,
                2_000
            )
        );
        executor.approveBalance(pid);

        vm.revertToState(snap);
        pid = _propose(10.4e6 - 1, 3);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                13e6,
                10.4e6 - 1,
                2_000
            )
        );
        executor.approveBalance(pid);

        // the band edges themselves pass
        vm.revertToState(snap);
        _attest(15.6e6, 3);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 15.6e6);
        vm.revertToState(snap);
        _attest(10.4e6, 3);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 10.4e6);
    }

    function testRelativeLimiterShouldReturnAfterTheFirstBandApproval() public {
        _topUpOnResidual(10e6, 8e6, 5e6);
        _attest(10.4e6, 3); // the band floor, approved from the below-band settled 5e6
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(11.44e6 + 1, 3); // inside the band, a step above 10% from the now in-band settled
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.BigChangeExceeded.selector, 10.4e6, 11.44e6 + 1, BIG_CHANGE_BPS)
        );
        executor.approveBalance(pid);
    }

    function testFuzz_topUpOnResidualAlwaysLeavesAnApprovableValue(
        uint256 loss_,
        uint256 residual_,
        uint256 topUp_
    ) public {
        loss_ = bound(loss_, 1e6, 10e6);
        residual_ = bound(residual_, 1e6, 100e6);
        // top-up below 4 * min(R, N): `settled` lands strictly below the band, the branch the fix changes
        topUp_ = bound(topUp_, 1e6, _min(50e6, 4 * _min(residual_, loss_) - 1));
        _topUpOnResidual(loss_, residual_, topUp_);

        uint256 settled = executor.settledRemoteBalance(REMOTE_CHAIN);
        uint256 anchor = executor.attestationAnchorPrincipal(REMOTE_CHAIN);
        assertEq(settled, topUp_);
        assertTrue(_outsideBand(settled, anchor), "fuzz must reach the below-band state");
        _attest(anchor, 3); // `settled` below the band: the anchor (the true value) must be approvable
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), anchor);
    }
}

/// @title CcipResidualAnchorAfterFullRecallTest
/// @notice IL-8606 / TP-M-28 on the CCIP transport: `RETURN_TRANSFER` carries the dispatcher's post-debit
///         reported balance. Yield is injected as extra tracked idle on the real dispatcher (what a REDEEM of
///         appreciated remote shares leaves behind).
contract CcipResidualAnchorAfterFullRecallTest is CcipExecutorFixture {
    using stdStorage for StdStorage;

    function setUp() public {
        _fixtureSetUp();
    }

    /// @dev Yield realised as tracked idle on the dispatcher (tokens + accounting move together).
    function _accrueYield(uint256 amount_) internal {
        token.mint(address(dispatcher), amount_);
        stdstore.target(address(dispatcher)).sig("trackedIdle()").checked_write(dispatcher.trackedIdle() + amount_);
    }

    /// @dev bridge 100, attest `attested_`, yield `yield_` accrues afterwards, then a full recall of `attested_`.
    function _fullRecallAfterYield(uint256 attested_, uint256 yield_) internal {
        _bridge(100e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(attested_);
        _accrueYield(yield_);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, attested_, 0, 0, address(0), 500_000);
    }

    function testFullRecallLeavingYieldShouldKeepResidualAsAnchorWithoutCreditingSettled() public {
        _fullRecallAfterYield(105e18, 12e18); // dispatcher holds 112, recall pays 105, residual 7

        assertEq(dispatcher.accountedBalance(), 7e18, "dispatcher still tracks the residual");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "settled drained, residual NOT credited");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 7e18, "anchor == dispatcher residual");
        assertEq(executor.getBalance(), 105e18, "NAV is the idle only until the residual is attested");
    }

    function testOrdinaryAttestationShouldPriceTheResidualAndNavFollows() public {
        _fullRecallAfterYield(105e18, 12e18);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(7e18);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 7e18);
        assertEq(executor.getBalance(), 112e18, "NAV = idle 105 + residual 7 = the true total");
    }

    function testResidualAttestationShouldStayInsideTheAnchorBand() public {
        _fullRecallAfterYield(105e18, 15e18); // residual 10
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(12e18 + 1);
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                10e18,
                12e18 + 1,
                2_000
            )
        );
        executor.approveBalance(pid);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(12e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 12e18);
    }

    function testZeroToZeroAttestationShouldStayAllowedAndKeepTheResidualAnchor() public {
        _fullRecallAfterYield(105e18, 12e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(0);
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 7e18, "anchor kept");
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(7e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 7e18);
    }

    function testAnotherRecallOfTheResidualShouldBePossibleAfterAttestation() public {
        _fullRecallAfterYield(105e18, 12e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(7e18);

        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 7e18, 0, 0, address(0), 500_000);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0);
        assertEq(dispatcher.accountedBalance(), 0);
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 0, "nothing left: anchor back to zero");
        assertEq(executor.getBalance(), 112e18);
    }

    function testResidualAtOrBelowDustShouldStillZeroTheAnchor() public {
        _fullRecallAfterYield(100e18, CrosschainConstants.ATTESTATION_ZERO_DUST_SD); // residual == dust

        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 0, "dust residual: anchor zeroed as before");
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(CrosschainConstants.ATTESTATION_ZERO_DUST_SD);
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.UnanchoredAttestation.selector,
                REMOTE_CHAIN,
                CrosschainConstants.ATTESTATION_ZERO_DUST_SD
            )
        );
        executor.approveBalance(pid);
    }

    function testResidualJustAboveDustShouldBeKept() public {
        _fullRecallAfterYield(100e18, CrosschainConstants.ATTESTATION_ZERO_DUST_SD + 1);
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), CrosschainConstants.ATTESTATION_ZERO_DUST_SD + 1);
    }

    /// @dev B2: a reported residual ABOVE the pre-debit anchor can never raise the anchor.
    function testReportedResidualAbovePreDebitAnchorShouldBeCappedAtThePreDebitAnchor() public {
        _bridge(100e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(105e18);
        uint256 preDebitAnchor = executor.attestationAnchorPrincipal(REMOTE_CHAIN);
        _accrueYield(500e18);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 105e18, 0, 0, address(0), 500_000);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0);
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), preDebitAnchor, "anchor == pre-debit anchor");
    }

    /// @dev N4: a credit landing BEFORE the residual is attested caps the anchor at the credited amount
    ///      (`min(R + D, netPrincipal = D)`). This is the documented reason to attest the residual BEFORE
    ///      re-supplying.
    function testCreditBeforeResidualAttestationShouldCapTheAnchorAtTheCredit() public {
        _fullRecallAfterYield(105e18, 12e18);
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 7e18);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _bridge(50e18);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 50e18);
        assertEq(
            executor.attestationAnchorPrincipal(REMOTE_CHAIN),
            50e18,
            "anchor = min(R + D, D) = D, the residual is lost"
        );
    }

    // ------------------------------------------------------------------
    // IL-8737 (#2): a top-up on a (settled 0, anchor R, net N > 0) residual
    // ------------------------------------------------------------------

    /// @dev Remote loss realised on the dispatcher's tracked idle (tokens + accounting move together).
    function _realiseLoss(uint256 amount_) internal {
        vm.prank(address(dispatcher));
        token.transfer(address(0xdead), amount_);
        stdstore.target(address(dispatcher)).sig("trackedIdle()").checked_write(dispatcher.trackedIdle() - amount_);
    }

    /// @dev bridge 100, an attested loss of `loss_`, remote value grows by `residual_`, a full recall of the attested
    ///      amount (residual `residual_` stays remote, net principal = loss_), then a top-up of `topUp_`. Ends with
    ///      settled = topUp_, anchor = min(residual_, loss_) + topUp_.
    function _topUpOnResidual(uint256 loss_, uint256 residual_, uint256 topUp_) internal {
        _bridge(100e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _realiseLoss(loss_);
        _attest(100e18 - loss_);
        _accrueYield(residual_);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 100e18 - loss_, 0, 0, address(0), 500_000);
        _bridge(topUp_);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
    }

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256) {
        return a_ < b_ ? a_ : b_;
    }

    function _outsideBand(uint256 value_, uint256 anchor_) internal pure returns (bool) {
        uint256 diff = value_ > anchor_ ? value_ - anchor_ : anchor_ - value_;
        return diff * 10_000 > anchor_ * CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS;
    }

    /// @dev PoC 8c4ec8d6: bigChange 20%, (0, R = 10, N = 10) + 10 gives (10, 20); window [8; 12] vs band [16; 24].
    function testTopUpOnResidualWithNetPrincipalShouldPriceTheTrueValue() public {
        _bridge(100e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _realiseLoss(10e18);
        _attest(90e18);
        uint256 oldObservedAt = uint256(executor.lastApprovedObservedAt(REMOTE_CHAIN));
        _accrueYield(10e18);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 90e18, 0, 0, address(0), 500_000);
        _bridge(10e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 10e18, "top-up credited to settled");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 20e18, "anchor = min(R, N) + c");
        assertEq(dispatcher.accountedBalance(), 20e18, "true remote value");

        _attest(20e18); // disjoint windows before the fix: BigChangeExceeded for every value in the band
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 20e18, "true value approved");

        // NAV no longer freezes once the OLD observation would have gone stale
        vm.warp(oldObservedAt + BALANCE_STALENESS_MAX + 1);
        assertEq(executor.getBalance(), 90e18 + 20e18, "NAV = idle 90 + settled 20");
    }

    function testTopUpOnResidualShouldStillBeBoundedByTheBand() public {
        _topUpOnResidual(10e18, 10e18, 10e18); // anchor 20e18
        uint256 snap = vm.snapshotState();

        uint256 pid = _propose(24e18 + 1);
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                20e18,
                24e18 + 1,
                2_000
            )
        );
        executor.approveBalance(pid);

        vm.revertToState(snap);
        pid = _propose(16e18 - 1);
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                20e18,
                16e18 - 1,
                2_000
            )
        );
        executor.approveBalance(pid);

        // the band edges themselves pass
        vm.revertToState(snap);
        _attest(24e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 24e18);
        vm.revertToState(snap);
        _attest(16e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 16e18);
    }

    function testRelativeLimiterShouldReturnAfterTheFirstBandApproval() public {
        _topUpOnResidual(10e18, 10e18, 10e18);
        _attest(16e18); // the band floor, approved from the below-band settled 10e18
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(19.2e18 + 1); // inside the band (24e18), a step above 20% from the in-band settled 16
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorAttestationLib.BigChangeExceeded.selector, 16e18, 19.2e18 + 1, 2_000)
        );
        executor.approveBalance(pid);
    }

    function testFuzz_topUpOnResidualAlwaysLeavesAnApprovableValue(
        uint256 loss_,
        uint256 residual_,
        uint256 topUp_
    ) public {
        loss_ = bound(loss_, 1e18, 20e18);
        residual_ = bound(residual_, 1e18, 100e18);
        // top-up below 4 * min(R, N): `settled` lands strictly below the band, the branch the fix changes
        topUp_ = bound(topUp_, 1e18, _min(100e18, 4 * _min(residual_, loss_) - 1));
        _topUpOnResidual(loss_, residual_, topUp_);

        uint256 settled = executor.settledRemoteBalance(REMOTE_CHAIN);
        uint256 anchor = executor.attestationAnchorPrincipal(REMOTE_CHAIN);
        assertEq(settled, topUp_);
        assertTrue(_outsideBand(settled, anchor), "fuzz must reach the below-band state");
        _attest(anchor); // `settled` below the band: the anchor (the true value) must be approvable
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), anchor);
    }
}
