// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {
    CcipAttestationState,
    CcipExecutorAttestationLib
} from "../../contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";

/// @title ResidualAnchorReportedBalanceFuzzTest
/// @notice IL-9602 (M12) pinning fuzz suite. The residual anchor set by a return that empties the attested bucket
///         follows the dispatcher's REPORTED balance (a sum of `convertToAssets` reads, an unreadable position counts
///         as 0). The report can be inflated (spot price) or deflated (unreadable position). These properties pin
///         what the code guarantees for every reported value: the anchor never rises above its pre-debit value,
///         `settled` never rises from the reported number, and NAV carries no residual until it is attested.
/// @dev Pinning tests: they pass on base 8692fbe5 and on the current series state; no code is changed by IL-9602.
///      Fault injection (done by hand, not committed): dropping the `remoteBalanceSD_ < principal` cap in
///      `CcipExecutorAttestationLib.applyReturnDebit` fails `testFuzz_anchorNeverRisesAboveItsPreDebitValue`.
contract ResidualAnchorReportedBalanceFuzzTest is Test {
    uint256 private constant CHAIN = 8453;

    CcipAttestationState internal state;
    mapping(uint256 => uint256) internal settled;

    function setUp() public {
        // IL-9720: the band is a per-executor value the harness has to set, as the executor constructor does.
        state.anchorBandBps = 2_000;
    }

    function _debit(uint256 sentSD_, uint256 maxAccounted_, uint256 remoteBalanceSD_) internal returns (uint256) {
        return
            CcipExecutorAttestationLib.applyReturnDebit(
                state,
                settled,
                CHAIN,
                bytes32(uint256(1)),
                sentSD_,
                maxAccounted_,
                remoteBalanceSD_
            );
    }

    /// @dev Band-legal pre-debit pair: `settled <= principal * 1.2`.
    function _seed(uint256 principal_, uint256 settledBps_) internal {
        state.anchorPrincipal[CHAIN] = principal_;
        settled[CHAIN] = (principal_ * settledBps_) / 10_000;
        state.netPrincipal[CHAIN] = principal_;
    }

    function testFuzz_anchorNeverRisesAboveItsPreDebitValue(
        uint256 principal_,
        uint256 settledBps_,
        uint256 sentSD_,
        uint256 maxAccounted_,
        uint256 remoteBalanceSD_
    ) public {
        principal_ = bound(principal_, 1, 1e30);
        settledBps_ = bound(settledBps_, 0, 12_000);
        sentSD_ = bound(sentSD_, 0, 2e30);
        maxAccounted_ = bound(maxAccounted_, 0, 2e30);
        _seed(principal_, settledBps_);
        uint256 anchorBefore = state.anchorPrincipal[CHAIN];

        _debit(sentSD_, maxAccounted_, remoteBalanceSD_);

        assertLe(state.anchorPrincipal[CHAIN], anchorBefore, "anchor never rises on a debit");
    }

    function testFuzz_settledNeverRisesFromTheReportedBalance(
        uint256 principal_,
        uint256 settledBps_,
        uint256 sentSD_,
        uint256 maxAccounted_,
        uint256 remoteBalanceSD_
    ) public {
        principal_ = bound(principal_, 1, 1e30);
        settledBps_ = bound(settledBps_, 0, 12_000);
        sentSD_ = bound(sentSD_, 0, 2e30);
        maxAccounted_ = bound(maxAccounted_, 0, 2e30);
        _seed(principal_, settledBps_);
        uint256 settledBefore = settled[CHAIN];

        uint256 debit = _debit(sentSD_, maxAccounted_, remoteBalanceSD_);

        assertLe(settled[CHAIN], settledBefore, "settled never rises");
        assertEq(settled[CHAIN], settledBefore - debit, "settled moves only by the debit");
        assertLe(debit, sentSD_, "debit never above the declared amount");
    }

    /// @dev A full recall (bucket emptied) keeps the reported residual as the anchor only above dust, capped at
    ///      the pre-debit anchor; at or below dust the anchor is zero.
    function testFuzz_fullRecallAnchorIsTheCappedReportedResidual(uint256 principal_, uint256 remoteBalanceSD_) public {
        principal_ = bound(principal_, 1, 1e30);
        _seed(principal_, 10_000);
        uint256 bucket = settled[CHAIN];

        _debit(bucket, bucket, remoteBalanceSD_);

        assertEq(settled[CHAIN], 0, "bucket emptied");
        uint256 expected = remoteBalanceSD_ > CrosschainConstants.ATTESTATION_ZERO_DUST_SD
            ? (remoteBalanceSD_ < principal_ ? remoteBalanceSD_ : principal_)
            : 0;
        // Band consistency raise only applies while `settledAfter != 0`; here it is zero, so the rule is exact.
        assertEq(state.anchorPrincipal[CHAIN], expected, "anchor = min(reported, pre-debit anchor) or zero at dust");
    }
}

