// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CcipExpiredReturnFixture} from "test/crosschain/CcipExpiredReturnFixture.sol";
import {CcipMsgType} from "contracts/crosschain/ccip/lib/CcipMessages.sol";

/// @title CcipExpiredReturnLaterReturnAnchorTest
/// @notice IL-9621 (Codex M1): a recall return released by `flushExpiredReturn` must not leave the balances
///         encoded in the responses queued behind it understated. The scenario: 10 units of dispatcher surplus
///         that was never attested (`settled` 100, dispatcher holds 110), R1 = 10 is stuck on a token-bearing
///         send and cancelled, R2 = 100 queues behind it. After R1 is released without tokens, R2 is sent and
///         reports the balance it was queued with. The residual 10 must become the attestation anchor, so an
///         ordinary positive attestation of it passes.
/// @dev Shared decimals are 6 (local 18); attestation proposals are in local units. Every amount is far above `ATTESTATION_ZERO_DUST_SD` (10_000).
contract CcipExpiredReturnLaterReturnAnchorTest is CcipExpiredReturnFixture {
    uint256 internal constant UNIT = 1e18;
    uint256 internal constant UNIT_SD = 1e6;

    function _sharedDecimals() internal pure override returns (uint8) {
        return 6;
    }

    function setUp() public {
        vm.warp(365 days);
        _expiredFixtureSetUp();
    }

    function testShouldAnchorTheResidualWhenALaterReturnIsSentAfterAReleasedReturn() public {
        // Input state: the dispatcher holds 110, 100 of it attested.
        _bridge(110 * UNIT);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(100 * UNIT);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100 * UNIT_SD, "settled 100");
        assertEq(dispatcher.trackedIdle(), 110 * UNIT_SD, "trackedIdle 110");
        assertEq(dispatcher.accountedBalance(), 110 * UNIT_SD, "10 of unattested surplus");

        // R1 = 10 is stuck (rate limit) and cancelled locally; R2 = 100 queues behind it.
        _blockTokenSends();
        uint256 deadline1 = _recall(10 * UNIT);
        uint64 r1 = dispatcher.responseQueueHead();
        executor.cancelPendingReturn(REMOTE_CHAIN);
        vm.warp(block.timestamp + 1);
        _recall(100 * UNIT);
        uint64 r2 = r1 + 1;
        assertEq(dispatcher.responseQueueTail(), r2, "R2 queued behind R1");

        (CcipMsgType type1, bytes memory payload1) = _queuedPayload(r1);
        assertEq(uint8(type1), uint8(CcipMsgType.RETURN_TRANSFER));
        (, uint256 amount1, uint256 balance1, ) = _decodeReturn(payload1);
        assertEq(amount1, 10 * UNIT_SD, "R1 amount");
        assertEq(balance1, 100 * UNIT_SD, "R1 queued with 100 left");
        (CcipMsgType type2, bytes memory payload2) = _queuedPayload(r2);
        assertEq(uint8(type2), uint8(CcipMsgType.RETURN_TRANSFER));
        (, uint256 amount2, uint256 balance2, ) = _decodeReturn(payload2);
        assertEq(amount2, 100 * UNIT_SD, "R2 amount");
        assertEq(balance2, 0, "R2 queued with nothing left");

        // R1 is released without its tokens; R2 then leaves with its tokens.
        vm.warp(deadline1 + 1);
        assertTrue(dispatcher.flushExpiredReturn(), "R1 released");
        assertEq(dispatcher.responseQueueHead(), r2, "R2 is the head");
        _unblockSends();
        dispatcher.flushResponse();

        assertEq(dispatcher.responseQueueHead(), 0, "queue empty");
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), 3, "both returns applied in order");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "R2 debited the whole settled value");
        assertEq(executor.idleLedger(), 100 * UNIT_SD, "R2 tokens are home");
        assertEq(dispatcher.accountedBalance(), 10 * UNIT_SD, "the 10 surplus stays on the dispatcher");

        // Expected after the fix: the anchor follows the dispatcher's real residual.
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 10 * UNIT_SD, "anchor is the 10 residual");

        // An ordinary positive attestation of the residual passes.
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(10 * UNIT);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 10 * UNIT_SD, "residual attested");
    }
}
