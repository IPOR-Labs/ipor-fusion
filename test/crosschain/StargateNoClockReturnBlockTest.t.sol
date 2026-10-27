// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {IStargateExecutorLibraryAbi} from "../../contracts/crosschain/stargate/IStargateExecutorLibraryAbi.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

/// @title StargateNoClockReturnBlockTest
/// @notice IL-8618 / IL-8624 (Ackee 7, TP-M-40 / TP-M-46): a late return leg that cannot reclaim a staleness slot
///         raises `chainBlocked` and is counted in `noClockReturnCount`. `forceSetSettled` refuses while the
///         count is non-zero (the record is not in `pendingTransferCount`); the finalization of the last such
///         record lifts the block iff nothing else raised it.
contract StargateNoClockReturnBlockTest is CrosschainTestBase {
    using stdStorage for StdStorage;

    function setUp() public {
        _baseSetUp();
        _readyDispatcher();
        _settle100(); // settled = 100e6, frontier = 1
    }

    function _approveFresh(uint256 settledLD_, uint64 version_) internal returns (uint256 pid) {
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: settledLD_,
            stateVersion: version_,
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 20 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        pid = executor.proposalCount();
        vm.prank(approver);
        executor.approveBalance(pid);
    }

    /// @dev Cancel a recall that nothing touched, then fill all 16 staleness slots with newer outbound transfers.
    function _cancelAndFillPool() internal returns (bytes32 requestId, bytes32[16] memory ids, bytes32[16] memory guids) {
        (requestId,,) = _requestAssets(40e6, 0);
        vm.warp(block.timestamp + TRANSFER_STALENESS_MAX + 1);
        executor.cancelStaleReturnRequest(REMOTE_CHAIN);
        for (uint256 i; i < 16; ++i) {
            (ids[i], guids[i],) = _sendAsset(1e6, 0);
        }
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 16, "pool full");
    }

    /// @dev Settle the 16 outbound transfers (versions 2..17) so only the unclocked record stays open.
    function _settleAll(bytes32[16] memory ids, bytes32[16] memory guids) internal {
        for (uint256 i; i < 16; ++i) {
            _deliverTransferSettled(ids[i], guids[i], 1e6, uint64(2 + i));
        }
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "no counted slot left");
    }

    function _forceSet(uint256 newSettledLD_) internal {
        uint64 v = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 id = executor.scheduleForceSetSettledBalance(REMOTE_CHAIN, newSettledLD_, v, _markFsObs(), false);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(id, REMOTE_CHAIN, newSettledLD_, v, fsObs, false);
    }

    function _composeFirstNoClock() internal returns (bytes32 requestId) {
        bytes32[16] memory ids;
        bytes32[16] memory guids;
        (requestId, ids, guids) = _cancelAndFillPool();
        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "no-slot compose blocks the chain");
        _settleAll(ids, guids);
    }

    /// @notice IL-8618: force-set refuses while the unclocked record is open; works once it is resolved.
    function testForceSetRefusedWhileUnclockedReturnOpenThenWorksAfterResolve() public {
        bytes32 requestId = _composeFirstNoClock();

        uint64 v = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 id = executor.scheduleForceSetSettledBalance(REMOTE_CHAIN, 100e6, v, _markFsObs(), false);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnclockedReturnOpen.selector, REMOTE_CHAIN, 1));
        executor.executeForceSetSettledBalance(id, REMOTE_CHAIN, 100e6, v, fsObs, false);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "block untouched");

        // Resolve the record (compose-first: DROP_RETURN_METADATA_INCLUDED), then the force-set works.
        vm.prank(admin);
        uint256 rid = executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.DROP_RETURN_METADATA_INCLUDED);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rid, requestId, ResolveOutcome.DROP_RETURN_METADATA_INCLUDED);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "drop keeps the block for the force-set");
        // The drop's own block must not be lifted by the finalization: only the force-set clears it.
        _forceSet(60e6);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "force-set lifted the block");
    }

    /// @notice IL-8618: while a no-clock record is open `getBalance` is blocked.
    function testNavBlockedWhileUnclockedReturnOpen() public {
        _composeFirstNoClock();
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    /// @notice IL-8624: metadata arrives, the record finalizes, the block it alone raised is lifted.
    function testFinalizeLiftsBlockRaisedOnlyByNoClockReturn() public {
        bytes32 requestId = _composeFirstNoClock();
        assertEq(executor.noClockReturnCount(REMOTE_CHAIN), 1, "record counted");

        vm.expectEmit(false, false, false, true, address(executor));
        emit IStargateExecutorLibraryAbi.NoClockReturnBlockLifted(REMOTE_CHAIN);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 18);

        assertEq(executor.noClockReturnCount(REMOTE_CHAIN), 0, "count released");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "block lifted on finalization");
        _approveFresh(76e6, 18);
        assertEq(executor.getBalance(), 116e6, "NAV open again");
    }

    /// @notice IL-8624: metadata-first no-slot return (value in `returnInFlight`) also clears on its compose.
    function testMetadataFirstNoClockReturnClearsOnCompose() public {
        (bytes32 requestId, bytes32[16] memory ids, bytes32[16] memory guids) = _cancelAndFillPool();
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "no-slot metadata blocks the chain");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 40e6, "value booked unclocked");
        for (uint256 i; i < 16; ++i) {
            _deliverTransferSettled(ids[i], guids[i], 1e6, uint64(3 + i));
        }
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();

        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "block lifted on finalization");
    }

    /// @notice IL-8624 limitation: a foreign block raised while the record is open stays after finalization.
    function testForeignBlockSurvivesFinalization() public {
        bytes32 requestId = _composeFirstNoClock();

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: 90e6,
            stateVersion: executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN),
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 20 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        uint256 pid = executor.proposalCount();
        vm.prank(approver);
        executor.rejectAndBlockProposal(pid);

        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 18);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "foreign block stays for the timelocked force-set");
    }

    /// @notice A block that stood BEFORE the no-clock return is not lifted by its finalization.
    function testPreexistingBlockSurvivesFinalization() public {
        bytes32[16] memory ids;
        bytes32[16] memory guids;
        bytes32 requestId;
        (requestId, ids, guids) = _cancelAndFillPool();
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: 95e6,
            stateVersion: 1,
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 20 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        uint256 pid = executor.proposalCount();
        vm.prank(approver);
        executor.rejectAndBlockProposal(pid);
        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);
        _settleAll(ids, guids);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 18);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "earlier block stays");
    }

    function _forceResolve(bytes32 id_, ResolveOutcome outcome_) internal {
        vm.prank(admin);
        uint256 rid = executor.scheduleForceResolveTransfer(id_, outcome_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rid, id_, outcome_);
    }

    function _advanceFrontierOnce() internal {
        uint64 newVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN) + 1;
        _forceResolve(bytes32((uint256(REMOTE_CHAIN) << 64) | uint256(newVersion)), ResolveOutcome.ADVANCE_STATE_FRONTIER);
    }

    /// @notice N3(a): with `settled == 0` the chain total is zero, so the bit alone would not block NAV; the
    ///         `noClockReturnCount != 0` branch of `computeNavSD` is what reverts.
    function testNavBlockedByCountWhenChainTotalIsZero() public {
        _composeFirstNoClock();
        stdstore.target(address(executor)).sig("settledRemoteBalance(uint256)").with_key(REMOTE_CHAIN).checked_write(
            uint256(0)
        );
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "settled zeroed");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "compose-first books no returnInFlight");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "nothing outbound");
        assertEq(executor.noClockReturnCount(REMOTE_CHAIN), 1, "record counted");
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    /// @notice IL-8611 follow-up: `getBalanceUnchecked()` mirrors the `noClockReturnCount != 0` branch of
    ///         `getBalance()` even when the chain total is zero.
    function testUncheckedBalanceBlockedByCountWhenChainTotalIsZero() public {
        _composeFirstNoClock();
        stdstore.target(address(executor)).sig("settledRemoteBalance(uint256)").with_key(REMOTE_CHAIN).checked_write(
            uint256(0)
        );
        assertEq(executor.noClockReturnCount(REMOTE_CHAIN), 1, "record counted");
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalanceUnchecked();
    }

    /// @notice N3(b): while the first unclocked record is open the chain refuses a new return request (the block
    ///         refuses new requests); the count is not capped at 1 because cancelled recalls leave records behind
    ///         (see the two-record test below).
    function testSecondReturnRequestRefusedWhileUnclockedRecordOpen() public {
        _composeFirstNoClock();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 10e6, 0, "");
        assertEq(executor.noClockReturnCount(REMOTE_CHAIN), 1, "still one counted record");
    }

    /// @notice IL-9165: two cancelled recalls whose late compose legs find no staleness slot are both unclocked;
    ///         the count reaches 2 and the block lifts only when the SECOND record finalizes.
    function testShouldLiftNoClockBlockOnlyWhenBothUnclockedRecordsFinalize() public {
        bytes32 recallA;
        bytes32 recallB;
        (recallA, , ) = _requestAssets(40e6, 0);
        vm.warp(block.timestamp + TRANSFER_STALENESS_MAX + 1);
        executor.cancelStaleReturnRequest(REMOTE_CHAIN);
        (recallB, , ) = _requestAssets(20e6, 0);
        vm.warp(block.timestamp + TRANSFER_STALENESS_MAX + 1);
        executor.cancelStaleReturnRequest(REMOTE_CHAIN);

        bytes32[16] memory ids;
        bytes32[16] memory guids;
        for (uint256 i; i < 16; ++i) {
            (ids[i], guids[i], ) = _sendAsset(1e6, 0);
        }
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 16, "pool full");

        bytes32 guidB = keccak256("RGUID-B");
        usdc.mint(address(executor), 60e6);
        _deliverReturnCompose(recallA, RGUID, 40e6);
        _deliverReturnCompose(recallB, guidB, 20e6);
        assertEq(executor.noClockReturnCount(REMOTE_CHAIN), 2, "both records counted");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "blocked");
        _settleAll(ids, guids);

        // First finalization: count 1, the block stays and NAV still reverts.
        _deliverReturnStarted(recallA, RGUID, 40e6, 40e6, 18);
        assertEq(executor.noClockReturnCount(REMOTE_CHAIN), 1, "one record left");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "still blocked after the first finalization");
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();

        // Second finalization: count 0, the block is lifted and NAV prices again.
        vm.expectEmit(false, false, false, true, address(executor));
        emit IStargateExecutorLibraryAbi.NoClockReturnBlockLifted(REMOTE_CHAIN);
        _deliverReturnStarted(recallB, guidB, 20e6, 20e6, 19);
        assertEq(executor.noClockReturnCount(REMOTE_CHAIN), 0, "count released");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "block lifted by the last record");
        _approveFresh(56e6, 19);
        assertEq(executor.getBalance(), 116e6, "NAV open again");
    }

    /// @notice N3(c): DROP_FROM_NAV on a metadata-first no-clock record closes it through `_finalizeReturn`,
    ///         releases the count and lifts the block it raised.
    function testDropFromNavOnMetadataFirstNoClockRecordLiftsBlock() public {
        (bytes32 requestId, bytes32[16] memory ids, bytes32[16] memory guids) = _cancelAndFillPool();
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        for (uint256 i; i < 16; ++i) {
            _deliverTransferSettled(ids[i], guids[i], 1e6, uint64(3 + i));
        }
        assertEq(executor.noClockReturnCount(REMOTE_CHAIN), 1, "record counted");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "blocked");

        vm.prank(admin);
        uint256 rid = executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.DROP_FROM_NAV);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.expectEmit(false, false, false, true, address(executor));
        emit IStargateExecutorLibraryAbi.NoClockReturnBlockLifted(REMOTE_CHAIN);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rid, requestId, ResolveOutcome.DROP_FROM_NAV);

        assertEq(executor.noClockReturnCount(REMOTE_CHAIN), 0, "count released");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "block lifted");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "value dropped from NAV");
    }

    /// @notice N3(d): a frontier repair during the window resets the flag; the finalization releases the count but
    ///         the block stays (the repair owns the NAV block now, an ordinary approval or force-set lifts it).
    function testFrontierRepairDuringWindowResetsFlagSoFinalizeKeepsBlock() public {
        bytes32 requestId = _composeFirstNoClock();
        _advanceFrontierOnce();
        uint64 v = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);

        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, v + 1);

        assertEq(executor.noClockReturnCount(REMOTE_CHAIN), 0, "count released");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "block stays after the repair reset the flag");
    }

    /// @notice N3(e): RETURN_REJECTED after the compose value leg resets the flag; a later metadata finalization
    ///         does not lift the block.
    function testRejectedAfterValueLegResetsFlagSoFinalizeKeepsBlock() public {
        bytes32 requestId = _composeFirstNoClock();
        _deliverReturnRejected(requestId);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "still blocked");

        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 18);

        assertEq(executor.noClockReturnCount(REMOTE_CHAIN), 0, "count released");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "block stays after the reject reset the flag");
    }
}
