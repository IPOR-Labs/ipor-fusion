// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {ExecutorInitParams} from "../../contracts/crosschain/interfaces/ICrosschainFactory.sol";
import {StargateAnchorBandRegressionConfig} from "./helpers/StargateAnchorBandRegressionConfig.sol";

/// @title StargateBandFixtureBase
/// @notice The Stargate test base with the relative step and the anchor band chosen per test. The parameters are changed
///         through field assignments and `StargateAnchorBandRegressionConfig.withBand`, so this file also compiles on the
///         base commit (IL-9720): it uses no symbol the base does not have, and reverts are asserted by selectors derived
///         from their signatures.
abstract contract StargateBandFixtureBase is CrosschainTestBase {
    /// @dev `AttestationOutsideAnchorBand(uint256,uint256,uint256,uint256)`, derived from the signature on purpose.
    bytes4 internal constant OUTSIDE_BAND =
        bytes4(keccak256("AttestationOutsideAnchorBand(uint256,uint256,uint256,uint256)"));
    bytes4 internal constant BIG_CHANGE = bytes4(keccak256("BigChangeExceeded(uint256,uint256,uint256)"));

    function _bandParams(uint256 bigChangeBps_, uint256 bandBps_) internal view returns (ExecutorInitParams memory p) {
        p = _params();
        p.bigChangeBps = bigChangeBps_;
        p = StargateAnchorBandRegressionConfig.withBand(p, bandBps_);
    }

    /// @dev Replaces the base executor by one built with the given relative step and band, then brings it up.
    function _setUpBand(uint256 bigChangeBps_, uint256 bandBps_) internal {
        _baseSetUp();
        executor = _deployExecutor(address(factory), _bandParams(bigChangeBps_, bandBps_));
        vm.deal(address(executor), 100 ether);
        _readyDispatcher();
    }

    function _tryAttest(uint256 settledLD_, uint64 stateVersion_) internal returns (bool ok, bytes memory reason) {
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
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
        try executor.approveBalance(proposalId) {
            ok = true;
        } catch (bytes memory data) {
            reason = data;
        }
    }

    function _attest(uint256 settledLD_, uint64 stateVersion_) internal {
        (bool ok, bytes memory reason) = _tryAttest(settledLD_, stateVersion_);
        if (!ok) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    /// @dev Bridge `amount_` out and settle it (state version 1): credits `settled` and the anchor.
    function _settle(uint256 amount_) internal {
        (bytes32 transferId, bytes32 guid, ) = _sendAsset(amount_, 0);
        _deliverTransferSettled(transferId, guid, amount_, 1);
    }
}

/// @title StargateLeveragedLegBandRegressionTest
/// @notice IL-9720 (3sigma #26), Stargate half of `CcipLeveragedLegBandRegressionTest`: a leveraged leg is walked to its true
///         value with ordinary approvals, each within the 20% relative step of the previous one: 8.0M -> 9.6M -> 11.2M
///         (+40% from the anchor) and 8.0M -> 6.4M -> 5.6M (-30%). With a band of 10_000 bps every step is admitted; on the
///         base commit (band fixed at 2_000) the second step of each sequence reverts `AttestationOutsideAnchorBand`.
contract StargateLeveragedLegBandRegressionTest is StargateBandFixtureBase {
    uint256 internal constant ANCHOR = 8_000_000e6;

    function setUp() public {
        _setUpBand(2_000, 10_000);
        _settle(ANCHOR);
    }

    function testShouldWalkALeveragedLegUpFortyPercentWithOrdinaryAttestations() public {
        _attest(9_600_000e6, 1);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 9_600_000e6, "first step: +20% from the anchor");
        _attest(11_200_000e6, 1);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 11_200_000e6, "second step: +40% from the anchor");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), ANCHOR, "approvals never move the anchor");
    }

    function testShouldWalkALeveragedLegDownThirtyPercentWithOrdinaryAttestations() public {
        _attest(6_400_000e6, 1);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 6_400_000e6, "first step: -20% from the anchor");
        _attest(5_600_000e6, 1);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 5_600_000e6, "second step: -30% from the anchor");
    }

    function testShouldStillRejectAJumpInOneStep() public {
        (bool ok, bytes memory reason) = _tryAttest(11_200_000e6, 1);
        assertFalse(ok, "a +40% jump is refused");
        assertEq(bytes4(reason), BIG_CHANGE, "by the relative step, not by the band");
    }
}
