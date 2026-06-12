// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {RWAForkTestBase, MockRWAProtocolForFork} from "./RWAForkTestBase.t.sol";
import {RWAExecutor} from "../../../contracts/fuses/rwa/RWAExecutor.sol";
import {IRWAExecutor} from "../../../contracts/fuses/rwa/IRWAExecutor.sol";
import {RWAErrors} from "../../../contracts/fuses/rwa/errors/RWAErrors.sol";
import {RWASubstrateLib} from "../../../contracts/fuses/rwa/lib/RWASubstrateLib.sol";

/// @title RWACustodianDualApprovalForkTest
/// @notice Fork coverage for the custodian dual-approval flow: propose-by-A, confirm-by-B, with
///         negative cases for same-custodian, expired proposals, replayed hashes, and the
///         `MIN_UPDATE_INTERVAL` rate limiter. Also exercises the dust check via a direct token
///         transfer to the executor.
contract RWACustodianDualApprovalForkTest is RWAForkTestBase {
    function test_fork_custodianDualApproval_happy() public {
        _createExecutor();

        vm.prank(custodianA);
        IRWAExecutor(_executorAddress()).proposeBalance(balanceAccountA, 1_000e6);

        (,, uint64 proposedAt, uint256 nonce) = RWAExecutor(_executorAddress()).pendingProposals(balanceAccountA);
        bytes32 h = _proposalHash(_executorAddress(), balanceAccountA, 1_000e6, custodianA, proposedAt, nonce);

        vm.prank(custodianB);
        IRWAExecutor(_executorAddress()).confirmBalance(balanceAccountA, h);

        // Confirmed balance is reflected on the executor and bumped lastCustodianUpdateTimestamp.
        (uint256 total,, uint256 lastTs) = IRWAExecutor(_executorAddress()).getBalanceFuseSnapshot();
        assertEq(total, 1_000e6, "balance confirmed");
        assertEq(lastTs, block.timestamp, "last custodian ts bumped");
    }

    function test_fork_custodianDualApproval_sameCustodianReverts() public {
        _createExecutor();
        vm.prank(custodianA);
        IRWAExecutor(_executorAddress()).proposeBalance(balanceAccountA, 100e6);

        (,, uint64 pa, uint256 n) = RWAExecutor(_executorAddress()).pendingProposals(balanceAccountA);
        bytes32 h = _proposalHash(_executorAddress(), balanceAccountA, 100e6, custodianA, pa, n);

        vm.prank(custodianA);
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAExecutorSameProposerAndConfirmer.selector, custodianA));
        IRWAExecutor(_executorAddress()).confirmBalance(balanceAccountA, h);
    }

    function test_fork_custodianDualApproval_expiredProposalReverts() public {
        _createExecutor();
        vm.prank(custodianA);
        IRWAExecutor(_executorAddress()).proposeBalance(balanceAccountA, 100e6);

        (,, uint64 pa, uint256 n) = RWAExecutor(_executorAddress()).pendingProposals(balanceAccountA);
        bytes32 h = _proposalHash(_executorAddress(), balanceAccountA, 100e6, custodianA, pa, n);

        // Move past the TTL (stalenessMax = 1 day).
        vm.warp(block.timestamp + STALENESS_MAX_S + 1);

        vm.prank(custodianB);
        vm.expectRevert(
            abi.encodeWithSelector(
                RWAErrors.RWAExecutorProposalExpired.selector, uint256(pa), block.timestamp, STALENESS_MAX_S
            )
        );
        IRWAExecutor(_executorAddress()).confirmBalance(balanceAccountA, h);
    }

    function test_fork_custodianDualApproval_replayHashReverts() public {
        _createExecutor();

        // First approval cycle.
        vm.prank(custodianA);
        IRWAExecutor(_executorAddress()).proposeBalance(balanceAccountA, 500e6);
        (,, uint64 pa1, uint256 n1) = RWAExecutor(_executorAddress()).pendingProposals(balanceAccountA);
        bytes32 h1 = _proposalHash(_executorAddress(), balanceAccountA, 500e6, custodianA, pa1, n1);

        vm.prank(custodianB);
        IRWAExecutor(_executorAddress()).confirmBalance(balanceAccountA, h1);

        // Second cycle: new proposal. The *old* hash must no longer work because pending is new.
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL_S + 1); // clear rate-limit
        vm.prank(custodianA);
        IRWAExecutor(_executorAddress()).proposeBalance(balanceAccountA, 600e6);

        (,, uint64 pa2, uint256 n2) = RWAExecutor(_executorAddress()).pendingProposals(balanceAccountA);
        bytes32 h2 = _proposalHash(_executorAddress(), balanceAccountA, 600e6, custodianA, pa2, n2);
        assertTrue(h1 != h2, "hashes differ across nonces/timestamps");

        vm.prank(custodianB);
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAExecutorProposalHashMismatch.selector, h2, h1));
        IRWAExecutor(_executorAddress()).confirmBalance(balanceAccountA, h1);
    }

    function test_fork_custodianDualApproval_minUpdateIntervalEnforced() public {
        _createExecutor();

        // First confirmed update
        _custodianConfirm(balanceAccountA, 100e6);

        // Attempt a second update inside the MIN_UPDATE_INTERVAL window
        vm.prank(custodianA);
        IRWAExecutor(_executorAddress()).proposeBalance(balanceAccountA, 200e6);
        (,, uint64 pa, uint256 n) = RWAExecutor(_executorAddress()).pendingProposals(balanceAccountA);
        bytes32 h = _proposalHash(_executorAddress(), balanceAccountA, 200e6, custodianA, pa, n);

        uint256 lastUpdate = block.timestamp;
        // Warp by less than MIN_UPDATE_INTERVAL_S
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL_S - 1);

        vm.prank(custodianB);
        vm.expectRevert(
            abi.encodeWithSelector(
                RWAErrors.RWAExecutorMinUpdateIntervalNotMet.selector,
                lastUpdate,
                block.timestamp,
                MIN_UPDATE_INTERVAL_S
            )
        );
        IRWAExecutor(_executorAddress()).confirmBalance(balanceAccountA, h);
    }

    function test_fork_custodianDualApproval_dustCheckBlocksUpdate() public {
        // Reconfigure dust threshold to 0 so any non-zero executor balance triggers the guard.
        _grantDustZero();

        // Deploy executor and seed it with USDC directly — simulates a stuck balance.
        _createExecutor();
        deal(USDC, _executorAddress(), 1e6); // 1 USDC

        uint256 decimals = 6; // USDC decimals
        uint256 allowed = (10 ** decimals) * 0 / 100; // dust threshold = 0
        vm.prank(custodianA);
        vm.expectRevert(
            abi.encodeWithSelector(RWAErrors.RWAExecutorDustCheckFailed.selector, USDC, uint256(1e6), allowed)
        );
        IRWAExecutor(_executorAddress()).proposeBalance(balanceAccountA, 50e6);
    }

    // ============================================================
    // Helpers
    // ============================================================

    /// @dev Re-grant substrates with `DUST_THRESHOLD = 0` so `_checkDust()` fails on any balance.
    ///      After regrant we must re-sync the executor cache.
    function _grantDustZero() internal {
        bytes32[] memory subs = new bytes32[](11);
        subs[0] = RWASubstrateLib.encodeAssetSubstrate(USDC);
        subs[1] = RWASubstrateLib.encodeAssetSubstrate(USDT);
        subs[2] = RWASubstrateLib.encodeBalanceAccountSubstrate(balanceAccountA);
        subs[3] = RWASubstrateLib.encodeBalanceAccountSubstrate(balanceAccountB);
        subs[4] = RWASubstrateLib.encodeCustodianSubstrate(custodianA);
        subs[5] = RWASubstrateLib.encodeCustodianSubstrate(custodianB);
        subs[6] = RWASubstrateLib.encodeTargetSubstrate(address(rwaProtocol), MockRWAProtocolForFork.deposit.selector);
        subs[7] = RWASubstrateLib.encodeStalenessMaxSubstrate(STALENESS_MAX_S);
        subs[8] = RWASubstrateLib.encodeBigChangeBpsSubstrate(BIG_CHANGE_BPS);
        subs[9] = RWASubstrateLib.encodeDustThresholdSubstrate(0);
        subs[10] = RWASubstrateLib.encodeMinUpdateIntervalSubstrate(MIN_UPDATE_INTERVAL_S);
        _grantSubstrates(subs);
        _syncExecutorSubstrates();
    }
}
