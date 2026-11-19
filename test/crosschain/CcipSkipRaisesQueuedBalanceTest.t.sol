// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CcipExpiredReturnFixture} from "test/crosschain/CcipExpiredReturnFixture.sol";
import {CcipCrosschainDispatcher} from "contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipClient} from "contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "contracts/crosschain/ccip/lib/CcipMessages.sol";
import {BusinessAction, CcipChainRescue} from "contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages, SweepFloor} from "contracts/crosschain/lib/CrosschainMessages.sol";

/// @title CcipSkipRaisesQueuedBalanceTest
/// @notice IL-9621 (K6): the administrative skip of a token-bearing queue head (`scheduleSkipStuckResponse` /
///         `executeSkipStuckResponse`) leaves the dropped tokens on the dispatcher, so every response queued behind it
///         that carries a dispatcher balance has that balance raised by the dropped amount in the same transaction
///         (IL-9146 closed in code). A skip of a head without tokens and the pool-capacity unwind change nothing.
/// @dev Shared decimals are 6 (local 18), so the queued amounts (shared decimals) differ from the token amounts.
contract CcipSkipRaisesQueuedBalanceTest is CcipExpiredReturnFixture {
    error TokenMaxCapacityExceeded(uint256 capacity, uint256 requested, address tokenAddress);

    uint256 internal constant UNIT = 1e18;
    uint256 internal constant UNIT_SD = 1e6;

    uint256 private _nonce;

    function _sharedDecimals() internal pure override returns (uint8) {
        return 6;
    }

    function setUp() public {
        vm.warp(365 days);
        _expiredFixtureSetUp();
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Delivers a message from the executor to the dispatcher as the router would.
    function _inject(bytes memory data_, uint256 tokenAmount_) private {
        CcipClient.EVMTokenAmount[] memory delivered = new CcipClient.EVMTokenAmount[](tokenAmount_ == 0 ? 0 : 1);
        if (tokenAmount_ != 0) {
            token.mint(address(dispatcher), tokenAmount_);
            delivered[0] = CcipClient.EVMTokenAmount({token: address(token), amount: tokenAmount_});
        }
        vm.prank(address(router));
        dispatcher.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256(abi.encode("skip-raise", ++_nonce)),
                sourceChainSelector: EXECUTOR_SELECTOR,
                sender: abi.encode(address(executor)),
                data: data_,
                destTokenAmounts: delivered
            })
        );
    }

    /// @dev An inbound transfer of `amountLD_` tokens: queues one `TRANSFER_SETTLED`.
    function _injectOutbound(uint256 amountLD_) private {
        _inject(
            CcipMessages.encode(CcipMsgType.OUTBOUND_TRANSFER, abi.encode(keccak256(abi.encode("op", ++_nonce)))),
            amountLD_
        );
    }

    /// @dev A balance request: queues one `BALANCE_REPORT`.
    function _injectBalanceRequest() private {
        _inject(CcipMessages.encode(CcipMsgType.BALANCE_REQUEST, ""), 0);
    }

    /// @dev An empty `UPDATE_VAULTS` command: queues one `COMMAND_ACK`.
    function _injectAck() private {
        _inject(
            _command(CcipMsgType.UPDATE_VAULTS, 0, "", abi.encode(new address[](0), true, false, new SweepFloor[](0))),
            0
        );
    }

    /// @dev A deposit into a vault that is not allowlisted: the command fails and queues one `COMMAND_NACK`.
    function _injectNack() private {
        _inject(
            _command(
                CcipMsgType.COMMAND,
                uint8(BusinessAction.DEPOSIT),
                CrosschainMessages.encodeDepositAction(address(0xDEAD), 1e18, 0),
                ""
            ),
            0
        );
    }

    /// @dev A recall request (amount in shared decimals) that the dispatcher answers with a `RETURN_TRANSFER`.
    function _injectRecall(uint256 amountSD_) private {
        _inject(
            CcipMessages.encode(
                CcipMsgType.RETURN_REQUEST,
                abi.encode(
                    keccak256(abi.encode("recall", ++_nonce)),
                    amountSD_,
                    type(uint128).max,
                    uint256(1),
                    type(uint256).max
                )
            ),
            0
        );
    }

    /// @dev A recall request with an unreachable minimum: answered with a `RETURN_REJECTED` (no balance field).
    function _injectRejectedRecall() private {
        _inject(
            CcipMessages.encode(
                CcipMsgType.RETURN_REQUEST,
                abi.encode(
                    keccak256(abi.encode("recall", ++_nonce)),
                    uint256(UNIT),
                    type(uint128).max,
                    type(uint256).max,
                    type(uint256).max
                )
            ),
            0
        );
    }

    function _command(
        CcipMsgType type_,
        uint8 action_,
        bytes memory actionData_,
        bytes memory extra_
    ) private returns (bytes memory) {
        return
            CcipMessages.encode(
                type_,
                abi.encode(
                    type_,
                    Command({
                        commandId: bytes32(((block.timestamp + 1 days) << 192) | ++_nonce),
                        sequence: dispatcher.nextCommandSequence(),
                        commandConfigEpoch: dispatcher.commandConfigEpoch(),
                        action: action_,
                        minExecutionGas: 0,
                        actionData: actionData_
                    }),
                    extra_
                )
            );
    }

    function _skip(uint64 responseId_) private {
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = dispatcher.scheduleSkipStuckResponse(responseId_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        dispatcher.executeSkipStuckResponse(rescueId, responseId_);
    }

    function _raw(uint64 id_) private view returns (bytes memory data, uint256 amountLD) {
        (data, , amountLD) = dispatcher.queuedResponse(id_);
    }

    /// @dev What the entry `id_` must encode after its carried balance rose by `raiseSD_`, built independently of the
    ///      library: the same envelope with only the balance field changed (types without a balance stay as they are).
    function _expectedRaised(bytes memory before_, uint256 raiseSD_) private pure returns (bytes memory) {
        (CcipMsgType messageType, bytes memory payload) = CcipMessages.decode(before_);
        if (messageType == CcipMsgType.RETURN_TRANSFER || messageType == CcipMsgType.TRANSFER_SETTLED) {
            (bytes32 operationId, uint256 amount, uint256 balance, uint64 version) = abi.decode(
                payload,
                (bytes32, uint256, uint256, uint64)
            );
            return CcipMessages.encode(messageType, abi.encode(operationId, amount, balance + raiseSD_, version));
        }
        if (messageType == CcipMsgType.BALANCE_REPORT) {
            (uint256 balance, uint64 version) = abi.decode(payload, (uint256, uint64));
            return CcipMessages.encode(messageType, abi.encode(balance + raiseSD_, version));
        }
        if (messageType == CcipMsgType.COMMAND_ACK) {
            CommandAck memory ack = _decodeCommandAck(payload);
            return
                CcipMessages.encode(
                    messageType,
                    abi.encode(
                        ack.commandId,
                        ack.sequence,
                        ack.valueDelta,
                        ack.balance + raiseSD_,
                        ack.version,
                        ack.nextSequence,
                        ack.status
                    )
                );
        }
        return before_;
    }

    /// @dev Bridges 100 tokens in, so that the dispatcher tracks 100 idle, and stalls every token-bearing send.
    function _bridgeAndBlock() private {
        _bridge(100 * UNIT);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(100 * UNIT);
        assertEq(dispatcher.trackedIdle(), 100 * UNIT_SD, "100 tracked idle");
        _blockTokenSends();
    }

    // ------------------------------------------------------------------ K6: skip of a token-bearing head

    function testShouldRaiseEveryBalanceBehindASkippedTokenBearingHead() public {
        _bridgeAndBlock();
        _recall(60 * UNIT);
        uint64 head = dispatcher.responseQueueHead();

        // One entry of every type behind the stuck head.
        _injectOutbound(10 * UNIT); // head + 1: TRANSFER_SETTLED
        _injectBalanceRequest(); // head + 2: BALANCE_REPORT
        _injectAck(); // head + 3: COMMAND_ACK
        _injectRecall(20 * UNIT_SD); // head + 4: RETURN_TRANSFER (token-bearing, queued behind the head)
        _injectRejectedRecall(); // head + 5: RETURN_REJECTED
        _injectNack(); // head + 6: COMMAND_NACK
        assertEq(dispatcher.responseQueueTail(), head + 6, "six entries behind the head");
        _assertTypesBehind(head);

        uint256 dropped = 60 * UNIT_SD;
        assertEq(dispatcher.queuedTokenAmount(), dropped + 20 * UNIT_SD, "head and the later recall hold tokens");
        uint256 idleBefore = dispatcher.trackedIdle();
        uint256 accountedBefore = dispatcher.accountedBalance();

        bytes[6] memory dataBefore;
        uint256[6] memory amountLDBefore;
        for (uint64 i = 1; i <= 6; ++i) {
            (dataBefore[i - 1], amountLDBefore[i - 1]) = _raw(head + i);
        }

        _skip(head);

        // Ledgers: the dropped value is idle again, the queue bucket keeps only the later recall.
        assertEq(dispatcher.trackedIdle(), idleBefore + dropped, "dropped value back in idle");
        assertEq(dispatcher.queuedTokenAmount(), 20 * UNIT_SD, "only the later recall still queued");
        assertEq(dispatcher.accountedBalance(), accountedBefore, "accounted balance unchanged by the skip");
        assertEq(dispatcher.responseQueueHead(), head + 1, "queue advanced past the dropped head");
        assertEq(dispatcher.responseQueueTail(), head + 6, "tail unchanged");

        for (uint64 i = 1; i <= 6; ++i) {
            _assertEntryRaised(head + i, dataBefore[i - 1], amountLDBefore[i - 1], dropped, i <= 4);
        }
    }

    function _assertTypesBehind(uint64 head_) private view {
        CcipMsgType[6] memory expected = [
            CcipMsgType.TRANSFER_SETTLED,
            CcipMsgType.BALANCE_REPORT,
            CcipMsgType.COMMAND_ACK,
            CcipMsgType.RETURN_TRANSFER,
            CcipMsgType.RETURN_REJECTED,
            CcipMsgType.COMMAND_NACK
        ];
        for (uint64 i = 1; i <= 6; ++i) {
            (CcipMsgType messageType, ) = _queuedPayload(head_ + i);
            assertEq(uint8(messageType), uint8(expected[i - 1]), "entry type");
        }
    }

    /// @dev The entry holds exactly `_expectedRaised` (balance field + dropped, everything else as before) and keeps
    ///      its token amount; entries with a balance really changed, the others are byte for byte what they were.
    function _assertEntryRaised(
        uint64 id_,
        bytes memory before_,
        uint256 amountLDBefore_,
        uint256 dropped_,
        bool carriesBalance_
    ) private view {
        (bytes memory dataAfter, uint256 amountLDAfter) = _raw(id_);
        assertEq(dataAfter, _expectedRaised(before_, dropped_), "entry raised by exactly the dropped amount");
        assertEq(amountLDAfter, amountLDBefore_, "token amount of the entry untouched");
        assertEq(keccak256(dataAfter) != keccak256(before_), carriesBalance_, "changed iff it carries a balance");
    }

    // ------------------------------------------------------------------ K6: head without tokens

    function testShouldRaiseNothingWhenTheSkippedHeadCarriesNoTokens() public {
        _bridgeAndBlock();
        _unblockSends();
        // Every send fails, so a token-less report stays at the head.
        router.setFailSend(address(dispatcher), true);
        _injectBalanceRequest();
        uint64 head = dispatcher.responseQueueHead();
        (, uint256 headAmountLD) = _raw(head);
        assertEq(headAmountLD, 0, "the head carries no tokens");

        _injectOutbound(10 * UNIT);
        _injectRecall(20 * UNIT_SD);
        _injectAck();
        uint64 tail = dispatcher.responseQueueTail();
        assertEq(tail, head + 3, "three entries behind the head");

        bytes[3] memory dataBefore;
        for (uint64 i = 1; i <= 3; ++i) (dataBefore[i - 1], ) = _raw(head + i);
        uint256 idleBefore = dispatcher.trackedIdle();
        uint256 queuedBefore = dispatcher.queuedTokenAmount();
        assertEq(queuedBefore, 20 * UNIT_SD, "the later recall holds tokens");

        _skip(head);

        for (uint64 i = 1; i <= 3; ++i) {
            (bytes memory dataAfter, ) = _raw(head + i);
            assertEq(dataAfter, dataBefore[i - 1], "entry untouched by the skip of a token-less head");
        }
        assertEq(dispatcher.trackedIdle(), idleBefore, "idle unchanged");
        assertEq(dispatcher.queuedTokenAmount(), queuedBefore, "queue bucket unchanged");
        assertEq(dispatcher.responseQueueHead(), head + 1, "head advanced");
    }

    // ------------------------------------------------------------------ K6: pool-capacity unwind

    function testShouldRaiseNothingInThePoolCapacityUnwind() public {
        _bridgeAndBlock();
        router.setFailSendWith(
            address(dispatcher),
            abi.encodeWithSelector(TokenMaxCapacityExceeded.selector, 5 * UNIT, 60 * UNIT, address(token))
        );
        uint256 idleBefore = dispatcher.trackedIdle();
        uint64 versionBefore = dispatcher.stateVersion();
        uint64 tailBefore = dispatcher.responseQueueTail();

        // The recall is the sole queue entry, so the unwind drops the tail: nothing is behind it.
        _recall(60 * UNIT);

        assertEq(dispatcher.trackedIdle(), idleBefore, "debit undone, nothing raised");
        assertEq(dispatcher.queuedTokenAmount(), 0, "queue bucket empty");
        assertEq(dispatcher.stateVersion(), versionBefore, "no version consumed");
        assertEq(dispatcher.accountedBalance(), 100 * UNIT_SD, "accounted balance unchanged");
        assertEq(dispatcher.responseQueueHead(), 0, "queue drained: the rejection left at once");
        assertEq(dispatcher.responseQueueTail(), tailBefore + 2, "the dropped id and the rejection id were used");
    }

    // ------------------------------------------------------------------ K6: IL-9146 anchor after a skip

    /// @dev The IL-9146 / Codex M1 scenario with the skip as the exit: `settled` 100, the dispatcher holds 110, R1 = 10
    ///      is stuck and cancelled, R2 = 100 queues behind it. After the skip of R1 and the repair of the skipped
    ///      version, R2 reports the balance it was queued with raised by R1, so the residual 10 anchors the next
    ///      ordinary attestation. Without the raise R2 reports 0 and the attestation is unanchored.
    function testShouldAnchorTheResidualWhenALaterReturnEmptiesSettledAfterASkip() public {
        _bridge(110 * UNIT);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(100 * UNIT);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100 * UNIT_SD, "settled 100");
        assertEq(dispatcher.trackedIdle(), 110 * UNIT_SD, "trackedIdle 110");

        _blockTokenSends();
        _recall(10 * UNIT);
        uint64 r1 = dispatcher.responseQueueHead();
        executor.cancelPendingReturn(REMOTE_CHAIN);
        vm.warp(block.timestamp + 1);
        _recall(100 * UNIT);
        uint64 r2 = r1 + 1;
        (, uint256 queuedBalance) = _queuedBalance(r2);
        assertEq(queuedBalance, 0, "R2 queued with nothing left");

        _skip(r1);

        // The balance behind the dropped head rose by the dropped amount.
        (, queuedBalance) = _queuedBalance(r2);
        assertEq(queuedBalance, 10 * UNIT_SD, "R2 raised by the dropped 10");
        assertEq(dispatcher.responseQueueHead(), r2, "R2 is the head");

        // The skipped version is a gap at the executor: repair it, then R2 leaves with its tokens.
        _unblockSends();
        uint256 lostVersion = uint256(dispatcher.stateVersion()) - 1;
        vm.prank(RESCUE_ADMIN);
        uint256 repairId = executor.scheduleChainRescue(CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, lostVersion);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(repairId, CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, lostVersion);
        dispatcher.flushResponse();

        assertEq(dispatcher.responseQueueHead(), 0, "queue empty");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "R2 debited the whole settled value");
        assertEq(executor.idleLedger(), 100 * UNIT_SD, "R2 tokens are home");
        assertEq(dispatcher.accountedBalance(), 10 * UNIT_SD, "the 10 surplus stays on the dispatcher");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 10 * UNIT_SD, "anchor is the 10 residual");

        // An ordinary positive attestation of the residual passes (it also lifts the repair block).
        _attest(10 * UNIT);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 10 * UNIT_SD, "residual attested");
    }

    // ------------------------------------------------------------------ K6: release interleaved with a skip

    /// @dev Three recalls R1 < R2 < R3 are stuck. A skip is scheduled for R1; before it can run, R1 is released
    ///      (`flushExpiredReturn`), so the skip hits `NoQueuedResponse` and has to be cancelled. A skip of the new
    ///      head R2 then raises R3 on top of the release raise: R3 ends up 10 (R1) + 20 (R2) above its queued balance.
    function testShouldHitNoQueuedResponseForASkipScheduledOnAReleasedEntryAndStackRaises() public {
        _bridgeAndBlock();
        uint256 deadline1 = _recall(10 * UNIT);
        uint64 r1 = dispatcher.responseQueueHead();
        executor.cancelPendingReturn(REMOTE_CHAIN);
        vm.warp(block.timestamp + 1);
        _recall(20 * UNIT);
        uint64 r2 = r1 + 1;
        executor.cancelPendingReturn(REMOTE_CHAIN);
        vm.warp(block.timestamp + 1);
        _recall(30 * UNIT);
        uint64 r3 = r2 + 1;
        assertEq(dispatcher.responseQueueTail(), r3, "three recalls queued");
        (, uint256 r2Queued) = _queuedBalance(r2);
        (, uint256 r3Queued) = _queuedBalance(r3);

        // A skip of R1 is scheduled, but R1 is released first (the deadline passes before the rescue delay).
        vm.prank(RESCUE_ADMIN);
        uint256 skipR1 = dispatcher.scheduleSkipStuckResponse(r1);
        vm.warp(deadline1 + 1);
        assertTrue(dispatcher.flushExpiredReturn(), "R1 released without tokens");
        assertEq(dispatcher.responseQueueHead(), r2, "R2 is the head");
        (, uint256 balance) = _queuedBalance(r2);
        assertEq(balance, r2Queued + 10 * UNIT_SD, "release raised R2 by R1");
        (, balance) = _queuedBalance(r3);
        assertEq(balance, r3Queued + 10 * UNIT_SD, "release raised R3 by R1");

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(CcipCrosschainDispatcher.NoQueuedResponse.selector);
        dispatcher.executeSkipStuckResponse(skipR1, r1);
        vm.prank(RESCUE_ADMIN);
        dispatcher.cancelRescue(skipR1);

        // The skip of the new head R2 stacks its raise on the release raise.
        uint256 idleBefore = dispatcher.trackedIdle();
        _skip(r2);
        (, balance) = _queuedBalance(r3);
        assertEq(balance, r3Queued + 30 * UNIT_SD, "R3 raised by R1 (release) and R2 (skip)");
        assertEq(dispatcher.trackedIdle(), idleBefore + 20 * UNIT_SD, "R2 value back in idle");
        assertEq(dispatcher.queuedTokenAmount(), 30 * UNIT_SD, "only R3 still queued");
        assertEq(dispatcher.responseQueueHead(), r3, "R3 is the head");
    }
}
