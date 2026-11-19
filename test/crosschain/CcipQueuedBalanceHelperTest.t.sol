// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, stdError} from "forge-std/Test.sol";

import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipQueuedResponseHarness} from "./mocks/CcipQueuedResponseHarness.sol";

/// @title CcipQueuedBalanceHelperTest
/// @notice IL-9621: the response-queue balance helper of `CcipDispatcherLib` (`raiseQueuedBalances`,
///         `unwindQueuedReturn`), run through `CcipQueuedResponseHarness` on a queue of its own. Every result is
///         compared byte for byte with an envelope the test encodes itself (wire version, raw type numbers and payload
///         layouts pinned here, independently of the library), and word by word with the stored bytes before the call:
///         exactly the balance word of `TRANSFER_SETTLED`, `RETURN_TRANSFER`, `BALANCE_REPORT` and `COMMAND_ACK` grows by
///         the amount, `RETURN_REJECTED`, `COMMAND_NACK`, other types and entries outside the range stay as they were,
///         and no `amountLD` / `returnDeadline` moves except the released head's `amountLD`.
contract CcipQueuedBalanceHelperTest is Test {
    /// @dev Wire values the expected envelopes are built with; `testShouldPinTheWireValuesTheTestEncodesWith` ties
    ///      them to `CcipMessages` once.
    uint8 internal constant WIRE_VERSION = 4;
    uint8 internal constant OUTBOUND_TRANSFER = 1;
    uint8 internal constant TRANSFER_SETTLED = 2;
    uint8 internal constant RETURN_TRANSFER = 4;
    uint8 internal constant COMMAND_ACK = 6;
    uint8 internal constant COMMAND_NACK = 7;
    uint8 internal constant BALANCE_REPORT = 14;
    uint8 internal constant RETURN_REJECTED = 15;

    /// @dev Envelope `abi.encode(uint8 version, uint8 type, bytes payload)`: version, type, payload offset and payload
    ///      length come before the first payload word.
    uint256 internal constant ENVELOPE_HEAD_WORDS = 4;
    /// @dev Index, in envelope words, of the balance of each type that carries one.
    uint256 internal constant SETTLED_BALANCE_WORD = ENVELOPE_HEAD_WORDS + 2;
    uint256 internal constant REPORT_BALANCE_WORD = ENVELOPE_HEAD_WORDS;
    uint256 internal constant ACK_BALANCE_WORD = ENVELOPE_HEAD_WORDS + 3;
    /// @dev Index, in envelope words, of a `RETURN_TRANSFER` amount.
    uint256 internal constant RETURN_AMOUNT_WORD = ENVELOPE_HEAD_WORDS + 1;

    /// @dev Released amount, shared decimals (6), and the local-decimals factor of an 18-decimal asset.
    uint256 internal constant AMOUNT_SD = 7_500_000;
    uint256 internal constant RATE = 1e12;

    CcipQueuedResponseHarness internal harness;

    function setUp() public {
        harness = new CcipQueuedResponseHarness();
    }

    // ------------------------------------------------------------------ wire values

    function testShouldPinTheWireValuesTheTestEncodesWith() public pure {
        assertEq(uint256(CcipMessages.VERSION), WIRE_VERSION, "version");
        assertEq(uint256(CcipMsgType.OUTBOUND_TRANSFER), OUTBOUND_TRANSFER, "OUTBOUND_TRANSFER");
        assertEq(uint256(CcipMsgType.TRANSFER_SETTLED), TRANSFER_SETTLED, "TRANSFER_SETTLED");
        assertEq(uint256(CcipMsgType.RETURN_TRANSFER), RETURN_TRANSFER, "RETURN_TRANSFER");
        assertEq(uint256(CcipMsgType.COMMAND_ACK), COMMAND_ACK, "COMMAND_ACK");
        assertEq(uint256(CcipMsgType.COMMAND_NACK), COMMAND_NACK, "COMMAND_NACK");
        assertEq(uint256(CcipMsgType.BALANCE_REPORT), BALANCE_REPORT, "BALANCE_REPORT");
        assertEq(uint256(CcipMsgType.RETURN_REJECTED), RETURN_REJECTED, "RETURN_REJECTED");
        // The independent encoding equals the production one.
        bytes memory payload = _balanceReport(123, 4);
        assertEq(
            _envelope(BALANCE_REPORT, payload),
            CcipMessages.encode(CcipMsgType.BALANCE_REPORT, payload),
            "envelope"
        );
    }

    // ------------------------------------------------------------------ raiseQueuedBalances

    function testShouldRaiseTheBalanceOfEachBalanceCarryingTypeAndLeaveTheRestByteForByte() public {
        _writeSixTypes(21);
        // Outside the range, both carrying a balance.
        _write(20, _envelope(BALANCE_REPORT, _balanceReport(900, 3)));
        _write(27, _envelope(TRANSFER_SETTLED, _settled(keccak256("after"), 11, 950, 12)));
        bytes[] memory before = _snapshot(20, 27);

        harness.raiseQueuedBalances(21, 26, AMOUNT_SD);

        _assertData(21, _envelope(TRANSFER_SETTLED, _settled(keccak256("settled"), 1_000, 5_000 + AMOUNT_SD, 7)));
        _assertData(22, _envelope(RETURN_TRANSFER, _settled(keccak256("return"), 2_000, 6_000 + AMOUNT_SD, 8)));
        _assertData(23, _envelope(BALANCE_REPORT, _balanceReport(7_000 + AMOUNT_SD, 8)));
        _assertData(24, _envelope(COMMAND_ACK, _commandAck(keccak256("ack"), 5, -12_345, 8_000 + AMOUNT_SD, 8, 3, 2)));
        _assertOnlyWordRaised(21, before[1], SETTLED_BALANCE_WORD, AMOUNT_SD);
        _assertOnlyWordRaised(22, before[2], SETTLED_BALANCE_WORD, AMOUNT_SD);
        _assertOnlyWordRaised(23, before[3], REPORT_BALANCE_WORD, AMOUNT_SD);
        _assertOnlyWordRaised(24, before[4], ACK_BALANCE_WORD, AMOUNT_SD);
        // No balance: byte for byte.
        _assertData(25, before[5]);
        _assertData(26, before[6]);
        // Outside the range: byte for byte.
        _assertData(20, before[0]);
        _assertData(27, before[7]);
        _assertFieldsUnchanged(20, 27);
    }

    function testShouldLeaveATypeTheDispatcherDoesNotQueueUntouched() public {
        // Shaped like a TRANSFER_SETTLED payload, but no queued response of this type exists: not a balance.
        _write(1, _envelope(OUTBOUND_TRANSFER, _settled(keccak256("outbound"), 1, 2, 3)));
        _write(2, _envelope(BALANCE_REPORT, _balanceReport(10, 1)));
        bytes[] memory before = _snapshot(1, 2);

        harness.raiseQueuedBalances(1, 2, AMOUNT_SD);

        _assertData(1, before[0]);
        _assertOnlyWordRaised(2, before[1], REPORT_BALANCE_WORD, AMOUNT_SD);
        _assertFieldsUnchanged(1, 2);
    }

    function testShouldDoNothingForAnEmptyRange() public {
        _writeSixTypes(21);
        bytes[] memory before = _snapshot(21, 26);

        harness.raiseQueuedBalances(26, 25, AMOUNT_SD);
        harness.raiseQueuedBalances(type(uint64).max, 0, AMOUNT_SD);
        // An empty range reads nothing: never-written ids do not revert.
        harness.raiseQueuedBalances(600, 500, AMOUNT_SD);

        for (uint64 id = 21; id <= 26; ++id) _assertData(id, before[id - 21]);
        _assertFieldsUnchanged(21, 26);
    }

    function testShouldDoNothingForAZeroAmount() public {
        _writeSixTypes(21);
        bytes[] memory before = _snapshot(21, 26);

        harness.raiseQueuedBalances(21, 26, 0);
        // A zero amount reads nothing: never-written ids do not revert.
        harness.raiseQueuedBalances(500, 600, 0);

        for (uint64 id = 21; id <= 26; ++id) _assertData(id, before[id - 21]);
        _assertFieldsUnchanged(21, 26);
    }

    function testShouldStopAtTheLastPossibleId() public {
        uint64 maxId = type(uint64).max;
        _write(maxId - 1, _envelope(BALANCE_REPORT, _balanceReport(10, 1)));
        _write(maxId, _envelope(BALANCE_REPORT, _balanceReport(20, 1)));

        harness.raiseQueuedBalances(maxId - 1, maxId, AMOUNT_SD);

        _assertData(maxId - 1, _envelope(BALANCE_REPORT, _balanceReport(10 + AMOUNT_SD, 1)));
        _assertData(maxId, _envelope(BALANCE_REPORT, _balanceReport(20 + AMOUNT_SD, 1)));
        _assertFieldsUnchanged(maxId - 1, maxId - 1);

        // A head at the last possible id is also the last id: the release raises nothing behind it.
        bytes32 operationId = keccak256("max");
        _writeEntry(maxId, _envelope(RETURN_TRANSFER, _settled(operationId, AMOUNT_SD, 0, 2)), AMOUNT_SD * RATE, 1);

        harness.unwindQueuedReturn(maxId, maxId);

        _assertData(maxId, _envelope(RETURN_TRANSFER, _settled(operationId, 0, AMOUNT_SD, 2)));
    }

    function testShouldRevertOnADeletedEntryInsideTheRange() public {
        _write(1, _envelope(BALANCE_REPORT, _balanceReport(10, 1)));
        // Id 2 was never written (a deleted entry reads the same): the envelope decode reverts without data.
        vm.expectRevert(bytes(""));
        harness.raiseQueuedBalances(1, 2, AMOUNT_SD);
    }

    function testShouldRevertOnAnEntryOfAnotherWireVersion() public {
        _write(1, abi.encode(uint8(WIRE_VERSION - 1), BALANCE_REPORT, _balanceReport(10, 1)));
        vm.expectRevert(abi.encodeWithSelector(CcipMessages.InvalidVersion.selector, uint8(WIRE_VERSION - 1)));
        harness.raiseQueuedBalances(1, 1, AMOUNT_SD);
    }

    function testShouldRevertOnABalanceOverflow() public {
        _write(1, _envelope(BALANCE_REPORT, _balanceReport(type(uint256).max, 1)));
        vm.expectRevert(stdError.arithmeticError);
        harness.raiseQueuedBalances(1, 1, 1);
    }

    function testFuzzShouldRaiseEachBalanceCarryingTypeByTheAmount(
        uint256 balance_,
        uint256 amount_,
        int256 delta_,
        uint64 version_
    ) public {
        amount_ = bound(amount_, 0, type(uint256).max);
        balance_ = bound(balance_, 0, type(uint256).max - amount_);
        bytes32 operationId = keccak256(abi.encode(balance_, amount_));
        _write(1, _envelope(TRANSFER_SETTLED, _settled(operationId, amount_, balance_, version_)));
        _write(2, _envelope(RETURN_TRANSFER, _settled(operationId, balance_, balance_, version_)));
        _write(3, _envelope(BALANCE_REPORT, _balanceReport(balance_, version_)));
        _write(4, _envelope(COMMAND_ACK, _commandAck(operationId, version_, delta_, balance_, version_, version_, 1)));
        _write(5, _envelope(RETURN_REJECTED, abi.encode(operationId, uint8(3))));
        _write(6, _envelope(COMMAND_NACK, abi.encode(operationId, version_)));
        bytes[] memory before = _snapshot(1, 6);

        harness.raiseQueuedBalances(1, 6, amount_);

        _assertData(1, _envelope(TRANSFER_SETTLED, _settled(operationId, amount_, balance_ + amount_, version_)));
        _assertData(2, _envelope(RETURN_TRANSFER, _settled(operationId, balance_, balance_ + amount_, version_)));
        _assertData(3, _envelope(BALANCE_REPORT, _balanceReport(balance_ + amount_, version_)));
        _assertData(
            4,
            _envelope(
                COMMAND_ACK,
                _commandAck(operationId, version_, delta_, balance_ + amount_, version_, version_, 1)
            )
        );
        _assertData(5, before[4]);
        _assertData(6, before[5]);
        _assertFieldsUnchanged(1, 6);
    }

    // ------------------------------------------------------------------ unwindQueuedReturn

    function testShouldUnwindTheHeadReturnAndRaiseEveryEntryBehindIt() public {
        bytes32 operationId = keccak256("released");
        // Head: the queued return, amountLD in local decimals (18) for an amount in shared decimals (6).
        _writeEntry(31, _envelope(RETURN_TRANSFER, _settled(operationId, AMOUNT_SD, 4_000, 9)), AMOUNT_SD * RATE, 777);
        _writeSixTypes(32);
        // Outside: one entry before the head, one after the last id.
        _write(30, _envelope(TRANSFER_SETTLED, _settled(keccak256("before"), 1, 3_000, 6)));
        _write(38, _envelope(BALANCE_REPORT, _balanceReport(9_000, 10)));
        bytes[] memory before = _snapshot(30, 38);

        (bytes32 releasedId, uint256 releasedSD) = harness.unwindQueuedReturn(31, 37);

        assertEq(releasedId, operationId, "operation id");
        assertEq(releasedSD, AMOUNT_SD, "released amount is the payload amount (shared), not amountLD");
        _assertData(31, _envelope(RETURN_TRANSFER, _settled(operationId, 0, 4_000 + AMOUNT_SD, 9)));
        _assertHeadWords(before[1], 31, AMOUNT_SD);
        (, uint256 headAmountLD, uint256 headDeadline) = harness.entry(31);
        assertEq(headAmountLD, 0, "head amountLD zeroed");
        assertEq(headDeadline, 777, "head returnDeadline left to the caller's send");

        _assertData(32, _envelope(TRANSFER_SETTLED, _settled(keccak256("settled"), 1_000, 5_000 + AMOUNT_SD, 7)));
        _assertData(33, _envelope(RETURN_TRANSFER, _settled(keccak256("return"), 2_000, 6_000 + AMOUNT_SD, 8)));
        _assertData(34, _envelope(BALANCE_REPORT, _balanceReport(7_000 + AMOUNT_SD, 8)));
        _assertData(35, _envelope(COMMAND_ACK, _commandAck(keccak256("ack"), 5, -12_345, 8_000 + AMOUNT_SD, 8, 3, 2)));
        _assertOnlyWordRaised(32, before[2], SETTLED_BALANCE_WORD, AMOUNT_SD);
        _assertOnlyWordRaised(33, before[3], SETTLED_BALANCE_WORD, AMOUNT_SD);
        _assertOnlyWordRaised(34, before[4], REPORT_BALANCE_WORD, AMOUNT_SD);
        _assertOnlyWordRaised(35, before[5], ACK_BALANCE_WORD, AMOUNT_SD);
        _assertData(36, before[6]);
        _assertData(37, before[7]);
        _assertData(30, before[0]);
        _assertData(38, before[8]);
        _assertFieldsUnchanged(30, 30);
        _assertFieldsUnchanged(32, 38);
    }

    function testShouldUnwindAHeadThatIsTheLastIdWithoutTouchingLaterIds() public {
        bytes32 operationId = keccak256("alone");
        _writeEntry(40, _envelope(RETURN_TRANSFER, _settled(operationId, AMOUNT_SD, 0, 2)), AMOUNT_SD * RATE, 55);
        _write(41, _envelope(BALANCE_REPORT, _balanceReport(100, 2)));
        bytes[] memory before = _snapshot(40, 41);

        (bytes32 releasedId, uint256 releasedSD) = harness.unwindQueuedReturn(40, 40);

        assertEq(releasedId, operationId, "operation id");
        assertEq(releasedSD, AMOUNT_SD, "released amount");
        _assertData(40, _envelope(RETURN_TRANSFER, _settled(operationId, 0, AMOUNT_SD, 2)));
        _assertHeadWords(before[0], 40, AMOUNT_SD);
        _assertData(41, before[1]);
        _assertFieldsUnchanged(41, 41);
    }

    function testShouldUnwindAZeroAmountHeadWithoutChangingAnyBalance() public {
        bytes32 operationId = keccak256("zero");
        _writeEntry(1, _envelope(RETURN_TRANSFER, _settled(operationId, 0, 4_000, 2)), 0, 9);
        _write(2, _envelope(BALANCE_REPORT, _balanceReport(100, 2)));
        bytes[] memory before = _snapshot(1, 2);

        (, uint256 releasedSD) = harness.unwindQueuedReturn(1, 2);

        assertEq(releasedSD, 0, "released amount");
        _assertData(1, before[0]);
        _assertData(2, before[1]);
        (, uint256 headAmountLD, uint256 headDeadline) = harness.entry(1);
        assertEq(headAmountLD, 0, "head amountLD");
        assertEq(headDeadline, 9, "head returnDeadline");
        _assertFieldsUnchanged(2, 2);
    }

    function testShouldRefuseToUnwindAHeadThatIsNotAReturn() public {
        _writeSixTypes(1);
        bytes[] memory before = _snapshot(1, 6);
        uint8[5] memory notReturns = [TRANSFER_SETTLED, BALANCE_REPORT, COMMAND_ACK, RETURN_REJECTED, COMMAND_NACK];
        uint64[5] memory ids = [uint64(1), 3, 4, 5, 6];
        for (uint256 i; i < notReturns.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(CcipMessages.InvalidMessageType.selector, notReturns[i]));
            harness.unwindQueuedReturn(ids[i], 6);
        }
        for (uint64 id = 1; id <= 6; ++id) _assertData(id, before[id - 1]);
        _assertFieldsUnchanged(1, 6);
    }

    function testShouldRevertOnAHeadBalanceOverflow() public {
        _writeEntry(1, _envelope(RETURN_TRANSFER, _settled(keccak256("max"), 1, type(uint256).max, 2)), RATE, 9);
        vm.expectRevert(stdError.arithmeticError);
        harness.unwindQueuedReturn(1, 1);
    }

    function testFuzzShouldUnwindTheHeadAndRaiseTheEntriesBehindIt(
        uint256 headBalance_,
        uint256 amount_,
        uint256 behindBalance_,
        uint64 version_
    ) public {
        amount_ = bound(amount_, 0, type(uint256).max / RATE);
        headBalance_ = bound(headBalance_, 0, type(uint256).max - amount_);
        behindBalance_ = bound(behindBalance_, 0, type(uint256).max - amount_);
        bytes32 operationId = keccak256(abi.encode(headBalance_, amount_, behindBalance_));
        _writeEntry(
            1,
            _envelope(RETURN_TRANSFER, _settled(operationId, amount_, headBalance_, version_)),
            amount_ * RATE,
            1
        );
        _write(2, _envelope(BALANCE_REPORT, _balanceReport(behindBalance_, version_)));
        _write(3, _envelope(COMMAND_ACK, _commandAck(operationId, 1, -1, behindBalance_, version_, 2, 0)));
        _write(4, _envelope(RETURN_TRANSFER, _settled(operationId, 1, behindBalance_, version_)));

        (bytes32 releasedId, uint256 releasedSD) = harness.unwindQueuedReturn(1, 4);

        assertEq(releasedId, operationId, "operation id");
        assertEq(releasedSD, amount_, "released amount");
        _assertData(1, _envelope(RETURN_TRANSFER, _settled(operationId, 0, headBalance_ + amount_, version_)));
        (, uint256 headAmountLD, ) = harness.entry(1);
        assertEq(headAmountLD, 0, "head amountLD zeroed");
        _assertData(2, _envelope(BALANCE_REPORT, _balanceReport(behindBalance_ + amount_, version_)));
        _assertData(
            3,
            _envelope(COMMAND_ACK, _commandAck(operationId, 1, -1, behindBalance_ + amount_, version_, 2, 0))
        );
        _assertData(4, _envelope(RETURN_TRANSFER, _settled(operationId, 1, behindBalance_ + amount_, version_)));
        _assertFieldsUnchanged(2, 4);
    }

    // ------------------------------------------------------------------ fixtures

    /// @dev One entry of each queued response type at `first_` .. `first_ + 5`: TRANSFER_SETTLED, RETURN_TRANSFER,
    ///      BALANCE_REPORT, COMMAND_ACK, RETURN_REJECTED, COMMAND_NACK.
    function _writeSixTypes(uint64 first_) internal {
        _write(first_, _envelope(TRANSFER_SETTLED, _settled(keccak256("settled"), 1_000, 5_000, 7)));
        _write(first_ + 1, _envelope(RETURN_TRANSFER, _settled(keccak256("return"), 2_000, 6_000, 8)));
        _write(first_ + 2, _envelope(BALANCE_REPORT, _balanceReport(7_000, 8)));
        _write(first_ + 3, _envelope(COMMAND_ACK, _commandAck(keccak256("ack"), 5, -12_345, 8_000, 8, 3, 2)));
        _write(first_ + 4, _envelope(RETURN_REJECTED, abi.encode(keccak256("rejected"), uint8(2))));
        _write(first_ + 5, _envelope(COMMAND_NACK, abi.encode(keccak256("nack"), uint64(6))));
    }

    /// @dev Writes `data_` with an `amountLD` and a `returnDeadline` derived from the id (non-zero and distinct, also
    ///      for types that never hold them, so any write to those fields shows).
    function _write(uint64 responseId_, bytes memory data_) internal {
        harness.setEntry(responseId_, data_, _amountLDOf(responseId_), _deadlineOf(responseId_));
    }

    function _writeEntry(uint64 responseId_, bytes memory data_, uint256 amountLD_, uint256 deadline_) internal {
        harness.setEntry(responseId_, data_, amountLD_, deadline_);
    }

    function _amountLDOf(uint64 responseId_) internal pure returns (uint256) {
        return uint256(responseId_) * RATE + 1;
    }

    function _deadlineOf(uint64 responseId_) internal pure returns (uint256) {
        return 1_000_000 + uint256(responseId_);
    }

    function _snapshot(uint64 first_, uint64 last_) internal view returns (bytes[] memory data) {
        data = new bytes[](last_ - first_ + 1);
        for (uint64 id = first_; id <= last_; ++id) (data[id - first_], , ) = harness.entry(id);
    }

    // ------------------------------------------------------------------ independent encodings

    function _envelope(uint8 messageType_, bytes memory payload_) internal pure returns (bytes memory) {
        return abi.encode(WIRE_VERSION, messageType_, payload_);
    }

    /// @dev `TRANSFER_SETTLED` / `RETURN_TRANSFER` payload, as the executor decodes it.
    function _settled(
        bytes32 operationId_,
        uint256 amount_,
        uint256 balance_,
        uint64 version_
    ) internal pure returns (bytes memory) {
        return abi.encode(operationId_, amount_, balance_, version_);
    }

    /// @dev `BALANCE_REPORT` payload, as the executor decodes it.
    function _balanceReport(uint256 balance_, uint64 version_) internal pure returns (bytes memory) {
        return abi.encode(balance_, version_);
    }

    /// @dev `COMMAND_ACK` payload, as the executor decodes it.
    function _commandAck(
        bytes32 commandId_,
        uint64 sequence_,
        int256 delta_,
        uint256 balance_,
        uint64 version_,
        uint64 configEpoch_,
        uint8 resolution_
    ) internal pure returns (bytes memory) {
        return abi.encode(commandId_, sequence_, delta_, balance_, version_, configEpoch_, resolution_);
    }

    // ------------------------------------------------------------------ assertions

    function _assertData(uint64 responseId_, bytes memory expected_) internal view {
        (bytes memory data, , ) = harness.entry(responseId_);
        assertEq(data, expected_, string.concat("data of response ", vm.toString(responseId_)));
    }

    /// @dev The stored bytes equal `before_` except word `wordIndex_`, which grew by exactly `amount_`.
    function _assertOnlyWordRaised(
        uint64 responseId_,
        bytes memory before_,
        uint256 wordIndex_,
        uint256 amount_
    ) internal view {
        (bytes memory data, , ) = harness.entry(responseId_);
        string memory label = string.concat("response ", vm.toString(responseId_));
        assertEq(data.length, before_.length, string.concat(label, ": length"));
        for (uint256 i; i < data.length / 32; ++i) {
            uint256 wordAfter = _word(data, i);
            uint256 wordBefore = _word(before_, i);
            if (i == wordIndex_) {
                assertEq(wordAfter, wordBefore + amount_, string.concat(label, ": balance word raised"));
            } else {
                assertEq(wordAfter, wordBefore, string.concat(label, ": word ", vm.toString(i), " unchanged"));
            }
        }
    }

    /// @dev The released head: the amount word is 0, the balance word grew by `amount_`, every other word is as before.
    function _assertHeadWords(bytes memory before_, uint64 headId_, uint256 amount_) internal view {
        (bytes memory data, , ) = harness.entry(headId_);
        assertEq(data.length, before_.length, "head length");
        for (uint256 i; i < data.length / 32; ++i) {
            if (i == RETURN_AMOUNT_WORD) {
                assertEq(_word(before_, i), amount_, "head amount before");
                assertEq(_word(data, i), 0, "head amount after");
            } else if (i == SETTLED_BALANCE_WORD) {
                assertEq(_word(data, i), _word(before_, i) + amount_, "head balance raised");
            } else {
                assertEq(_word(data, i), _word(before_, i), string.concat("head word ", vm.toString(i), " unchanged"));
            }
        }
    }

    /// @dev `amountLD` and `returnDeadline` of every id in `first_` .. `last_` are the values `_write` stored.
    function _assertFieldsUnchanged(uint64 first_, uint64 last_) internal view {
        for (uint64 id = first_; id <= last_; ++id) {
            (, uint256 amountLD, uint256 deadline) = harness.entry(id);
            assertEq(amountLD, _amountLDOf(id), string.concat("amountLD of response ", vm.toString(id)));
            assertEq(deadline, _deadlineOf(id), string.concat("returnDeadline of response ", vm.toString(id)));
        }
    }

    function _word(bytes memory data_, uint256 index_) internal pure returns (uint256 word) {
        assembly ("memory-safe") {
            word := mload(add(add(data_, 0x20), mul(index_, 0x20)))
        }
    }
}
