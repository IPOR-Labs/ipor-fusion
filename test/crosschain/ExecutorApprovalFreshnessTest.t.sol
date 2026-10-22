// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {StargateExecutorAttestationLib} from "../../contracts/crosschain/stargate/lib/StargateExecutorAttestationLib.sol";
import {CcipExecutorAttestationLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";

/// @title StargateApprovalFreshnessTest
/// @notice IL-8631 / TP-L-03 and IL-8648 / TP-L-20 on Stargate. `approve` (1) refuses an observation whose
///         remaining freshness is shorter than `minUpdateInterval` (it would go stale before the next approval
///         is permitted, freezing NAV with `NavSettledStale`) and (2) refuses an observation older than the
///         one already approved (it would roll the NAV freshness clock backwards).
contract StargateApprovalFreshnessTest is CrosschainTestBase {
    function setUp() public {
        _baseSetUp();
        _readyDispatcher();
        _settle100(); // settled = 100e6, frontier = 1
    }

    function _proposeAt(uint64 remoteTimestamp_) internal returns (uint256) {
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: 100e6,
            stateVersion: 1,
            remoteBlock: 1,
            remoteTimestamp: remoteTimestamp_,
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        return executor.proposalCount();
    }

    function _approve(uint256 pid_) internal {
        vm.prank(approver);
        executor.approveBalance(pid_);
    }

    function testShouldRejectObservationWithRemainingFreshnessBelowMinUpdateInterval() public {
        uint64 ts = uint64(block.timestamp - (STALENESS_MAX - MIN_UPDATE_INTERVAL) - 1); // remaining = interval - 1
        uint256 pid = _proposeAt(ts);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                StargateExecutorAttestationLib.ObservationTooCloseToStale.selector, REMOTE_CHAIN, ts
            )
        );
        executor.approveBalance(pid);
    }

    function testShouldAcceptObservationWithRemainingFreshnessExactlyMinUpdateInterval() public {
        uint64 ts = uint64(block.timestamp - (STALENESS_MAX - MIN_UPDATE_INTERVAL));
        _approve(_proposeAt(ts));
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), ts);
    }

    function testShouldKeepNavFreshUntilNextApprovalIsPermitted() public {
        uint64 ts = uint64(block.timestamp - (STALENESS_MAX - MIN_UPDATE_INTERVAL));
        _approve(_proposeAt(ts));

        // Still rate-limited one second before the interval ends, and NAV is fresh.
        uint256 approvedAt = block.timestamp;
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL - 1);
        assertEq(executor.getBalance(), 100e6);
        uint256 early = _proposeAt(uint64(block.timestamp));
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.MinUpdateIntervalNotMet.selector, approvedAt, block.timestamp, MIN_UPDATE_INTERVAL
            )
        );
        executor.approveBalance(early);
        // The interval has elapsed: a replacement approval is permitted AND NAV is still fresh at that instant.
        vm.warp(block.timestamp + 1);
        assertEq(executor.getBalance(), 100e6);
        _approve(_proposeAt(uint64(block.timestamp)));
        assertEq(executor.getBalance(), 100e6);
    }

    function testShouldGoStaleOneSecondAfterTheRateLimitOpens() public {
        uint64 ts = uint64(block.timestamp - (STALENESS_MAX - MIN_UPDATE_INTERVAL));
        _approve(_proposeAt(ts));
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        assertEq(executor.getBalance(), 100e6);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    function testShouldRejectObservationOlderThanTheApprovedOne() public {
        uint64 first = uint64(block.timestamp);
        _approve(_proposeAt(first));

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        uint64 older = first - 5 minutes; // still fresh and still approvable by the freshness rules
        uint256 pid = _proposeAt(older);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                StargateExecutorAttestationLib.ObservationOlderThanApproved.selector, REMOTE_CHAIN, older, first
            )
        );
        executor.approveBalance(pid);

        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), first, "clock did not regress");
        assertEq(executor.getBalance(), 100e6, "NAV still fresh");
    }

    function testShouldAcceptObservationEqualToTheApprovedOne() public {
        uint64 first = uint64(block.timestamp);
        _approve(_proposeAt(first));
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        _approve(_proposeAt(first));
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), first);
    }

    function testShouldAdvanceFreshnessClockOnNormalFreshApprovals() public {
        _approve(_proposeAt(uint64(block.timestamp)));
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        uint64 next = uint64(block.timestamp);
        _approve(_proposeAt(next));
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), next);
    }
}

