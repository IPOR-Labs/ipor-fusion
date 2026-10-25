// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {StargateCrosschainExecutor} from "../../contracts/crosschain/stargate/StargateCrosschainExecutor.sol";
import {ExecutorInitParams} from "../../contracts/crosschain/interfaces/ICrosschainFactory.sol";
import {ICrosschainExecutor, BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {ResolveOutcome, CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

/// @title ExecutorNavTest
/// @notice The core NAV suite: four-bucket transitions, BOTH return arrival orders each netting NAV exactly
///         once, source-of-funds guard, version frontier gaps/duplicates, fail-closed `getBalance`,
///         two-step attestation semantics, `claimAsset` cap and donation exclusion (plan §6/§9, spec §9).
contract ExecutorNavTest is CrosschainTestBase {
    /// @dev Reference production NAV config.
    uint256 internal constant REFERENCE_STALENESS_MAX = 1 hours;
    uint256 internal constant REFERENCE_TRANSFER_STALENESS_MAX = 1 hours;
    uint256 internal constant REFERENCE_MIN_UPDATE_INTERVAL = 1 minutes;
    uint256 internal constant REFERENCE_BIG_CHANGE_BPS = 1_000;
    uint256 internal constant REFERENCE_DEPLOYMENT_TTL = 1 days;

    function setUp() public {
        _baseSetUp();
    }

    // ---------------------------------------------------------------------
    // Bring-up sanity
    // ---------------------------------------------------------------------

    function testShouldStartWithZeroNavWhenDispatcherReady() public {
        _readyDispatcher();
        assertTrue(executor.hasDispatcher(REMOTE_CHAIN), "dispatcher ready");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 0, "initial ACK is value-neutral");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 1, "config epoch advanced");
        assertEq(executor.getBalance(), 0, "zero NAV");
        (bool active,,,,,,) = executor.activeCommand(REMOTE_CHAIN);
        assertFalse(active, "command slot free");
    }

    // ---------------------------------------------------------------------
    // Outbound transfer: outbound-in-flight -> settled nets NAV once
    // ---------------------------------------------------------------------

    function testShouldNetOutboundTransferOnceThroughSettlement() public {
        _readyDispatcher();
        (bytes32 transferId, bytes32 guid,) = _sendAsset(100e6, 0);

        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 100e6, "outbound in-flight recorded");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "not yet settled");
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 100e6, "NAV counts the outbound once");

        _deliverTransferSettled(transferId, guid, 100e6, 1);

        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "outbound cleared");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "moved to settled");
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 100e6, "NAV still counts it exactly once");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 1, "frontier advanced");
    }

    function testShouldRecognizeRouteDiscrepancyAtSettlement() public {
        _readyDispatcher();
        (bytes32 transferId, bytes32 guid,) = _sendAsset(100e6, 0);
        // Dispatcher reports a slightly lower actual credit (route fee): outbound was 100e6, settle 99e6.
        _deliverTransferSettled(transferId, guid, 99e6, 1);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 99e6, "settled reflects actual credited amount");
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 99e6, "NAV recognizes the discrepancy");
    }

    // ---------------------------------------------------------------------
    // Return: BOTH arrival orders net NAV exactly once
    // ---------------------------------------------------------------------

    function testShouldNetReturnMetadataFirstExactlyOnce() public {
        _readyDispatcher();
        _settle100(); // settled = 100e6, frontier = 2

        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 100e6, "request does not move NAV");

        // (a) metadata first: settled -= sent; returnInFlight += expected.
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "settled debited by amountSent");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 40e6, "expected credit in return-in-flight");
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 100e6, "NAV unchanged mid-flight");

        // compose then replaces expected in-flight with actual idle.
        usdc.mint(address(executor), 40e6); // physical Stargate credit
        _deliverReturnCompose(requestId, RGUID, 40e6);
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "return-in-flight cleared");
        assertEq(executor.idleLedger(), 40e6, "actual credit recognized as idle");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "automatic compose releases pending slot");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "settled unchanged by compose");
        // idle(40) + settled(60) = 100, counted once.
        assertEq(executor.idleLedger() + executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "NAV net once");
    }

    function testShouldNetReturnComposeFirstExactlyOnce() public {
        _readyDispatcher();
        _settle100(); // settled = 100e6, frontier = 2

        (bytes32 requestId,,) = _requestAssets(40e6, 0);

        // (b) compose first: tokens physically credited, held in pendingArrivalReserve; settled still counts.
        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);
        assertEq(executor.pendingArrivalReserve(), 40e6, "compose-first parked in reserve");
        assertEq(executor.idleLedger(), 0, "not yet idle");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "settled still counts the value");
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 100e6, "NAV counts value once (via settled)");

        // metadata then reconciles: settled -= sent; idle += actual; reserve released.
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        assertEq(executor.pendingArrivalReserve(), 0, "reserve released");
        assertEq(executor.idleLedger(), 40e6, "recognized as idle");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "metadata reconciliation releases pending slot");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "settled debited");
        assertEq(executor.idleLedger() + executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "NAV net once");
    }

    function testShouldNoopOnDuplicateReturnLegs() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);
        assertEq(executor.idleLedger(), 40e6);

        // Duplicate metadata and duplicate compose after finalization are both idempotent no-ops.
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        _deliverReturnCompose(requestId, RGUID, 40e6);
        assertEq(executor.idleLedger(), 40e6, "no double credit from duplicate legs");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "settled not debited twice");
    }

    function testShouldRecognizeReturnFeeRewardOnBothLegs() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        // Dispatcher debited 40e6 on the remote, but only 39e6 actually credited home (bridge fee).
        _deliverReturnStarted(requestId, RGUID, 40e6, 39e6, 2);
        usdc.mint(address(executor), 39e6);
        _deliverReturnCompose(requestId, RGUID, 39e6);
        assertEq(executor.idleLedger(), 39e6, "actual credit is the fee-reduced amount");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "settled debited by the source amount");
    }

    // ---------------------------------------------------------------------
    // Source-of-funds guard
    // ---------------------------------------------------------------------

    function testShouldBlockSendThatWouldConsumeLedgerBackedTokens() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);
        // idleLedger == 40e6, backed by exactly 40e6 physical USDC.
        assertEq(executor.idleLedger(), 40e6);
        assertEq(usdc.balanceOf(address(executor)), 40e6);

        // A send of 1 without fresh funding would consume ledger-backed tokens -> guard reverts.
        uint256 need = 40e6 + 1;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.SourceOfFundsGuard.selector, 40e6, need));
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 1, 0, "");

        // Fresh untracked funding makes the same send pass.
        usdc.mint(address(executor), 1);
        vm.prank(manager);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 1, 0, "");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 1, "fresh funds bridged");
    }

    function testShouldCountPendingArrivalReserveInSourceOfFundsGuard() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        // Compose-first: 40e6 physically present but parked in pendingArrivalReserve (not idle).
        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);
        assertEq(executor.pendingArrivalReserve(), 40e6);

        // Guard must protect reserve-backed tokens too: idle(0)+reserve(40e6)+1 > balance(40e6).
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.SourceOfFundsGuard.selector, 40e6, 40e6 + 1));
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 1, 0, "");
    }

    // ---------------------------------------------------------------------
    // Version frontier: gap reverts, duplicate no-ops
    // ---------------------------------------------------------------------

    function testShouldRevertOnVersionFrontierGap() public {
        _readyDispatcher(); // frontier = 0
        (bytes32 transferId, bytes32 guid,) = _sendAsset(100e6, 0);
        // Expected next version is 1; a receipt claiming 2 is a gap -> revert (LZ retains for retry).
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.StateVersionGap.selector, REMOTE_CHAIN, uint64(1), uint64(2))
        );
        _deliverTransferSettled(transferId, guid, 100e6, 2);
    }

    function testShouldNoopOnDuplicateSettledReceipt() public {
        _readyDispatcher();
        (bytes32 transferId, bytes32 guid,) = _sendAsset(100e6, 0);
        _deliverTransferSettled(transferId, guid, 100e6, 1);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6);
        // Re-deliver the identical settled receipt: idempotent no-op, no double count.
        _deliverTransferSettled(transferId, guid, 100e6, 1);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "no double count");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 1, "frontier not advanced twice");
    }

    // ---------------------------------------------------------------------
    // getBalance fail-closed gates
    // ---------------------------------------------------------------------

    function testShouldFailClosedWhenChainBlocked() public {
        _readyDispatcher();
        _settle100(); // settled = 100e6, frontier = 2
        uint256 pid = _propose(100e6, 1);
        vm.prank(approver);
        executor.rejectAndBlockProposal(pid);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    /// @dev IL-8260: a blocked chain with nothing tracked adds nothing to NAV, so it must not gate NAV for
    ///      the whole vault. The block stays raised, and the first value booked on the chain gates NAV again.
    function testShouldNotGateNavOnBlockedChainWithZeroTrackedValue() public {
        _readyDispatcher();
        uint256 pid = _propose(0, 0);
        vm.prank(approver);
        executor.rejectAndBlockProposal(pid);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN));
        assertEq(executor.getBalance(), 0, "empty blocked chain does not gate NAV");

        _sendAsset(100e6, 0);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "send does not lift the block");
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    function testShouldFailClosedWhenSettledStale() public {
        _readyDispatcher();
        _settle100(); // settled = 100e6, frontier = 2
        uint256 pid = _propose(100e6, 1);
        vm.prank(approver);
        executor.approveBalance(pid);
        assertEq(executor.getBalance(), 100e6, "fresh NAV readable");

        vm.warp(block.timestamp + STALENESS_MAX + 1);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    function testShouldFailClosedWhenInFlightStale() public {
        _readyDispatcher();
        _sendAsset(100e6, 0); // outbound in-flight, inFlightSince = now
        vm.warp(block.timestamp + TRANSFER_STALENESS_MAX + 1);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavTransferStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    // ---------------------------------------------------------------------
    // Attestation
    // ---------------------------------------------------------------------

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

    function testShouldOverwriteOnlySettledOnApprove() public {
        _readyDispatcher();
        _settle100(); // settled = 100e6, frontier = 2
        // Leave an outbound genuinely in-flight (unsettled) to prove attestation never touches it.
        _sendAsset(50e6, 0); // outboundInFlight = 50e6, frontier stays 2

        uint256 pid = _propose(105e6, 1); // 5% change, within BIG_CHANGE_BPS (10%)
        vm.prank(approver);
        executor.approveBalance(pid);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 105e6, "settled overwritten to attested value");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 50e6, "attestation cannot erase in-flight value");
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 155e6, "NAV = attested settled + untouched in-flight");
    }

    function testShouldRejectAndBlockOnBigChange() public {
        _readyDispatcher();
        _settle100(); // settled = 100e6, frontier = 2
        uint256 basePid = _propose(100e6, 1);
        vm.prank(approver);
        executor.approveBalance(basePid);

        // A 20% jump exceeds BIG_CHANGE_BPS (10%): normal approval is refused.
        uint256 pid = _propose(120e6, 1);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.BigChangeExceeded.selector, 100e6, 120e6, BIG_CHANGE_BPS)
        );
        executor.approveBalance(pid);

        // The approver must reject-and-block instead, which fails NAV closed.
        vm.prank(approver);
        executor.rejectAndBlockProposal(pid);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN));
    }

    function testShouldTimelockFrontierRepairAndRequireFreshApprovalToUnblock() public {
        _readyDispatcher(); // frontier = 0
        bytes32 repairId = bytes32((REMOTE_CHAIN << 64) | uint256(uint64(4)));
        uint256 t0 = block.timestamp;
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(repairId, ResolveOutcome.ADVANCE_STATE_FRONTIER);

        // The frontier repair runs on its own, shorter timelock: FRONTIER_REPAIR_DELAY (6 h), not RESCUE_DELAY.
        assertLt(CrosschainConstants.FRONTIER_REPAIR_DELAY, RESCUE_DELAY, "repair delay is the shorter one");
        uint256 executableAt = t0 + CrosschainConstants.FRONTIER_REPAIR_DELAY;

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.RescueTimelockNotElapsed.selector, rescueId, t0, executableAt)
        );
        executor.executeForceResolveTransfer(rescueId, repairId, ResolveOutcome.ADVANCE_STATE_FRONTIER);

        // One second early still reverts, and reports the current time.
        vm.warp(executableAt - 1);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueTimelockNotElapsed.selector,
                rescueId,
                executableAt - 1,
                executableAt
            )
        );
        executor.executeForceResolveTransfer(rescueId, repairId, ResolveOutcome.ADVANCE_STATE_FRONTIER);

        // Exactly at the delay it executes, long before RESCUE_DELAY would allow it.
        vm.warp(executableAt);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, repairId, ResolveOutcome.ADVANCE_STATE_FRONTIER);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 4);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "repair remains fail-closed");
        // The chain tracks nothing, so the block does not gate NAV (IL-8260); the flag still has to be lifted.
        assertEq(executor.getBalance(), 0);

        uint256 pid = _propose(0, 4);
        vm.prank(approver);
        executor.approveBalance(pid);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "fresh approval completes repair");
        assertEq(executor.getBalance(), 0);
    }

    function testShouldRejectStaleObservationOnPropose() public {
        _readyDispatcher();
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: 0,
            stateVersion: 0,
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp - STALENESS_MAX - 1),
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ObservationStale.selector, REMOTE_CHAIN));
        executor.proposeBalance(o);
    }

    function testShouldEnforceMinUpdateInterval() public {
        _readyDispatcher();
        _settle100();
        uint256 basePid = _propose(100e6, 1);
        vm.prank(approver);
        executor.approveBalance(basePid); // last approval = now

        uint256 pid = _propose(100e6, 1);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.MinUpdateIntervalNotMet.selector, block.timestamp, block.timestamp, MIN_UPDATE_INTERVAL
            )
        );
        executor.approveBalance(pid);
    }

    function testShouldRejectWrongProposerAndApprover() public {
        _readyDispatcher();
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: 0,
            stateVersion: 0,
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedProposer.selector, address(0xdead)));
        executor.proposeBalance(o);

        _propose(0, 0);
        uint256 pid = executor.proposalCount();
        vm.prank(address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedApprover.selector, address(0xdead)));
        executor.approveBalance(pid);
    }

    function testShouldEnforceProposerNotApproverInConstructor() public {
        ExecutorInitParams memory p = _params();
        p.balanceProposer = address(0xCAFE);
        p.balanceApprover = address(0xCAFE);
        vm.expectRevert(CrosschainErrors.ProposerEqualsApprover.selector);
        _deployExecutor(address(factory), p);
    }

    function testShouldRejectBigChangeBpsAboveHundredPercent() public {
        // §8 P3 item 5 / IL-8049: 10_001 bps is still rejected at construction, but the check that now
        // fires is the `ATTESTATION_ANCHOR_BAND_BPS` (2_000) ceiling, not the superseded 100% ceiling —
        // 10_001 exceeds both, so the selector and argument are unchanged (see
        // testShouldRejectBigChangeBpsAboveAnchorBand for the boundary that isolates the new ceiling).
        ExecutorInitParams memory p = _params();
        p.bigChangeBps = 10_001;
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidBigChangeBps.selector, uint256(10_001)));
        _deployExecutor(address(factory), p);
    }

    function testShouldRejectZeroStalenessParams() public {
        // §8 P3 item 4: zero staleness windows are rejected (they would block NAV permanently).
        ExecutorInitParams memory p = _params();
        p.stalenessMax = 0;
        vm.expectRevert(CrosschainErrors.InvalidTimingParameter.selector);
        _deployExecutor(address(factory), p);

        ExecutorInitParams memory p2 = _params();
        p2.transferStalenessMax = 0;
        vm.expectRevert(CrosschainErrors.InvalidTimingParameter.selector);
        _deployExecutor(address(factory), p2);
    }

    // ---------------------------------------------------------------------
    // IL-8049: attestation/timing/TTL boundary validation at construction
    // ---------------------------------------------------------------------

    function testShouldRejectZeroMinUpdateInterval() public {
        ExecutorInitParams memory p = _params();
        p.minUpdateInterval = 0;
        vm.expectRevert(CrosschainErrors.InvalidTimingParameter.selector);
        _deployExecutor(address(factory), p);
    }

    function testShouldRejectMinUpdateIntervalEqualToStalenessMax() public {
        ExecutorInitParams memory p = _params();
        p.minUpdateInterval = p.stalenessMax;
        vm.expectRevert(CrosschainErrors.InvalidTimingParameter.selector);
        _deployExecutor(address(factory), p);
    }

    function testShouldRejectMinUpdateIntervalAboveStalenessMax() public {
        ExecutorInitParams memory p = _params();
        p.minUpdateInterval = p.stalenessMax + 1;
        vm.expectRevert(CrosschainErrors.InvalidTimingParameter.selector);
        _deployExecutor(address(factory), p);
    }

    function testShouldAcceptMinUpdateIntervalJustBelowStalenessMax() public {
        ExecutorInitParams memory p = _params();
        p.minUpdateInterval = p.stalenessMax - 1;
        StargateCrosschainExecutor e = _deployExecutor(address(factory), p);
        assertEq(e.MIN_UPDATE_INTERVAL(), p.stalenessMax - 1, "min update interval set");
    }

    function testShouldRejectZeroBigChangeBps() public {
        ExecutorInitParams memory p = _params();
        p.bigChangeBps = 0;
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidBigChangeBps.selector, uint256(0)));
        _deployExecutor(address(factory), p);
    }

    function testShouldRejectBigChangeBpsAboveAnchorBand() public {
        ExecutorInitParams memory p = _params();
        p.bigChangeBps = CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.InvalidBigChangeBps.selector, CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS + 1
            )
        );
        _deployExecutor(address(factory), p);
    }

    function testShouldAcceptBigChangeBpsEqualToAnchorBand() public {
        ExecutorInitParams memory p = _params();
        p.bigChangeBps = CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS;
        StargateCrosschainExecutor e = _deployExecutor(address(factory), p);
        assertEq(e.BIG_CHANGE_BPS(), CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS, "big change bps set");
    }

    function testShouldRejectDeploymentTtlJustBelowMinimum() public {
        ExecutorInitParams memory p = _params();
        p.deploymentTtl = CrosschainConstants.MIN_DEPLOYMENT_TTL - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.InvalidDeploymentTtl.selector,
                CrosschainConstants.MIN_DEPLOYMENT_TTL - 1,
                CrosschainConstants.MIN_DEPLOYMENT_TTL,
                CrosschainConstants.MAX_DEPLOYMENT_TTL
            )
        );
        _deployExecutor(address(factory), p);
    }

    function testShouldRejectZeroDeploymentTtl() public {
        ExecutorInitParams memory p = _params();
        p.deploymentTtl = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.InvalidDeploymentTtl.selector,
                uint256(0),
                CrosschainConstants.MIN_DEPLOYMENT_TTL,
                CrosschainConstants.MAX_DEPLOYMENT_TTL
            )
        );
        _deployExecutor(address(factory), p);
    }

    function testShouldRejectDeploymentTtlJustAboveMaximum() public {
        ExecutorInitParams memory p = _params();
        p.deploymentTtl = CrosschainConstants.MAX_DEPLOYMENT_TTL + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.InvalidDeploymentTtl.selector,
                CrosschainConstants.MAX_DEPLOYMENT_TTL + 1,
                CrosschainConstants.MIN_DEPLOYMENT_TTL,
                CrosschainConstants.MAX_DEPLOYMENT_TTL
            )
        );
        _deployExecutor(address(factory), p);
    }

    function testShouldRejectMaxUintDeploymentTtl() public {
        ExecutorInitParams memory p = _params();
        p.deploymentTtl = type(uint256).max;
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.InvalidDeploymentTtl.selector,
                type(uint256).max,
                CrosschainConstants.MIN_DEPLOYMENT_TTL,
                CrosschainConstants.MAX_DEPLOYMENT_TTL
            )
        );
        _deployExecutor(address(factory), p);
    }

    function testShouldAcceptDeploymentTtlAtBothBounds() public {
        ExecutorInitParams memory p = _params();
        p.deploymentTtl = CrosschainConstants.MIN_DEPLOYMENT_TTL;
        StargateCrosschainExecutor e = _deployExecutor(address(factory), p);
        assertEq(e.DEPLOYMENT_TTL(), CrosschainConstants.MIN_DEPLOYMENT_TTL, "deployment ttl at floor");

        ExecutorInitParams memory p2 = _params();
        p2.deploymentTtl = CrosschainConstants.MAX_DEPLOYMENT_TTL;
        StargateCrosschainExecutor e2 = _deployExecutor(address(factory), p2);
        assertEq(e2.DEPLOYMENT_TTL(), CrosschainConstants.MAX_DEPLOYMENT_TTL, "deployment ttl at ceiling");
    }

    function testShouldRejectStalenessMaxAboveCeiling() public {
        ExecutorInitParams memory p = _params();
        p.stalenessMax = CrosschainConstants.MAX_STALENESS_WINDOW + 1;
        vm.expectRevert(CrosschainErrors.InvalidTimingParameter.selector);
        _deployExecutor(address(factory), p);
    }

    function testShouldRejectTransferStalenessMaxAboveCeiling() public {
        ExecutorInitParams memory p = _params();
        p.transferStalenessMax = CrosschainConstants.MAX_STALENESS_WINDOW + 1;
        vm.expectRevert(CrosschainErrors.InvalidTimingParameter.selector);
        _deployExecutor(address(factory), p);
    }

    function testShouldAcceptStalenessWindowsAtCeiling() public {
        ExecutorInitParams memory p = _params();
        p.stalenessMax = CrosschainConstants.MAX_STALENESS_WINDOW;
        p.transferStalenessMax = CrosschainConstants.MAX_STALENESS_WINDOW;
        p.minUpdateInterval = 10 minutes;
        StargateCrosschainExecutor e = _deployExecutor(address(factory), p);
        assertEq(e.STALENESS_MAX(), CrosschainConstants.MAX_STALENESS_WINDOW, "staleness max at ceiling");
        assertEq(
            e.TRANSFER_STALENESS_MAX(), CrosschainConstants.MAX_STALENESS_WINDOW, "transfer staleness max at ceiling"
        );
    }

    function testShouldConstructWithReferenceMainnetConfig() public {
        ExecutorInitParams memory p = _params();
        p.stalenessMax = REFERENCE_STALENESS_MAX;
        p.bigChangeBps = REFERENCE_BIG_CHANGE_BPS;
        p.minUpdateInterval = REFERENCE_MIN_UPDATE_INTERVAL;
        p.deploymentTtl = REFERENCE_DEPLOYMENT_TTL;
        p.transferStalenessMax = REFERENCE_TRANSFER_STALENESS_MAX;
        StargateCrosschainExecutor e = _deployExecutor(address(factory), p);
        assertEq(e.STALENESS_MAX(), REFERENCE_STALENESS_MAX, "reference staleness max");
        assertEq(e.BIG_CHANGE_BPS(), REFERENCE_BIG_CHANGE_BPS, "reference big change bps");
        assertEq(e.MIN_UPDATE_INTERVAL(), REFERENCE_MIN_UPDATE_INTERVAL, "reference min update interval");
        assertEq(e.DEPLOYMENT_TTL(), REFERENCE_DEPLOYMENT_TTL, "reference deployment ttl");
        assertEq(e.TRANSFER_STALENESS_MAX(), REFERENCE_TRANSFER_STALENESS_MAX, "reference transfer staleness max");
    }

    // ---------------------------------------------------------------------
    // claimAsset cap + donations excluded
    // ---------------------------------------------------------------------

    function _fundIdle40() internal {
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);
    }

    function testShouldCapClaimAtIdleLedger() public {
        _readyDispatcher();
        _fundIdle40(); // idle = 40e6, backed by 40e6 USDC

        vm.prank(manager);
        executor.claimAsset(1000e6); // ask for far more than idle
        assertEq(usdc.balanceOf(manager), 40e6, "claim capped at idle ledger");
        assertEq(executor.idleLedger(), 0, "idle drained");
    }

    function testShouldClaimExactWhenBelowIdle() public {
        _readyDispatcher();
        _fundIdle40();
        vm.prank(manager);
        executor.claimAsset(30e6);
        assertEq(usdc.balanceOf(manager), 30e6, "exact claim");
        assertEq(executor.idleLedger(), 10e6, "remainder stays idle");
    }

    function testShouldExcludeDonationsFromClaimableAndNav() public {
        _readyDispatcher();
        _fundIdle40(); // idle = 40e6

        // Direct donation to the executor: physically present but untracked (rescue-only).
        usdc.mint(address(executor), 10e6);
        assertEq(usdc.balanceOf(address(executor)), 50e6, "balance includes donation");
        assertEq(executor.idleLedger(), 40e6, "donation excluded from ledger");

        vm.prank(manager);
        executor.claimAsset(type(uint256).max);
        assertEq(usdc.balanceOf(manager), 40e6, "only tracked idle claimable");
        assertEq(usdc.balanceOf(address(executor)), 10e6, "donation remains, rescue-only");
    }

    function testShouldOnlyLetManagerClaim() public {
        _readyDispatcher();
        _fundIdle40();
        vm.prank(address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedManager.selector, address(0xdead)));
        executor.claimAsset(1);
    }
}