/// @title StargateResidualAnchorReportedBalanceFuzzTest
/// @notice IL-9602 (M12), Stargate transport, end to end: any reported residual in a full recall leaves NAV at the
///         idle only, `settled` at zero and the anchor not above the pre-debit anchor.
contract StargateResidualAnchorReportedBalanceFuzzTest is CrosschainTestBase {
    function setUp() public {
        _baseSetUp();
        _readyDispatcher();
    }

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

    function testFuzz_reportedResidualNeverLeaksIntoNavOrRaisesTheAnchor(uint256 residual_) public {
        residual_ = bound(residual_, 0, 1e30);
        _settle100();
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(105e6, 1);
        uint256 preDebitAnchor = executor.attestationAnchorPrincipal(REMOTE_CHAIN);

        (bytes32 requestId, , ) = _requestAssets(105e6, 0);
        returnStartedRemoteBalanceSD = residual_;
        _deliverReturnStarted(requestId, RGUID, 105e6, 105e6, 2);
        usdc.mint(address(executor), 105e6);
        _deliverReturnCompose(requestId, RGUID, 105e6);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "settled stays zero: residual not credited");
        assertLe(executor.attestationAnchorPrincipal(REMOTE_CHAIN), preDebitAnchor, "anchor <= pre-debit anchor");
        assertEq(executor.getBalance(), 105e6, "NAV is the idle only until the residual is attested");
    }
}

/// @title CcipResidualAnchorReportedBalanceFuzzTest
/// @notice IL-9602 (M12), CCIP transport, end to end: yield realised after the attestation is fuzzed; the full
///         recall reports the residual, which anchors but never enters NAV before it is attested.
contract CcipResidualAnchorReportedBalanceFuzzTest is CcipExecutorFixture {
    using stdStorage for StdStorage;

    function setUp() public {
        _fixtureSetUp();
    }

    function testFuzz_reportedResidualNeverLeaksIntoNavOrRaisesTheAnchor(uint256 yield_) public {
        // The dispatcher must hold the whole recall (105) for the bucket to be emptied: 100 bridged + at least 5 of yield.
        yield_ = bound(yield_, 5e18, 1e27);
        _bridge(100e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(105e18);
        uint256 preDebitAnchor = executor.attestationAnchorPrincipal(REMOTE_CHAIN);
        token.mint(address(dispatcher), yield_);
        stdstore.target(address(dispatcher)).sig("trackedIdle()").checked_write(dispatcher.trackedIdle() + yield_);

        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 105e18, 0, 0, address(0), 500_000);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "settled stays zero: residual not credited");
        assertLe(executor.attestationAnchorPrincipal(REMOTE_CHAIN), preDebitAnchor, "anchor <= pre-debit anchor");
        assertEq(executor.getBalance(), 105e18, "NAV is the idle only until the residual is attested");
    }
}
