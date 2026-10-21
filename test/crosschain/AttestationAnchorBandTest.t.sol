// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {ResolveOutcome, CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipExecutorAttestationLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";
import {CcipChainRescue} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

/// @title StargateAttestationAnchorBandTest
/// @notice Regression cover for IL-7967 (`no_cumulative_bound_on_attested_balance_ratchet`) on the
///         Stargate transport: the per-approval RELATIVE limiter (`BIG_CHANGE_BPS`) bounds one step, not
///         the number of steps, so a compliant proposer/approver pair could previously walk
///         `settledRemoteBalance` to ~304x (up) / ~1/556x (down) of its authenticated baseline inside one
///         freshness window. The fix anchors every approval to `anchorPrincipal`, a per-chain accounting
///         counter credited only by peer-authenticated settlement/return-debit accounting and the
///         timelocked `forceSetSettled` rescue.
///
///         Every test in this contract (except `testFullRecallShouldZeroAnchorAndFallBackToZeroBaselineRule`,
///         labelled below as an invariant pin) fails at `HEAD` (before the fix) and passes with the fix.
contract StargateAttestationAnchorBandTest is CrosschainTestBase {
    // Library event, raised through the executor via delegatecall — the emitting address in the log IS
    // the executor's, but `vm.expectEmit` cannot be used across `PlasmaVault.execute`-style multi-hop
    // calls in general, so this suite uses `vm.recordLogs()` + manual decode consistently.
    bytes32 internal constant ANCHOR_REBASED_TOPIC = keccak256("AttestationAnchorRebased(uint256,uint256)");

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

    function _tryApprove(uint256 settledLD_, uint64 stateVersion_) internal returns (bool ok, bytes memory reason) {
        uint256 pid = _propose(settledLD_, stateVersion_);
        vm.prank(approver);
        try executor.approveBalance(pid) {
            ok = true;
        } catch (bytes memory data) {
            reason = data;
        }
    }

    function _attest(uint256 settledLD_, uint64 stateVersion_) internal {
        uint256 pid = _propose(settledLD_, stateVersion_);
        vm.prank(approver);
        executor.approveBalance(pid);
    }

    /// @dev Second authenticated settlement so the anchor can be raised past 100e6 without touching the
    ///      band-under-test itself. Frontier must already be at `nextVersion_ - 1`.
    function _settleAgain(uint256 amount_, uint64 nextVersion_) internal {
        (bytes32 transferId, bytes32 guid, ) = _sendAsset(amount_, 0);
        _deliverTransferSettled(transferId, guid, amount_, nextVersion_);
    }

    function _lastAnchorRebase() internal returns (bool found, uint256 chainId, uint256 principal) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ANCHOR_REBASED_TOPIC && logs[i].emitter == address(executor)) {
                (chainId, principal) = abi.decode(logs[i].data, (uint256, uint256));
                found = true;
            }
        }
    }

    /// @dev Independent re-derivation of the contract's pro-rata debit (`Math.mulDiv(..., Ceil)`), using
    ///      a different code path (`(x*y + d - 1) / d`), so the test does not merely echo the production
    ///      formula back at itself -- it pins the CEIL rounding direction from a second implementation.
    function _ceilMulDiv(uint256 x_, uint256 y_, uint256 d_) internal pure returns (uint256) {
        return (x_ * y_ + d_ - 1) / d_;
    }

    event AttestationAnchorUpdated(uint256 chainId, uint256 principalSD);

    bytes32 internal constant ANCHOR_UPDATED_TOPIC = keccak256("AttestationAnchorUpdated(uint256,uint256)");

    function _anchorUpdatedCount() internal returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ANCHOR_UPDATED_TOPIC && logs[i].emitter == address(executor)) ++count;
        }
    }

    // ---------------------------------------------------------------------
    // IL-8466: the anchor is observable (getter + AttestationAnchorUpdated on every non-rebase change)
    // ---------------------------------------------------------------------

    function testShouldEmitAnchorUpdatedOnSettleAndRecallAndExposeAnchorGetter() public {
        (bytes32 transferId, bytes32 guid, ) = _sendAsset(100e6, 0);
        vm.expectEmit(address(executor));
        emit AttestationAnchorUpdated(REMOTE_CHAIN, 100e6);
        _deliverTransferSettled(transferId, guid, 100e6, 1);
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 100e6, "settle credited the anchor");

        // An approval moves settled inside the band but never the anchor, and emits no anchor event.
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        vm.recordLogs();
        _attest(105e6, 1);
        assertEq(_anchorUpdatedCount(), 0, "approve emits no AttestationAnchorUpdated");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 100e6, "approve leaves the anchor unchanged");

        // Reviewer PoC: settle 100, approve 105, recall 40 -> anchor 100 - ceil(100 * 40 / 105) = 61_904_761.
        uint256 expected = 100e6 - _ceilMulDiv(100e6, 40e6, 105e6);
        assertEq(expected, 61_904_761, "pro-rata debit value");
        (bytes32 requestId, , ) = _requestAssets(40e6, 0);
        vm.expectEmit(address(executor));
        emit AttestationAnchorUpdated(REMOTE_CHAIN, expected);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), expected, "getter matches the emitted value");
    }

    // ---------------------------------------------------------------------
    // 1. 60-round inflation walk
    // ---------------------------------------------------------------------

    function testSixtyRoundRatchetShouldStopAtAnchorBand() public {
        _settle100(); // settled = principal = 100e6, frontier = 1

        uint256 settled = 100e6;
        uint256 reverts;
        bool firstReasonChecked;
        for (uint256 i; i < 60; ++i) {
            vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
            uint256 next = settled + settled / 10; // +10%
            (bool ok, bytes memory reason) = _tryApprove(next, 1);
            if (ok) {
                settled = next;
            } else {
                ++reverts;
                if (!firstReasonChecked) {
                    firstReasonChecked = true;
                    assertEq(
                        reason,
                        abi.encodeWithSelector(
                            CrosschainErrors.AttestationOutsideAnchorBand.selector,
                            REMOTE_CHAIN,
                            100e6,
                            121e6,
                            2_000
                        ),
                        "first revert is the band, at round 2 (110 -> 121)"
                    );
                }
            }
        }
        assertGt(reverts, 0, "the band must reject some rounds");
        assertLe(executor.settledRemoteBalance(REMOTE_CHAIN), 120e6, "final settled stays within +20% of principal");
        assertEq(settled, 110e6, "only the first round (100 -> 110) was ever accepted");
    }

    // ---------------------------------------------------------------------
    // 2. 60-round deflation walk
    // ---------------------------------------------------------------------

    function testSixtyRoundDeflationShouldStopAtAnchorBand() public {
        _settle100();

        uint256 settled = 100e6;
        uint256 reverts;
        bool firstReasonChecked;
        for (uint256 i; i < 60; ++i) {
            vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
            uint256 next = settled - settled / 10; // -10%
            (bool ok, bytes memory reason) = _tryApprove(next, 1);
            if (ok) {
                settled = next;
            } else {
                ++reverts;
                if (!firstReasonChecked) {
                    firstReasonChecked = true;
                    // Round 1: 100 -> 90 (|10| <= 20, passes). Round 2: 90 -> 81 (|19| <= 20, passes).
                    // Round 3: 81 -> 72.9e6 (|27.1| > 20, reverts).
                    assertEq(
                        reason,
                        abi.encodeWithSelector(
                            CrosschainErrors.AttestationOutsideAnchorBand.selector,
                            REMOTE_CHAIN,
                            100e6,
                            72_900_000,
                            2_000
                        ),
                        "first revert is the band, at round 3 (81 -> 72.9e6)"
                    );
                }
            }
        }
        assertGt(reverts, 0, "the band must reject some rounds");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 81e6, "settled parked at the last accepted step");
        assertGe(executor.settledRemoteBalance(REMOTE_CHAIN), 80e6, "final settled stays within -20% of principal");
    }

    // ---------------------------------------------------------------------
    // 3. Boundary is exact
    // ---------------------------------------------------------------------

    function testShouldAcceptYieldDriftExactlyAtBandBoundary() public {
        _settle100();

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(110e6, 1);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(120e6, 1); // == cap, passes
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e6);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(120e6 + 1, 1);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                100e6,
                120e6 + 1,
                2_000
            )
        );
        executor.approveBalance(pid);
    }

    // ---------------------------------------------------------------------
    // 4. Authenticated settlement raises the anchor
    // ---------------------------------------------------------------------

    function testAuthenticatedSettlementShouldRaiseAnchor() public {
        _settle100(); // principal = settled = 100e6, frontier = 1
        _settleAgain(100e6, 2); // principal = settled = 200e6, frontier = 2

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(220e6, 2); // relative 10% ok, band 10% (<=20%) ok

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(240e6, 2); // relative from 220 is ~9.1% ok; band |40| == 200*0.2 == 40, boundary passes
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 240e6);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(240e6 + 1, 2);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                200e6,
                240e6 + 1,
                2_000
            )
        );
        executor.approveBalance(pid);
    }

    // ---------------------------------------------------------------------
    // 5. Partial recall preserves band headroom (pro-rata debit)
    // ---------------------------------------------------------------------

    function testPartialRecallShouldPreserveBandHeadroom() public {
        _settle100(); // principal = settled = 100e6, frontier = 1

        // Reaching 115e6 from a 100e6 principal in ONE step would itself trip the pre-existing 10%
        // relative limiter (unrelated to this fix); two ordinary steps stay inside it.
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(110e6, 1);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(115e6, 1); // principal stays 100e6, settled = 115e6

        (bytes32 requestId, , ) = _requestAssets(50e6, 0); // maxAccountedSD = min(50, 115) = 50
        _deliverReturnStarted(requestId, RGUID, 50e6, 50e6, 2);
        // accountedDebitSD = min(50, min(50, 115)) = 50e6 -> settled = 65e6
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 65e6, "settled debited by the accounted amount");

        // Independently re-derive `anchorPrincipal` after the pro-rata debit: `Math.mulDiv(100e6, 50e6,
        // 115e6, Ceil)` rounds UP at full SD precision (43_478_261, not the naively-rounded "44" a
        // human-scale approximation would suggest) — pin the exact value via a second implementation.
        uint256 principal = 100e6 - _ceilMulDiv(100e6, 50e6, 115e6);
        assertEq(principal, 56_521_739, "pro-rata debit rounds UP at full precision, not to the nearest unit");
        uint256 cap = principal + (principal * 2_000) / 10_000; // floor, matches the on-chain boundary

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(cap, 2); // exactly at the cap: passes
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), cap);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(cap + 1, 2);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                principal,
                cap + 1,
                2_000
            )
        );
        executor.approveBalance(pid);
    }

    // ---------------------------------------------------------------------
    // 6. Full recall zeroes the anchor together with settled — INVARIANT PIN, passes at HEAD too
    // ---------------------------------------------------------------------

    /// @notice INVARIANT PIN (not a regression test — this passes at `HEAD` too; the plan §2.8 labels it
    ///         as such explicitly). A full recall (accountedDebitSD == settledBefore) always reduces
    ///         `anchorPrincipal` to exactly zero in lockstep with `settledRemoteBalance`, because the
    ///         pro-rata ratio is exactly 1 in that case (no rounding residue): the zero-baseline
    ///         `UnanchoredAttestation` rule (R-04) is what governs re-anchoring afterwards, unchanged.
    function testFullRecallShouldZeroAnchorAndFallBackToZeroBaselineRule() public {
        _settle100(); // principal = settled = 100e6, frontier = 1

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(110e6, 1); // principal = 100e6, settled = 110e6

        (bytes32 requestId, , ) = _requestAssets(110e6, 0); // maxAccountedSD = min(110, 110) = 110
        _deliverReturnStarted(requestId, RGUID, 110e6, 110e6, 2);
        // accountedDebitSD = min(110, min(110, 110)) = 110 -> settled = 0
        // principalDebit = ceil(100 * 110 / 110) = 100 -> principal = 0
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "settled fully drained");

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(50e6, 2);
        vm.prank(approver);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnanchoredAttestation.selector, REMOTE_CHAIN, 50e6));
        executor.approveBalance(pid);
    }

    // ---------------------------------------------------------------------
    // 7. forceSetSettled rebases the anchor
    // ---------------------------------------------------------------------

    /// @dev `BIG_CHANGE_BPS` is 10% on this fixture, so reaching 300e6 from a 250e6 rebase in one step
    ///      would itself trip `BigChangeExceeded` (a 20% relative move) before the band is even reached —
    ///      that guard is untouched by this fix and must keep firing. Two ordinary approvals (250 -> 275
    ///      -> 300) reach the band boundary within the existing relative limiter; only the THIRD step
    ///      (300 -> 300e6+1) is a band-only revert, which is what this test is regression cover for.
    function testForceSetSettledShouldRebaseAnchor() public {
        vm.recordLogs();
        uint64 observedVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceSetSettledBalance(
            REMOTE_CHAIN, 250e6, observedVersion, _markFsObs(), false
        );
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(rescueId, REMOTE_CHAIN, 250e6, observedVersion, fsObs, false);

        (bool found, uint256 chainId, uint256 principal) = _lastAnchorRebase();
        assertTrue(found, "AttestationAnchorRebased was emitted");
        assertEq(chainId, REMOTE_CHAIN);
        assertEq(principal, 250e6);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 250e6);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(275e6, executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN)); // relative 10% ok, band 10% ok

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(300e6, executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN)); // relative ~9.1% ok, band == cap
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 300e6);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(300e6 + 1, executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN));
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                250e6,
                300e6 + 1,
                2_000
            )
        );
        executor.approveBalance(pid);
    }

    // ---------------------------------------------------------------------
    // Stargate-only: force-resolve outbound credit raises the anchor
    // ---------------------------------------------------------------------

    /// @notice A stuck outbound transfer, force-resolved with `ResolveOutcome.DELIVERED_TO_SETTLED`,
    ///         raises BOTH `settledRemoteBalance` and `anchorPrincipal` by the recorded outbound amount —
    ///         the rescue admin has confirmed, under timelock, that the value reached the remote chain.
    ///         Mirrors the CCIP `testForceResolveOutboundCreditShouldRaiseAnchor` coverage: the anchor
    ///         credit at `StargateExecutorAccountingLib.sol` force-resolve `DELIVERED_TO_SETTLED`
    ///         (`applyForceResolve`) has no other test that dies if it is re-injected without the fix.
    function testForceResolveOutboundCreditShouldRaiseAnchor() public {
        (bytes32 transferId, , ) = _sendAsset(100e6, 0); // stuck: never settled by an authenticated receipt

        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(transferId, ResolveOutcome.DELIVERED_TO_SETTLED);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectEmit(address(executor));
        emit AttestationAnchorUpdated(REMOTE_CHAIN, 100e6);
        executor.executeForceResolveTransfer(rescueId, transferId, ResolveOutcome.DELIVERED_TO_SETTLED);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "force-resolve credited settled");

        // Two ordinary steps (100 -> 110 -> 120) stay inside the pre-existing 10% relative limiter; a
        // single 100 -> 120 step would itself trip `BigChangeExceeded` before the band is even reached.
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(110e6, executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN));
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(120e6, executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN)); // == cap (principal 100e6), passes
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e6);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(120e6 + 1, executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN));
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                100e6,
                120e6 + 1,
                2_000
            )
        );
        executor.approveBalance(pid);
    }

    // ---------------------------------------------------------------------
    // IL-7967: dust-anchor no-op refresh must not freeze the chain (residue 1)
    // ---------------------------------------------------------------------

    /// @notice Regression cover for cycle-1's dust-freeze defect: a near-full recall that leaves exactly
    ///         1 SD unit of `settled` also drives the Ceil-rounded pro-rata debit to zero the anchor. An
    ///         un-clamped zero anchor makes the no-op refresh of the surviving dust value revert
    ///         `AttestationOutsideAnchorBand(chainId, 0, 1, 2000)`, which permanently blocks `approve` on
    ///         that chain (no `approve` can ever pass `newSettled == 0` and `newSettled == 1`
    ///         simultaneously) and drives the chain to `NavSettledStale` within `STALENESS_MAX` — a
    ///         whole-vault freeze reachable by an ORDINARY full recall whose returned amount falls even 1
    ///         unit short of the attested balance, no attacker required. Residue 1 is the smallest member
    ///         of the class; the band-consistency clamp that closes the whole class (see
    ///         `testNearFullRecallLeavingResidueTwoShouldStayApprovable`) subsumes cycle 2's floor-at-1
    ///         here: it re-anchors on 1, so the dust refresh passes and freshness stays alive.
    function testNoOpRefreshAtDustAnchorShouldSucceed() public {
        _settle100(); // principal = settled = 100e6, frontier = 1

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(110e6, 1); // principal = 100e6, settled = 110e6

        (bytes32 requestId, , ) = _requestAssets(110e6, 0); // maxAccountedSD = min(110, 110) = 110
        _deliverReturnStarted(requestId, RGUID, 110e6 - 1, 110e6 - 1, 2);
        // accountedDebitSD = min(110e6 - 1, 110e6) = 110e6 - 1 -> settled = 1
        // principalDebit = ceil(100e6 * (110e6 - 1) / 110e6) = 100e6 -> pro-rata remainder 0, which is
        // outside the band against settled = 1, so the clamp re-anchors on the residue (1).
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 1, "settled left at dust after near-full recall");

        // The no-op refresh of the surviving dust value must succeed, not revert
        // AttestationOutsideAnchorBand(REMOTE_CHAIN, 0, 1, 2000).
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(1, 2);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 1, "dust refresh succeeded and left settled unchanged");
    }

    // ---------------------------------------------------------------------
    // IL-8499 (IL-8424 #6): rounding dust left by a full recall is attestable down to exactly zero
    // ---------------------------------------------------------------------

    /// @dev Settle 100e6, then fully recall it with a sent amount `dust_` short of the settled value (the
    ///      remote ERC-4626 redeem rounding), delivering the tokens too. Leaves settled == `dust_`,
    ///      frontier == 2.
    function _fullRecallLeavingDust(uint256 dust_) internal {
        _settle100();
        (bytes32 requestId, , ) = _requestAssets(100e6, 0);
        uint256 sent = 100e6 - dust_;
        _deliverReturnStarted(requestId, RGUID, sent, sent, 2);
        usdc.mint(address(executor), sent);
        _deliverReturnCompose(requestId, RGUID, sent);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), dust_, "recall left the dust behind");
    }

    function testShouldAttestRecallDustToZeroAndKeepNavLive() public {
        _fullRecallLeavingDust(13);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(0, 2);
        vm.expectEmit(address(executor));
        emit AttestationAnchorUpdated(REMOTE_CHAIN, 0);
        vm.prank(approver);
        executor.approveBalance(pid);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "dust attested to zero");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 0, "anchor reset to zero");

        // A zero bucket never goes stale, so NAV stays live long after the staleness window.
        vm.warp(block.timestamp + STALENESS_MAX + 8 days);
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 0, "zero bucket does not fail closed");
        executor.getBalance();
    }

    function testShouldAttestZeroFromExactlyDustBoundButNotAbove() public {
        uint256 bound = CrosschainConstants.ATTESTATION_ZERO_DUST_SD;

        _fullRecallLeavingDust(bound);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(0, 2);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "exactly the bound is accepted");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 0, "anchor reset");
    }

    function testShouldRejectZeroAttestationAboveDustBound() public {
        uint256 bound = CrosschainConstants.ATTESTATION_ZERO_DUST_SD;

        _fullRecallLeavingDust(bound + 1);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(0, 2);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.BigChangeExceeded.selector, bound + 1, 0, BIG_CHANGE_BPS)
        );
        vm.prank(approver);
        executor.approveBalance(pid);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), bound + 1, "bucket untouched");
    }

    function testShouldStillApplyRelativeRuleToNonZeroTargetBelowDustBound() public {
        _fullRecallLeavingDust(13);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(5, 2);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.BigChangeExceeded.selector, 13, 5, BIG_CHANGE_BPS));
        vm.prank(approver);
        executor.approveBalance(pid);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 13, "only exactly-zero is special");
    }

    // ---------------------------------------------------------------------
    // IL-7967 cycle-3 correction 1: a residue of 2 must stay approvable too
    // ---------------------------------------------------------------------

    /// @notice Regression cover for cycle-2's residue-2 freeze. A near-full recall that comes back 2 SD
    ///         units short leaves `settled == 2`, while the Ceil-rounded pro-rata debit leaves the
    ///         cycle-2 `anchorPrincipal` at 1. That pair sits OUTSIDE the band `approve` enforces, and the
    ///         two admissible windows are then disjoint -- the band admits only `{1}`, the relative check
    ///         admits only `{2}` -- so NO value can be approved at all: the freshness marker can never be
    ///         refreshed again and the chain reaches `NavSettledStale` within `STALENESS_MAX`. That is a
    ///         whole-vault deposit/redeem halt over ~1e-5 USDC of residue, reachable by one ordinary
    ///         MANAGER recall, with no attester collusion. Cycle 2's floor-at-1 moved the boundary by one
    ///         unit instead of closing the class (the frozen end states were `(1,2) (2,3) (3,4) (4,5)
    ///         (5,7) (6,8) (7,9)`). The band-consistency clamp re-anchors on the residue instead, so the
    ///         post-debit pair satisfies the same predicate `approve` enforces and the refresh passes.
    function testNearFullRecallLeavingResidueTwoShouldStayApprovable() public {
        _settle100(); // principal = settled = 100e6, frontier = 1

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(110e6, 1); // principal = 100e6, settled = 110e6

        (bytes32 requestId, , ) = _requestAssets(110e6, 0); // maxAccountedSD = min(110e6, 110e6) = 110e6
        _deliverReturnStarted(requestId, RGUID, 110e6 - 2, 110e6 - 2, 2);
        // accountedDebitSD = min(110e6 - 2, 110e6) = 110e6 - 2 -> settled = 2
        // principalDebit = ceil(100e6 * (110e6 - 2) / 110e6) = 100e6 - 1 -> pro-rata remainder = 1, which
        // is outside the band against settled = 2, so the clamp re-anchors on the residue (2).
        assertEq(
            100e6 - _ceilMulDiv(100e6, 110e6 - 2, 110e6),
            1,
            "pro-rata remainder is 1, the cycle-2 value that froze the chain against a residue of 2"
        );
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 2, "settled left at a 2-unit residue");

        // The refresh of the surviving residue must succeed, not revert
        // AttestationOutsideAnchorBand(REMOTE_CHAIN, 1, 2, 2000).
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(2, 2);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 2, "residue refresh succeeded, settled unchanged");
    }

    // ---------------------------------------------------------------------
    // IL-7967 cycle-3: the clamp must NOT be usable to walk the anchor upward
    // ---------------------------------------------------------------------

    /// @notice The band-consistency clamp raises `anchorPrincipal` relative to the pro-rata value, so it
    ///         has to be pinned that it raises it to the SMALLEST band-restoring value and never above the
    ///         pre-debit principal. Re-anchoring on `settledAfter` instead (the shape first proposed in
    ///         cycle-2 verification) adopts an ATTESTED figure as the new principal, which reopens exactly
    ///         the ratchet IL-7967 closes: from the top of the band, a 1-unit recall would carry the anchor
    ///         to ~1.2x, and the loop compounds (modelled in `audit/IL-7942/IL-7967/anchor_band_sweep.py`:
    ///         anchor 1e6 -> 1.5e12 in 200 one-unit recalls, all of which return to the vault).
    ///         Here: principal 100e6, settled attested to the band top (120e6), one 1-unit recall. The
    ///         anchor must still be exactly 100e6 -- observed through the `principal` argument of the band
    ///         revert, since Stargate has no anchor getter (26 B of EIP-170 margin).
    function testBandEdgeRecallMustNotRaiseTheAnchor() public {
        _settle100(); // principal = settled = 100e6, frontier = 1

        // Two ordinary 10% steps to the top of the band; one step would trip the relative limiter.
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(110e6, 1);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(120e6, 1); // principal 100e6, settled 120e6 -- exactly at the +20% cap

        (bytes32 requestId, , ) = _requestAssets(1, 0);
        _deliverReturnStarted(requestId, RGUID, 1, 1, 2);
        // principalDebit = ceil(100e6 * 1 / 120e6) = 1 -> pro-rata remainder 99_999_999 against
        // settledAfter 119_999_999, which is outside the band; the clamp restores it to exactly 100e6.
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e6 - 1, "settled debited by the 1-unit return");

        // The anchor is unchanged at 100e6, so the cap is still 120e6: at the cap the approval passes.
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(120e6, 2);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e6);

        // One unit above the cap reverts, and the revert's `principal` argument pins the anchor at 100e6 --
        // not 99_999_999 (the un-clamped pro-rata value) and not 119_999_999 (the re-anchor-on-residue
        // shape, which would have raised the cap to 143_999_998).
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(120e6 + 1, 2);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                100e6,
                120e6 + 1,
                2_000
            )
        );
        executor.approveBalance(pid);
    }
}

