// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CcipExpiredReturnFixture} from "test/crosschain/CcipExpiredReturnFixture.sol";
import {MockFaultyVault} from "test/crosschain/mocks/MockFaultyVault.sol";
import {CcipCrosschainDispatcher} from "contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipClient} from "contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "contracts/crosschain/ccip/lib/CcipMessages.sol";
import {BusinessAction} from "contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages, SweepFloor} from "contracts/crosschain/lib/CrosschainMessages.sol";

/// @title CcipExpiredReturnQueueBalanceBase
/// @notice IL-9621 (fix way 1): when `flushExpiredReturn` releases a stuck `RETURN_TRANSFER` without its tokens, the
///         balances already encoded in the responses queued behind it (`TRANSFER_SETTLED`, `RETURN_TRANSFER`,
///         `BALANCE_REPORT`, `COMMAND_ACK`) were taken net of those tokens, which now stay on the dispatcher, so each
///         grows by the released amount (shared decimals). The head itself leaves with amount 0 and the balance it was
///         queued with plus the released amount. `RETURN_REJECTED` and `COMMAND_NACK` carry no balance and stay byte
///         for byte. This suite reads the real dispatcher's queue (`queuedResponse`) before and after the release and
///         the message the router received, so it proves the helper through the host: every field, the envelope,
///         `amountLD`, the ids and the order.
/// @dev The router does not auto-deliver: token-less messages are held and nothing reaches an executor, so only the
///      dispatcher side is under test. Messages are injected as the router would deliver them. A recall request
///      carries its amount in SHARED decimals. With no tracked vault the balance a response is queued with is the
///      dispatcher's `trackedIdle` at that moment, which the expected values below use.
abstract contract CcipExpiredReturnQueueBalanceBase is CcipExpiredReturnFixture {
    bytes32 internal constant TRACKED_VAULT_UNPRICED_TOPIC = keccak256("TrackedVaultUnpriced(address,uint8)");
    uint256 internal constant UNIT = 1e18;

    uint256 private _nonce;

    // The full queue built by `_buildFullQueue` (ids are contiguous, in this order).
    uint64 internal idHead;
    uint64 internal idReport;
    uint64 internal idSettled;
    uint64 internal idAck;
    uint64 internal idNack;
    uint64 internal idRejected;
    uint64 internal idSecondReturn;
    bytes32 internal opHead;
    uint256 internal deadlineHead;

    function setUp() public {
        vm.warp(365 days);
        _expiredFixtureSetUp();
        router.setAutoDeliver(false);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev `units_` whole tokens in shared decimals.
    function _sd(uint256 units_) internal view returns (uint256) {
        return _toShared(units_ * UNIT);
    }

    function _inject(bytes memory data_, uint256 tokenAmountLD_) private {
        CcipClient.EVMTokenAmount[] memory delivered = new CcipClient.EVMTokenAmount[](tokenAmountLD_ == 0 ? 0 : 1);
        if (tokenAmountLD_ != 0) {
            token.mint(address(dispatcher), tokenAmountLD_);
            delivered[0] = CcipClient.EVMTokenAmount({token: address(token), amount: tokenAmountLD_});
        }
        vm.prank(address(router));
        dispatcher.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256(abi.encode("queue-balance", ++_nonce)),
                sourceChainSelector: EXECUTOR_SELECTOR,
                sender: abi.encode(address(executor)),
                data: data_,
                destTokenAmounts: delivered
            })
        );
    }

    function _injectOutbound(uint256 units_) internal {
        _inject(
            CcipMessages.encode(CcipMsgType.OUTBOUND_TRANSFER, abi.encode(keccak256(abi.encode("op", ++_nonce)))),
            units_ * UNIT
        );
    }

    /// @return operationId The recall's operation id.
    /// @return deadline The recall deadline carried by the request (`now + 1 day`).
    function _injectRecall(
        uint256 units_,
        uint256 minReturnSD_
    ) internal returns (bytes32 operationId, uint256 deadline) {
        operationId = keccak256(abi.encode("op", ++_nonce));
        deadline = block.timestamp + 1 days;
        _inject(
            CcipMessages.encode(
                CcipMsgType.RETURN_REQUEST,
                abi.encode(operationId, _sd(units_), type(uint128).max, minReturnSD_, deadline)
            ),
            0
        );
    }

    function _injectBalanceRequest() internal {
        _inject(CcipMessages.encode(CcipMsgType.BALANCE_REQUEST, ""), 0);
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

    /// @dev A successful `UPDATE_VAULTS` that allowlists `vaults_`: queues one `COMMAND_ACK`.
    function _injectAck(address[] memory vaults_) internal {
        _inject(_command(CcipMsgType.UPDATE_VAULTS, 0, "", abi.encode(vaults_, true, false, new SweepFloor[](0))), 0);
    }

    /// @dev A deposit into a vault that is not allowlisted: the command fails and queues one `COMMAND_NACK`.
    function _injectNack() internal {
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

    function _tail() internal view returns (uint64) {
        return dispatcher.responseQueueTail();
    }

    /// @dev Raw CCIP payload of the held (token-less) message `index_`, decoded.
    function _heldMessage(uint256 index_) internal view returns (CcipMsgType messageType, bytes memory payload) {
        (messageType, payload) = CcipMessages.decode(router.heldData(index_));
    }

    /// @dev Balance of a held `RETURN_TRANSFER` / `TRANSFER_SETTLED` / `COMMAND_ACK` message `index_`.
    function _heldBalance(uint256 index_) internal view returns (uint256 balance) {
        (CcipMsgType messageType, bytes memory payload) = _heldMessage(index_);
        if (messageType == CcipMsgType.RETURN_TRANSFER) {
            (, , balance, ) = _decodeReturn(payload);
        } else if (messageType == CcipMsgType.TRANSFER_SETTLED) {
            (, , balance, ) = _decodeSettled(payload);
        } else if (messageType == CcipMsgType.COMMAND_ACK) {
            balance = _decodeCommandAck(payload).balance;
        } else {
            (balance, ) = _decodeBalanceReport(payload);
        }
    }

    /// @dev Pushes a stuck return and every response type behind it. The queue is: stuck `RETURN_TRANSFER` of 100
    ///      (queued with balance 900), `BALANCE_REPORT` (900), `TRANSFER_SETTLED` of 50 (950), `COMMAND_ACK` (950),
    ///      `COMMAND_NACK`, `RETURN_REJECTED`, and a second `RETURN_TRANSFER` of 20 (930), all in whole tokens.
    function _buildFullQueue() internal {
        _injectOutbound(1_000); // sent at once (held by the router), trackedIdle 1000
        _blockTokenSends();
        (opHead, deadlineHead) = _injectRecall(100, 0);
        idHead = _tail();
        assertEq(dispatcher.responseQueueHead(), idHead, "stuck return holds the head");
        _injectBalanceRequest();
        idReport = _tail();
        _injectOutbound(50);
        idSettled = _tail();
        _injectAck(new address[](0));
        idAck = _tail();
        _injectNack();
        idNack = _tail();
        _injectRecall(30, type(uint256).max); // below the minimum: RETURN_REJECTED
        idRejected = _tail();
        _injectRecall(20, 0);
        idSecondReturn = _tail();
        assertEq(idSecondReturn, idHead + 6, "seven entries, contiguous ids");
        assertEq(dispatcher.trackedIdle(), _sd(1_000 - 100 + 50 - 20), "trackedIdle after the pushes");
        assertEq(dispatcher.queuedTokenAmount(), _sd(120), "two returns queued");
    }

    // ------------------------------------------------------------------ before / after checks

    function _dataAt(uint64 id_) private view returns (bytes memory data) {
        (data, , ) = dispatcher.queuedResponse(id_);
    }

    function _amountLDAt(uint64 id_) private view returns (uint256 amountLD) {
        (, , amountLD) = dispatcher.queuedResponse(id_);
    }

    /// @dev `after_` must be `before_` with exactly the balance word raised by `delta_` and re-encoded in the same
    ///      envelope; for a type without a balance it must be identical.
    function _assertRaisedOnlyTheBalance(bytes memory before_, bytes memory after_, uint256 delta_) internal {
        (CcipMsgType typeBefore, bytes memory payloadBefore) = CcipMessages.decode(before_);
        (CcipMsgType typeAfter, bytes memory payloadAfter) = CcipMessages.decode(after_);
        assertEq(uint8(typeAfter), uint8(typeBefore), "type unchanged");
        if (typeBefore == CcipMsgType.TRANSFER_SETTLED || typeBefore == CcipMsgType.RETURN_TRANSFER) {
            _assertFourWordRaised(typeBefore, payloadBefore, payloadAfter, after_, delta_);
        } else if (typeBefore == CcipMsgType.BALANCE_REPORT) {
            _assertReportRaised(payloadBefore, payloadAfter, after_, delta_);
        } else if (typeBefore == CcipMsgType.COMMAND_ACK) {
            _assertAckRaised(payloadBefore, payloadAfter, after_, delta_);
        } else {
            assertEq(after_, before_, "a type without a balance is byte for byte unchanged");
        }
    }

    function _assertFourWordRaised(
        CcipMsgType type_,
        bytes memory payloadBefore_,
        bytes memory payloadAfter_,
        bytes memory dataAfter_,
        uint256 delta_
    ) private {
        (bytes32 op0, uint256 amount0, uint256 balance0, uint64 version0) = _decodeReturn(payloadBefore_);
        (bytes32 op1, uint256 amount1, uint256 balance1, uint64 version1) = _decodeReturn(payloadAfter_);
        assertEq(op1, op0, "operation id");
        assertEq(amount1, amount0, "amount");
        assertEq(version1, version0, "version");
        assertEq(balance1, balance0 + delta_, "balance raised by exactly the released amount");
        assertEq(
            dataAfter_,
            CcipMessages.encode(type_, abi.encode(op0, amount0, balance0 + delta_, version0)),
            "envelope and layout"
        );
    }

    function _assertReportRaised(
        bytes memory payloadBefore_,
        bytes memory payloadAfter_,
        bytes memory dataAfter_,
        uint256 delta_
    ) private {
        (uint256 balance0, uint64 version0) = _decodeBalanceReport(payloadBefore_);
        (uint256 balance1, uint64 version1) = _decodeBalanceReport(payloadAfter_);
        assertEq(version1, version0, "version");
        assertEq(balance1, balance0 + delta_, "balance raised by exactly the released amount");
        assertEq(
            dataAfter_,
            CcipMessages.encode(CcipMsgType.BALANCE_REPORT, abi.encode(balance0 + delta_, version0)),
            "envelope and layout"
        );
    }

    function _assertAckRaised(
        bytes memory payloadBefore_,
        bytes memory payloadAfter_,
        bytes memory dataAfter_,
        uint256 delta_
    ) private {
        CommandAck memory ack0 = _decodeCommandAck(payloadBefore_);
        CommandAck memory ack1 = _decodeCommandAck(payloadAfter_);
        assertEq(ack1.commandId, ack0.commandId, "command id");
        assertEq(ack1.sequence, ack0.sequence, "sequence");
        assertEq(ack1.valueDelta, ack0.valueDelta, "value delta");
        assertEq(ack1.version, ack0.version, "version");
        assertEq(ack1.nextSequence, ack0.nextSequence, "next sequence");
        assertEq(ack1.status, ack0.status, "status");
        assertEq(ack1.balance, ack0.balance + delta_, "balance raised by exactly the released amount");
        ack0.balance += delta_;
        assertEq(
            dataAfter_,
            CcipMessages.encode(
                CcipMsgType.COMMAND_ACK,
                abi.encode(
                    ack0.commandId,
                    ack0.sequence,
                    ack0.valueDelta,
                    ack0.balance,
                    ack0.version,
                    ack0.nextSequence,
                    ack0.status
                )
            ),
            "envelope and layout"
        );
    }

    // ------------------------------------------------------------------ six response types behind the head

    function testShouldRaiseTheBalanceOfEachResponseTypeBehindTheReleasedHead() public {
        _buildFullQueue();
        uint64 first = idHead;
        uint64 last = idSecondReturn;
        uint256 count = uint256(last - first) + 1;
        bytes[] memory dataBefore = new bytes[](count);
        uint256[] memory amountBefore = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            dataBefore[i] = _dataAt(first + uint64(i));
            amountBefore[i] = _amountLDAt(first + uint64(i));
        }
        (CcipMsgType t, ) = _queuedPayload(idReport);
        assertEq(uint8(t), uint8(CcipMsgType.BALANCE_REPORT));
        (t, ) = _queuedPayload(idSettled);
        assertEq(uint8(t), uint8(CcipMsgType.TRANSFER_SETTLED));
        (t, ) = _queuedPayload(idAck);
        assertEq(uint8(t), uint8(CcipMsgType.COMMAND_ACK));
        (t, ) = _queuedPayload(idNack);
        assertEq(uint8(t), uint8(CcipMsgType.COMMAND_NACK));
        (t, ) = _queuedPayload(idRejected);
        assertEq(uint8(t), uint8(CcipMsgType.RETURN_REJECTED));
        (t, ) = _queuedPayload(idSecondReturn);
        assertEq(uint8(t), uint8(CcipMsgType.RETURN_TRANSFER));

        uint256 idleBefore = dispatcher.trackedIdle();
        uint256 queuedBefore = dispatcher.queuedTokenAmount();
        uint256 accountedBefore = dispatcher.accountedBalance();
        uint256 tokensBefore = token.balanceOf(address(dispatcher));
        uint64 versionBefore = dispatcher.stateVersion();
        uint256 released = _sd(100);

        vm.warp(deadlineHead + 1);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit CcipCrosschainDispatcher.ReturnExpiredUnwound(opHead, released, idHead);
        assertTrue(dispatcher.flushExpiredReturn(), "released without tokens");

        // The queue: same ids and order, the head left, nothing else moved.
        assertEq(dispatcher.responseQueueHead(), first + 1, "next entry is the head");
        assertEq(dispatcher.responseQueueTail(), last, "tail unchanged");
        for (uint256 i = 1; i < count; ++i) {
            uint64 id = first + uint64(i);
            _assertRaisedOnlyTheBalance(dataBefore[i], _dataAt(id), released);
            assertEq(_amountLDAt(id), amountBefore[i], "amountLD unchanged");
        }
        // The two types without a balance are the ones that did not change.
        assertEq(_dataAt(idNack), dataBefore[idNack - first], "COMMAND_NACK byte for byte");
        assertEq(_dataAt(idRejected), dataBefore[idRejected - first], "RETURN_REJECTED byte for byte");
        // The balances the executor will see are the real dispatcher balance, not the one net of the released tokens.
        (, uint256 reportBalance) = _queuedBalance(idReport);
        assertEq(reportBalance, _sd(1_000), "report: 900 + 100");
        (, uint256 settledBalance) = _queuedBalance(idSettled);
        assertEq(settledBalance, _sd(1_050), "settled: 950 + 100");
        (, uint256 ackBalance) = _queuedBalance(idAck);
        assertEq(ackBalance, _sd(1_050), "ack: 950 + 100");
        (, uint256 returnBalance) = _queuedBalance(idSecondReturn);
        assertEq(returnBalance, _sd(1_030), "second return: 930 + 100");

        // Ledgers: the value moves from the queue bucket to idle, nothing else changes.
        assertEq(dispatcher.trackedIdle(), idleBefore + released, "trackedIdle + amount");
        assertEq(dispatcher.queuedTokenAmount(), queuedBefore - released, "queued - amount");
        assertEq(dispatcher.trackedIdle() + dispatcher.queuedTokenAmount(), idleBefore + queuedBefore, "sum");
        assertEq(dispatcher.accountedBalance(), accountedBefore, "accountedBalance unchanged");
        assertEq(token.balanceOf(address(dispatcher)), tokensBefore, "no token left");
        assertEq(dispatcher.stateVersion(), versionBefore, "stateVersion unchanged");
    }

    function testShouldSendTheReleasedHeadWithZeroAmountAndItsQueuedBalancePlusTheAmount() public {
        _buildFullQueue();
        (, bytes memory queuedPayload) = _queuedPayload(idHead);
        (bytes32 opBefore, uint256 amountBefore, uint256 balanceBefore, uint64 versionBefore) = _decodeReturn(
            queuedPayload
        );
        assertEq(opBefore, opHead);
        assertEq(amountBefore, _sd(100), "queued amount");
        assertEq(balanceBefore, _sd(900), "queued with the balance net of its own tokens");
        // The state moved on after the head was queued: trackedIdle is now not the balance the head was queued with.
        assertTrue(dispatcher.trackedIdle() != balanceBefore, "state changed since queueing");
        uint256 sent = router.heldCount();

        vm.warp(deadlineHead + 1);
        assertTrue(dispatcher.flushExpiredReturn());

        assertEq(router.heldCount(), sent + 1, "exactly the head was sent");
        (CcipMsgType messageType, bytes memory payload) = _heldMessage(sent);
        assertEq(uint8(messageType), uint8(CcipMsgType.RETURN_TRANSFER), "same type");
        assertEq(
            router.heldData(sent),
            CcipMessages.encode(
                CcipMsgType.RETURN_TRANSFER,
                abi.encode(opHead, uint256(0), balanceBefore + _sd(100), versionBefore)
            ),
            "operation id and version kept, amount 0, balance 900 + 100"
        );
        (, uint256 amountSent, uint256 balanceSent, ) = _decodeReturn(payload);
        assertEq(amountSent, 0, "amount 0");
        assertEq(balanceSent, _sd(1_000), "queued balance plus the released amount, not the later state");
        assertTrue(balanceSent != dispatcher.trackedIdle(), "not re-read from the current state");
        assertEq(dispatcher.queuedReturnDeadline(idHead), 0, "the deadline left with the entry");
    }

    function testShouldNotReadVaultsOrEmitTrackedVaultUnpricedWhenReleasing() public {
        MockFaultyVault vault = new MockFaultyVault(IERC20(address(token)), "V", "V");
        _injectOutbound(1_000);
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        _injectAck(vaults);
        assertEq(dispatcher.trackedVaultsLength(), 1, "vault tracked");
        _blockTokenSends();
        (, uint256 deadline) = _injectRecall(100, 0);
        // A vault whose balance read reverts is unpriced every time the dispatcher values itself.
        vault.setFaults(true, false, false);
        vm.recordLogs();
        _injectBalanceRequest();
        assertTrue(_countUnpriced(vm.getRecordedLogs()) > 0, "a valuation flags the vault");

        vm.warp(deadline + 1);
        vm.recordLogs();
        assertTrue(dispatcher.flushExpiredReturn());
        assertEq(_countUnpriced(vm.getRecordedLogs()), 0, "the release reads no vault");
    }

    function _countUnpriced(Vm.Log[] memory logs_) private pure returns (uint256 count) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].topics[0] == TRACKED_VAULT_UNPRICED_TOPIC) ++count;
        }
    }

    // ------------------------------------------------------------------ report coalescing

    function testShouldNotAddTheReleasedAmountTwiceToACoalescedReport() public {
        _injectOutbound(1_000);
        _blockTokenSends();
        (, uint256 deadline) = _injectRecall(100, 0);
        _injectBalanceRequest();
        uint64 report = _tail();
        (, uint256 first) = _queuedBalance(report);
        assertEq(first, _sd(900), "queued net of the 100 in the queue");

        // Coalesced BEFORE the release: rewritten in place with the then-current balance.
        _injectOutbound(50);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit CcipCrosschainDispatcher.ResponseCoalesced(report);
        _injectBalanceRequest();
        assertEq(_tail(), report + 1, "the report was not re-queued");
        (, uint256 coalesced) = _queuedBalance(report);
        assertEq(coalesced, _sd(950), "coalesced balance");
        (, bytes memory beforePayload) = _queuedPayload(report);
        (, uint64 versionBefore) = _decodeBalanceReport(beforePayload);

        vm.warp(deadline + 1);
        assertTrue(dispatcher.flushExpiredReturn());

        (, uint256 raised) = _queuedBalance(report);
        assertEq(raised, coalesced + _sd(100), "raised once");
        assertEq(raised, dispatcher.trackedIdle(), "equals the true balance: no tokens are queued any more");
        (, bytes memory afterPayload) = _queuedPayload(report);
        (, uint64 versionAfter) = _decodeBalanceReport(afterPayload);
        assertEq(versionAfter, versionBefore, "version unchanged");

        // Coalesced AFTER the release: the fresh balance, which already includes the released tokens, replaces it.
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit CcipCrosschainDispatcher.ResponseCoalesced(report);
        _injectBalanceRequest();
        (, uint256 fresh) = _queuedBalance(report);
        assertEq(fresh, raised, "the fresh report equals the raised one (no double add)");
        assertEq(fresh, _sd(1_050), "1000 - 100 + 50 + 100");
        assertEq(_tail(), report + 1, "still one report");
    }

    // ------------------------------------------------------------------ several releases in a row

    function testShouldSumSeveralReleasesInARow() public {
        _injectOutbound(1_000);
        _blockTokenSends();
        (, uint256 deadline1) = _injectRecall(100, 0); // R1, queued balance 900
        _injectAck(new address[](0));
        uint64 ack1 = _tail(); // 900
        _injectRecall(20, 0); // R2, balance 880
        _injectOutbound(50);
        uint64 settled = _tail(); // 930
        _injectRecall(30, 0); // R3, balance 900
        _injectAck(new address[](0));
        uint64 ack2 = _tail(); // 900
        uint64 return2 = ack1 + 1;
        uint64 return3 = settled + 1;
        (, uint256 b) = _queuedBalance(ack1);
        assertEq(b, _sd(900));
        (, b) = _queuedBalance(return2);
        assertEq(b, _sd(880));
        (, b) = _queuedBalance(settled);
        assertEq(b, _sd(930));
        (, b) = _queuedBalance(return3);
        assertEq(b, _sd(900));
        (, b) = _queuedBalance(ack2);
        assertEq(b, _sd(900));
        uint256 sent = router.heldCount();
        vm.warp(deadline1 + 3); // past all three deadlines (1 second apart at most)

        // First release (100): everything behind gains 100.
        assertTrue(dispatcher.flushExpiredReturn());
        (, b) = _queuedBalance(ack1);
        assertEq(b, _sd(1_000), "ack1 + 100");
        (, b) = _queuedBalance(return2);
        assertEq(b, _sd(980), "R2 + 100");
        (, b) = _queuedBalance(settled);
        assertEq(b, _sd(1_030), "settled + 100");
        (, b) = _queuedBalance(return3);
        assertEq(b, _sd(1_000), "R3 + 100");
        (, b) = _queuedBalance(ack2);
        assertEq(b, _sd(1_000), "ack2 + 100");

        // The ack leaves; R2 is the head and is released too: the entries behind it gain its 20 on top.
        assertEq(dispatcher.flushResponse(1), 1);
        assertEq(dispatcher.responseQueueHead(), return2);
        assertTrue(dispatcher.flushExpiredReturn());
        (, b) = _queuedBalance(settled);
        assertEq(b, _sd(1_050), "settled + 100 + 20");
        (, b) = _queuedBalance(return3);
        assertEq(b, _sd(1_020), "R3 + 100 + 20");
        (, b) = _queuedBalance(ack2);
        assertEq(b, _sd(1_020), "ack2 + 100 + 20");

        // The settlement leaves; R3 is released: the last entry gains all three amounts.
        assertEq(dispatcher.flushResponse(1), 1);
        assertEq(dispatcher.responseQueueHead(), return3);
        assertTrue(dispatcher.flushExpiredReturn());
        (, b) = _queuedBalance(ack2);
        assertEq(b, _sd(1_050), "ack2 + 100 + 20 + 30");

        // What each head left with: its queued balance plus every release before it plus its own amount.
        assertEq(_heldBalance(sent), _sd(1_000), "R1: 900 + 100");
        assertEq(_heldBalance(sent + 1), _sd(1_000), "ack1: 900 + 100");
        assertEq(_heldBalance(sent + 2), _sd(1_000), "R2: 880 + 100 + 20");
        assertEq(_heldBalance(sent + 3), _sd(1_050), "settled: 930 + 100 + 20");
        assertEq(_heldBalance(sent + 4), _sd(1_050), "R3: 900 + 100 + 20 + 30");
        // The last release left the dispatcher's whole balance in the entry behind it and in the message it sent.
        assertEq(dispatcher.queuedTokenAmount(), 0, "nothing is queued as tokens any more");
        assertEq(dispatcher.trackedIdle(), _sd(1_050), "all value is idle");
        assertEq(_heldBalance(sent + 4), dispatcher.accountedBalance(), "R3 reports the dispatcher's real balance");
        (, b) = _queuedBalance(ack2);
        assertEq(b, dispatcher.accountedBalance(), "ack2 reports the real balance");
        assertEq(dispatcher.responseQueueHead(), ack2, "only the last ack is left");
    }

    // ------------------------------------------------------------------ later returns and settlements

    function testShouldQueueLaterReturnsAndSettlementsFromTheReleasedState() public {
        _injectOutbound(1_000);
        _blockTokenSends();
        (, uint256 deadline1) = _injectRecall(100, 0);
        vm.warp(deadline1 + 1);
        assertTrue(dispatcher.flushExpiredReturn());
        assertEq(dispatcher.responseQueueHead(), 0, "empty queue");
        assertEq(dispatcher.trackedIdle(), _sd(1_000), "the released tokens are idle again");

        // A later recall and a later settlement carry balances read from the released state: no stale correction.
        (, uint256 deadline2) = _injectRecall(20, 0);
        uint64 return2 = dispatcher.responseQueueHead();
        (, uint256 b) = _queuedBalance(return2);
        assertEq(b, _sd(980), "queued: 1000 - 20");
        _injectOutbound(50);
        uint64 settled = _tail();
        (, b) = _queuedBalance(settled);
        assertEq(b, _sd(1_030), "queued: 980 + 50");

        // Releasing the later return raises only what is behind it, by its own amount.
        vm.warp(deadline2 + 1);
        assertTrue(dispatcher.flushExpiredReturn());
        (, b) = _queuedBalance(settled);
        assertEq(b, _sd(1_050), "1030 + 20");
        assertEq(b, dispatcher.accountedBalance(), "the real balance");
        assertEq(dispatcher.queuedTokenAmount(), 0);
    }

    // ------------------------------------------------------------------ decimals

    function testShouldKeepAmountLdInLocalDecimalsAndBalancesInSharedDecimals() public {
        _buildFullQueue();
        uint256 factor = 10 ** (uint256(_localDecimals()) - uint256(_sharedDecimals()));
        assertEq(_amountLDAt(idHead), 100 * UNIT, "stuck return: amountLD in local decimals");
        assertEq(_amountLDAt(idSecondReturn), 20 * UNIT, "second return: amountLD in local decimals");
        assertEq(_amountLDAt(idReport) + _amountLDAt(idSettled), 0, "neutral entries carry no tokens");
        (, bytes memory payload) = _queuedPayload(idHead);
        (, uint256 amountSD, , ) = _decodeReturn(payload);
        assertEq(amountSD * factor, 100 * UNIT, "payload amount in shared decimals");

        vm.warp(deadlineHead + 1);
        assertTrue(dispatcher.flushExpiredReturn());

        // The raise is in shared decimals; `amountLD` of the entry behind is untouched.
        assertEq(_amountLDAt(idSecondReturn), 20 * UNIT, "amountLD unchanged");
        (, uint256 balance) = _queuedBalance(idSecondReturn);
        assertEq(balance, (1_030 * UNIT) / factor, "balance 930 + 100 in shared decimals");
        assertEq(dispatcher.queuedTokenAmount() * factor, 20 * UNIT, "ledger in shared decimals");
        assertEq(dispatcher.trackedIdle() * factor, 1_030 * UNIT, "idle in shared decimals");
    }
}

/// @notice The suite with local and shared decimals equal (18).
contract CcipExpiredReturnQueueBalanceTest is CcipExpiredReturnQueueBalanceBase {}

/// @notice The suite with local decimals 18 and shared decimals 6 (`amountLD` is the amount times 1e12).
contract CcipExpiredReturnQueueBalanceSharedSixTest is CcipExpiredReturnQueueBalanceBase {
    function _sharedDecimals() internal pure override returns (uint8) {
        return 6;
    }
}