/// @title CcipApprovalFreshnessTest
/// @notice Same rules on the CCIP transport (IL-8631 / IL-8648).
contract CcipApprovalFreshnessTest is CcipExecutorFixture {
    function setUp() public {
        _fixtureSetUp();
        _bridge(100e18); // settled = 100e18
        vm.warp(block.timestamp + 8 days); // leave the bridge receipt well behind every observation below
    }

    function _proposeAt(uint64 remoteTimestamp_) internal returns (uint256) {
        return executor.proposeBalance(
            REMOTE_CHAIN,
            100e18,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            1,
            remoteTimestamp_,
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
    }

    function _approve(uint256 pid_) internal {
        vm.prank(APPROVER);
        executor.approveBalance(pid_);
    }

    function testShouldRejectObservationWithRemainingFreshnessBelowMinUpdateInterval() public {
        uint64 ts = uint64(block.timestamp - (BALANCE_STALENESS_MAX - MIN_UPDATE_INTERVAL) - 1);
        uint256 pid = _proposeAt(ts);
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorAttestationLib.ObservationTooCloseToStale.selector, REMOTE_CHAIN, ts)
        );
        executor.approveBalance(pid);
    }

    function testShouldAcceptObservationWithRemainingFreshnessExactlyMinUpdateInterval() public {
        uint64 ts = uint64(block.timestamp - (BALANCE_STALENESS_MAX - MIN_UPDATE_INTERVAL));
        _approve(_proposeAt(ts));
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), ts);
    }

    function testShouldKeepNavFreshUntilNextApprovalIsPermitted() public {
        uint64 ts = uint64(block.timestamp - (BALANCE_STALENESS_MAX - MIN_UPDATE_INTERVAL));
        _approve(_proposeAt(ts));

        uint64 approvedAt = uint64(block.timestamp);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL - 1);
        assertEq(executor.getBalance(), 100e18);
        uint256 early = _proposeAt(uint64(block.timestamp));
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.MinUpdateIntervalNotMet.selector,
                approvedAt,
                block.timestamp,
                MIN_UPDATE_INTERVAL
            )
        );
        executor.approveBalance(early);
        vm.warp(block.timestamp + 1);
        assertEq(executor.getBalance(), 100e18);
        _approve(_proposeAt(uint64(block.timestamp)));
        assertEq(executor.getBalance(), 100e18);
    }

    function testShouldGoStaleOneSecondAfterTheRateLimitOpens() public {
        uint64 ts = uint64(block.timestamp - (BALANCE_STALENESS_MAX - MIN_UPDATE_INTERVAL));
        _approve(_proposeAt(ts));
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        assertEq(executor.getBalance(), 100e18);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorAttestationLib.ObservationStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    function testShouldRejectObservationOlderThanTheApprovedOne() public {
        uint64 first = uint64(block.timestamp);
        _approve(_proposeAt(first));

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        uint64 older = first - 5 minutes;
        uint256 pid = _proposeAt(older);
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.ObservationOlderThanApproved.selector, REMOTE_CHAIN, older, first
            )
        );
        executor.approveBalance(pid);

        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), first, "clock did not regress");
        assertEq(executor.getBalance(), 100e18, "NAV still fresh");
    }

    function testShouldAcceptObservationEqualToTheApprovedOne() public {
        uint64 first = uint64(block.timestamp);
        _approve(_proposeAt(first));
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        _approve(_proposeAt(first));
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), first);
    }

    function testShouldAdvanceFreshnessClockOnNormalFreshApprovals() public {
        _approve(_proposeAt(uint64(block.timestamp)));
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        uint64 next = uint64(block.timestamp);
        _approve(_proposeAt(next));
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), next);
    }
}