/// @title CcipAttestationAnchorBandTest
/// @notice CCIP mirror of `StargateAttestationAnchorBandTest` (IL-7967). This harness's
///         `bigChangeBps = 2_000` (20%) sits exactly at the constructor ceiling `ATTESTATION_ANCHOR_BAND_BPS`
///         (IL-8058), so a single step from the anchor to either band edge is admitted by both limits (each
///         reverts on a strict `>`, so exactly 20% passes). For a step that starts at the anchor the two
///         thresholds coincide and the relative limiter, checked first, is the one that reverts — the band
///         never fires on a from-anchor step here; the band binds on its own only for a step that starts
///         away from the anchor. The relative limiter still binds on its own for a move between two points
///         inside the band that is wider than 20% of the previous approved value (e.g. 0.8P -> 1.2P).
contract CcipAttestationAnchorBandTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;
    uint256 internal constant MIN_UPDATE_INTERVAL = 1 hours;

    bytes32 internal constant ANCHOR_REBASED_TOPIC = keccak256("AttestationAnchorRebased(uint256,uint256)");
    bytes32 internal constant RGUID = keccak256("ccip-anchor-band-return");

    MockCcipRouter internal router;
    AnchorBandToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new AnchorBandToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            18,
            _safety()
        );
        CcipRouteConfig memory back = CcipRouteConfig({
            chainSelector: EXECUTOR_SELECTOR,
            peer: address(executor),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            18,
            block.chainid,
            back,
            RESCUE_ADMIN,
            address(0xB22),
            RESCUE_DELAY
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
    }

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: RESCUE_ADMIN,
                rescueGuardian: address(0xB22),
                balanceProposer: address(this),
                balanceApprover: APPROVER,
                rescueDelay: RESCUE_DELAY,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000, // == ATTESTATION_ANCHOR_BAND_BPS, the constructor ceiling (IL-8058)
                minUpdateInterval: MIN_UPDATE_INTERVAL,
                transferStalenessMax: 1 days
            });
    }

    function _propose(uint256 balance_) internal returns (uint256 proposalId) {
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
        proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            balance_,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            uint64(block.number == 0 ? 1 : block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
    }

    function _tryApprove(uint256 balance_) internal returns (bool ok, bytes memory reason) {
        uint256 proposalId = _propose(balance_);
        vm.prank(APPROVER);
        try executor.approveBalance(proposalId) {
            ok = true;
        } catch (bytes memory data) {
            reason = data;
        }
    }

    function _attest(uint256 balance_) internal {
        uint256 proposalId = _propose(balance_);
        vm.prank(APPROVER);
        executor.approveBalance(proposalId);
    }

    /// @dev Bridge and settle `amount_`, which credits `settledRemoteBalance` (and now `anchorPrincipal`)
    ///      through an AUTHENTICATED TRANSFER_SETTLED.
    function _bridge(uint256 amount_) internal {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 500_000);
    }

    function _forceSetSettled(uint256 newSettledLD_) internal {
        // Observed at the current frontier, as `FORCE_SET_SETTLED` requires (IL-8294).
        uint256 arg = (uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) << 192) |
            (block.timestamp << 128) | newSettledLD_;
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
    }

    function _lastAnchorRebase() internal returns (bool found, uint256 chainId, uint256 principal) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ANCHOR_REBASED_TOPIC && logs[i].emitter == address(executor)) {
                (chainId, principal) = abi.decode(logs[i].data, (uint256, uint256));
                found = true;
            }
        }
    }

    /// @dev Independent re-derivation of the contract's pro-rata debit (`Math.mulDiv(..., Ceil)`), using
    ///      a different code path (`(x*y + d - 1) / d`), so the test does not merely echo the production
    ///      formula back at itself -- it pins the CEIL rounding direction from a second implementation.
    function _ceilMulDiv(uint256 x_, uint256 y_, uint256 d_) internal pure returns (uint256) {
        return (x_ * y_ + d_ - 1) / d_;
    }

    event AttestationAnchorUpdated(uint256 chainId, uint256 principalSD);

    bytes32 internal constant ANCHOR_UPDATED_TOPIC = keccak256("AttestationAnchorUpdated(uint256,uint256)");

    function _lastAnchorUpdated() internal returns (uint256 principal) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ANCHOR_UPDATED_TOPIC && logs[i].emitter == address(executor)) {
                (, principal) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }

    function _anchorUpdatedCount() internal returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ANCHOR_UPDATED_TOPIC && logs[i].emitter == address(executor)) ++count;
        }
    }

    // ---------------------------------------------------------------------
    // IL-8466: AttestationAnchorUpdated on every non-rebase change of the anchor
    // ---------------------------------------------------------------------

    function testShouldEmitAnchorUpdatedOnSettleAndRecallAndMatchAnchorGetter() public {
        vm.recordLogs();
        _bridge(100e18);
        assertEq(_lastAnchorUpdated(), 100e18, "settle emitted the new anchor");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 100e18, "settle credited the anchor");

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        vm.recordLogs();
        _attest(105e18);
        assertEq(_anchorUpdatedCount(), 0, "approve emits no AttestationAnchorUpdated");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 100e18, "approve leaves the anchor unchanged");

        uint256 expected = 100e18 - _ceilMulDiv(100e18, 40e18, 105e18);
        vm.expectEmit(address(executor));
        emit AttestationAnchorUpdated(REMOTE_CHAIN, expected);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 40e18, 40e18, 0, address(0), 500_000);
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), expected, "getter matches the emitted value");
    }

    // ---------------------------------------------------------------------
    // 1. 60-round inflation walk
    // ---------------------------------------------------------------------

    function testSixtyRoundRatchetShouldStopAtAnchorBand() public {
        _bridge(100e18);

        uint256 settled = 100e18;
        uint256 reverts;
        bool firstReasonChecked;
        for (uint256 i; i < 60; ++i) {
            vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
            uint256 next = settled + settled / 10;
            (bool ok, bytes memory reason) = _tryApprove(next);
            if (ok) {
                settled = next;
            } else {
                ++reverts;
                if (!firstReasonChecked) {
                    firstReasonChecked = true;
                    assertEq(
                        reason,
                        abi.encodeWithSelector(
                            CcipExecutorAttestationLib.AttestationOutsideAnchorBand.selector,
                            REMOTE_CHAIN,
                            100e18,
                            121e18,
                            2_000
                        ),
                        "first revert is the band, at round 2 (110 -> 121)"
                    );
                }
            }
        }
        assertGt(reverts, 0);
        assertLe(executor.settledRemoteBalance(REMOTE_CHAIN), 120e18);
        assertEq(settled, 110e18);
    }

    // ---------------------------------------------------------------------
    // 2. 60-round deflation walk
    // ---------------------------------------------------------------------

    function testSixtyRoundDeflationShouldStopAtAnchorBand() public {
        _bridge(100e18);

        uint256 settled = 100e18;
        uint256 reverts;
        bool firstReasonChecked;
        for (uint256 i; i < 60; ++i) {
            vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
            uint256 next = settled - settled / 10;
            (bool ok, bytes memory reason) = _tryApprove(next);
            if (ok) {
                settled = next;
            } else {
                ++reverts;
                if (!firstReasonChecked) {
                    firstReasonChecked = true;
                    assertEq(
                        reason,
                        abi.encodeWithSelector(
                            CcipExecutorAttestationLib.AttestationOutsideAnchorBand.selector,
                            REMOTE_CHAIN,
                            100e18,
                            72_900_000_000_000_000_000,
                            2_000
                        ),
                        "first revert is the band, at round 3 (81 -> 72.9e18)"
                    );
                }
            }
        }
        assertGt(reverts, 0);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 81e18);
        assertGe(executor.settledRemoteBalance(REMOTE_CHAIN), 80e18);
    }

    // ---------------------------------------------------------------------
    // 3. Boundary is exact
    // ---------------------------------------------------------------------

    function testShouldAcceptYieldDriftExactlyAtBandBoundary() public {
        _bridge(100e18);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(110e18);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(120e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e18);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 proposalId = _propose(120e18 + 1);
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                100e18,
                120e18 + 1,
                2_000
            )
        );
        executor.approveBalance(proposalId);
    }

    // ---------------------------------------------------------------------
    // 4. Authenticated settlement raises the anchor
    // ---------------------------------------------------------------------

    function testAuthenticatedSettlementShouldRaiseAnchor() public {
        _bridge(100e18);
        _bridge(100e18); // principal = settled = 200e18

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(220e18);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(240e18); // band |40| == 200*0.2 == 40, boundary passes
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 240e18);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 proposalId = _propose(240e18 + 1);
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                200e18,
                240e18 + 1,
                2_000
            )
        );
        executor.approveBalance(proposalId);
    }

    // ---------------------------------------------------------------------
    // 5. Partial recall preserves band headroom (pro-rata debit), via requestAssetsFromDispatcher
    // ---------------------------------------------------------------------

    function testPartialRecallShouldPreserveBandHeadroom() public {
        _bridge(100e18); // principal = settled = 100e18

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(115e18); // principal stays 100e18, settled = 115e18

        // The mock router finalizes RETURN_REQUEST/RETURN_TRANSFER synchronously.
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 50e18, 50e18, 0, address(0), 500_000);
        // accountedDebitSD = min(50, min(50, 115)) = 50e18 -> settled = 65e18
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 65e18, "settled debited by the received amount");

        // Independently re-derive `anchorPrincipal` after the pro-rata debit at full 18-decimal precision
        // (a second implementation of the CEIL rounding, not a copy of the production formula).
        uint256 principal = 100e18 - _ceilMulDiv(100e18, 50e18, 115e18);
        assertEq(principal, 56_521_739_130_434_782_608, "pro-rata debit rounds UP at full precision");
        uint256 cap = principal + (principal * 2_000) / 10_000;

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(cap);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), cap);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 proposalId = _propose(cap + 1);
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                principal,
                cap + 1,
                2_000
            )
        );
        executor.approveBalance(proposalId);
    }

    // ---------------------------------------------------------------------
    // 7. forceSetSettled rebases the anchor
    // ---------------------------------------------------------------------

    function testForceSetSettledShouldRebaseAnchor() public {
        vm.recordLogs();
        _forceSetSettled(250e18);

        (bool found, uint256 chainId, uint256 principal) = _lastAnchorRebase();
        assertTrue(found, "AttestationAnchorRebased was emitted");
        assertEq(chainId, REMOTE_CHAIN);
        assertEq(principal, 250e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 250e18);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(300e18); // relative 20% == the 2_000 limit, admitted by the strict '>'; band == cap, also admitted
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 300e18);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 proposalId = _propose(300e18 + 1);
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                250e18,
                300e18 + 1,
                2_000
            )
        );
        executor.approveBalance(proposalId);
    }

    // ---------------------------------------------------------------------
    // CCIP-only: force-resolve outbound credit raises the anchor
    // ---------------------------------------------------------------------

    /// @notice A stuck outbound transfer, force-resolved with `creditToSettled = true`, raises BOTH
    ///         `settledRemoteBalance` and `anchorPrincipal` by the recorded outbound amount — the rescue
    ///         admin has confirmed, under timelock, that the value reached the remote chain.
    function testForceResolveOutboundCreditShouldRaiseAnchor() public {
        router.setAutoDeliver(false); // the OUTBOUND_TRANSFER message never reaches the dispatcher
        token.mint(address(executor), 100e18);
        vm.recordLogs();
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 500_000);
        bytes32 operationId = _captureOperationId();
        router.setAutoDeliver(true);

        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleForceResolveOutbound(operationId, true);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        vm.expectEmit(address(executor));
        emit AttestationAnchorUpdated(REMOTE_CHAIN, 100e18);
        executor.executeForceResolveOutbound(rescueId, operationId, true);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18, "force-resolve credited settled");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 100e18, "force-resolve credited the anchor too");

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(120e18); // == cap, passes
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e18);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 proposalId = _propose(120e18 + 1);
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                100e18,
                120e18 + 1,
                2_000
            )
        );
        executor.approveBalance(proposalId);
    }

    // ---------------------------------------------------------------------
    // CCIP-only: the LATE-credit path also raises the anchor
    // ---------------------------------------------------------------------

    /// @notice A transfer force-resolved with `creditToSettled = false` (dropped from NAV) still owes its
    ///         remote credit if a late `TRANSFER_SETTLED` receipt eventually arrives —
    ///         `CcipExecutorTransferLib._applyLateCredit`. That credit must raise `anchorPrincipal` too,
    ///         same as the fresh-settle path; this test has no fresh-settle/force-resolve-credit overlap,
    ///         so it is the only coverage that dies if `_applyLateCredit`'s anchor write is re-injected.
    function testLateCreditShouldRaiseAnchor() public {
        router.setAutoDeliver(false); // the OUTBOUND_TRANSFER message never reaches the dispatcher
        token.mint(address(executor), 100e18);
        vm.recordLogs();
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 500_000);
        bytes32 operationId = _captureOperationId();
        router.setAutoDeliver(true);

        // Drop from NAV now (no credit yet) — the transfer is force-resolved but still owes its remote
        // credit if a late receipt shows up.
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleForceResolveOutbound(operationId, false);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeForceResolveOutbound(rescueId, operationId, false);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "dropped, not yet credited");

        // The late TRANSFER_SETTLED receipt now lands and hits `_applyLateCredit`.
        vm.prank(address(router));
        executor.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256("late-settle"),
                sourceChainSelector: DISPATCHER_SELECTOR,
                sender: abi.encode(address(dispatcher)),
                data: CcipMessages.encode(CcipMsgType.TRANSFER_SETTLED, abi.encode(operationId, 100e18, 100e18, 1)),
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18, "late credit applied");

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(120e18); // == cap (principal 100e18), passes
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e18);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 proposalId = _propose(120e18 + 1);
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                100e18,
                120e18 + 1,
                2_000
            )
        );
        executor.approveBalance(proposalId);
    }

    bytes32 internal constant ASSET_SENT_TOPIC = keccak256("AssetSent(uint256,bytes32,bytes32,uint256)");

    function _captureOperationId() internal returns (bytes32 operationId) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ASSET_SENT_TOPIC) {
                (, operationId, , ) = abi.decode(logs[i].data, (uint256, bytes32, bytes32, uint256));
                return operationId;
            }
        }
        revert("AssetSent not emitted");
    }

    // ---------------------------------------------------------------------
    // IL-7967: dust-anchor no-op refresh must not freeze the chain (residue 1)
    // ---------------------------------------------------------------------

    /// @notice CCIP mirror of the Stargate dust-freeze regression, adapted to this harness's REAL token
    ///         custody: unlike Stargate's raw mock (which lets a test dictate `amountSentSD` directly),
    ///         the CCIP dispatcher's `trackedIdle` physically caps every recall, and `trackedIdle` only
    ///         ever moves in lockstep with `settledRemoteBalance` (both are adjusted by the identical
    ///         `amount` on every bridge and every recall) — so `settledRemoteBalance - trackedIdle` is an
    ///         INVARIANT set once, by the one operation that changes `settled` without moving any token:
    ///         `approve`. Attesting `principal + 1` (instead of the Stargate mirror's +10%) sets that gap
    ///         to exactly 1 SD unit, so draining the dispatcher's entire real `trackedIdle` (100e18) in one
    ///         recall leaves `settled == 1` — the same dust corner, reached through a real, fully-backed
    ///         round trip. The Ceil-rounded pro-rata debit then computes `principalDebit == principal`
    ///         (verified: `ceil(100e18 * 100e18 / (100e18 + 1)) == 100e18` exactly), which would zero the
    ///         anchor. A zero anchor is outside the band against a settled of 1, so the band-consistency
    ///         clamp re-anchors on the residue and leaves `anchorPrincipal == 1`. Un-clamped, the no-op
    ///         refresh of the surviving dust value reverts `AttestationOutsideAnchorBand(chainId, 0, 1,
    ///         2000)`, permanently blocking `approve` on that chain. Residue 1 is the smallest member of
    ///         the class; `testNearFullRecallLeavingResidueTwoShouldStayApprovable` covers the rest.
    function testNoOpRefreshAtDustAnchorShouldSucceed() public {
        _bridge(100e18); // principal = settled = trackedIdle = 100e18

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(100e18 + 1); // principal stays 100e18, settled = 100e18 + 1, trackedIdle stays 100e18

        // Drain the dispatcher's entire real trackedIdle (100e18) in one recall; the return is capped at
        // trackedIdle regardless of the requested amount, so `minReturn_ = 0` accepts whatever comes back.
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 100e18, 0, 0, address(0), 500_000);
        // accountedDebitSD = min(received = 100e18, maxAccounted = min(100e18, 100e18 + 1)) = 100e18
        // settled = (100e18 + 1) - 100e18 = 1
        // principalDebit = ceil(100e18 * 100e18 / (100e18 + 1)) = 100e18 -> pro-rata remainder 0, which is
        // outside the band against settled = 1, so the clamp re-anchors on the residue (1).
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 1, "settled left at dust after near-full recall");

        // The no-op refresh of the surviving dust value must succeed, not revert
        // AttestationOutsideAnchorBand(REMOTE_CHAIN, 0, 1, 2000).
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(1);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 1, "dust refresh succeeded and left settled unchanged");
    }

    // ---------------------------------------------------------------------
    // IL-7967 cycle-3 correction 1: a residue of 2 must stay approvable too
    // ---------------------------------------------------------------------

    /// @notice CCIP mirror of the Stargate residue-2 regression, using the same real-custody construction
    ///         cycle 2 established for this harness: `settledRemoteBalance - trackedIdle` is an invariant
    ///         that only `approve` moves (every bridge and every recall moves both by the identical
    ///         amount), so attesting `principal + 2` sets that gap to exactly 2 units and draining the
    ///         dispatcher's entire real `trackedIdle` in one recall reaches `settled == 2` through a
    ///         fully-backed round trip -- the literal Stargate numbers would instead be rejected
    ///         `ReturnRejected(BELOW_MINIMUM)` for exceeding the physical `trackedIdle`. The Ceil-rounded
    ///         pro-rata debit then leaves the cycle-2 anchor at 1 against a settled of 2, a pair whose band
    ///         window `{1}` and relative window `{2}` are disjoint: no value is approvable, the freshness
    ///         marker freezes and the vault halts on `ObservationStale`. The band-consistency clamp
    ///         re-anchors on the residue, so the refresh passes.
    function testNearFullRecallLeavingResidueTwoShouldStayApprovable() public {
        _bridge(100e18); // principal = settled = trackedIdle = 100e18

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(100e18 + 2); // principal stays 100e18, settled = 100e18 + 2, trackedIdle stays 100e18

        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 100e18, 0, 0, address(0), 500_000);
        // debit = min(received = 100e18, settled = 100e18 + 2) = 100e18 -> settled = 2
        // principalDebit = ceil(100e18 * 100e18 / (100e18 + 2)) = 100e18 - 1 -> pro-rata remainder = 1
        assertEq(
            100e18 - _ceilMulDiv(100e18, 100e18, 100e18 + 2),
            1,
            "pro-rata remainder is 1, the cycle-2 value that froze the chain against a residue of 2"
        );
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 2, "settled left at a 2-unit residue");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 2, "anchor re-anchored on the residue");

        // The refresh of the surviving residue must succeed, not revert
        // AttestationOutsideAnchorBand(REMOTE_CHAIN, 1, 2, 2000).
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(2);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 2, "residue refresh succeeded, settled unchanged");
    }

    // ---------------------------------------------------------------------
    // IL-7967 cycle-3: the clamp must NOT be usable to walk the anchor upward
    // ---------------------------------------------------------------------

    /// @notice CCIP mirror of the anti-ratchet pin. The band-consistency clamp raises `anchorPrincipal`
    ///         relative to the pro-rata value, so it must be pinned that it raises it to the SMALLEST
    ///         band-restoring value and never above the pre-debit principal. Re-anchoring on `settledAfter`
    ///         instead would adopt an ATTESTED figure as the new principal and reopen the ratchet this
    ///         ticket closes (modelled in `audit/IL-7942/IL-7967/anchor_band_sweep.py`: anchor 1e6 -> 1.5e12
    ///         in 200 one-unit recalls, every one of which returns its unit to the vault). Here the anchor
    ///         is read directly from `attestationAnchorPrincipal`, which this transport exposes.
    function testBandEdgeRecallMustNotRaiseTheAnchor() public {
        _bridge(100e18); // principal = settled = trackedIdle = 100e18

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(120e18); // exactly at the +20% cap; bigChangeBps is 2_000 here, so one step suffices

        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 1, 1, 0, address(0), 500_000);
        // principalDebit = ceil(100e18 * 1 / 120e18) = 1 -> pro-rata remainder 100e18 - 1 against
        // settledAfter 120e18 - 1, which is outside the band; the clamp restores it to exactly 100e18.
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e18 - 1, "settled debited by the 1-unit return");
        assertEq(
            executor.attestationAnchorPrincipal(REMOTE_CHAIN),
            100e18,
            "clamp restores the band minimally: never above the pre-debit principal, never the residue"
        );

        // The cap is therefore still 120e18: at the cap the approval passes, one unit above it reverts.
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(120e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e18);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 proposalId = _propose(120e18 + 1);
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                100e18,
                120e18 + 1,
                2_000
            )
        );
        executor.approveBalance(proposalId);
    }
}

contract AnchorBandToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}
