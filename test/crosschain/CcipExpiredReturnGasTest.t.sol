// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CcipExpiredReturnFixture, CcipExpiredReturnToken} from "test/crosschain/CcipExpiredReturnFixture.sol";
import {ColdGas} from "test/crosschain/ColdGas.sol";
import {CcipCrosschainDispatcher} from "contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipClient} from "contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "contracts/crosschain/ccip/lib/CcipMessages.sol";
import {Command, SweepFloor} from "contracts/crosschain/lib/CrosschainMessages.sol";

/// @notice Token of the IL-9621 gas suite. It is etched over the fixture token (same ERC-20 storage layout), so the
///         dispatcher, the executor and the router keep using the fixture address. In `transferFrom` it records
///         `gasleft()` first and then either burns gas, burns all gas, or rejects below a gas threshold.
contract CcipExpiredReturnGasToken is CcipExpiredReturnToken {
    error GasBelowThreshold(uint256 gasLeft, uint256 threshold);

    enum Mode {
        NORMAL,
        BURN,
        BURN_ALL,
        REJECT_BELOW
    }

    Mode public mode;
    /// @dev BURN: gas burnt; REJECT_BELOW: the gas threshold.
    uint256 public parameter;
    /// @notice `gasleft()` seen at the entry of the last `transferFrom` that was not rolled back.
    uint256 public lastGasLeft;

    constructor() CcipExpiredReturnToken(18) {}

    function configure(Mode mode_, uint256 parameter_) external {
        mode = mode_;
        parameter = parameter_;
    }

    function transferFrom(address from_, address to_, uint256 amount_) public override returns (bool) {
        uint256 gasLeft = gasleft();
        lastGasLeft = gasLeft;
        Mode current = mode;
        if (current == Mode.BURN) {
            uint256 target = gasLeft - parameter;
            while (gasleft() > target) {}
        } else if (current == Mode.BURN_ALL) {
            while (true) {}
        } else if (current == Mode.REJECT_BELOW) {
            if (gasLeft < parameter) revert GasBelowThreshold(gasLeft, parameter);
        }
        return super.transferFrom(from_, to_, amount_);
    }
}

/// @title CcipExpiredReturnGasTest
/// @notice IL-9621 attempt gas budget of `flushExpiredReturn` (decision D6) and cold gas measurements.
///         The attempt to send the expired return WITH its tokens always gets exactly `B =
///         EXPIRED_RETURN_ATTEMPT_GAS` (2,000,000), whatever the caller's gas limit, after the check `gasleft() >= B
///         + B / 32`. Below that the call reverts `InsufficientGasForExpiredReturn` with no state change; above it the
///         outcome depends only on the state: a send that fits in `B` returns `false`, a send that does not fit in `B`
///         (or fails early) returns `true` (released without tokens), at every limit.
/// @dev The tests that measure gas (`ColdGas`) assert nothing about the numbers beyond what the plan asks; they report
///      them with `emit log_named_uint`. `foundry.toml` has `isolate = false`, so a test is one transaction and the
///      measurements cool the touched accounts first (`ColdGas`).
contract CcipExpiredReturnGasTest is CcipExpiredReturnFixture, ColdGas {
    event ReturnExpiredUnwound(bytes32 operationId, uint256 amount, uint64 responseId);

    error InsufficientGasForExpiredReturn(uint256 gasLeft, uint256 required);
    error GasBelowThreshold(uint256 gasLeft, uint256 threshold);

    uint256 internal constant FUNDED = 100e18;
    uint256 internal constant RECALL = 60e18;
    uint256 internal constant ATTEMPT_GAS = 2_000_000;
    uint256 internal constant REQUIRED = 2_062_500;
    uint256 internal constant SMALL_BLOCK = 3_000_000;
    uint256 internal constant NEUTRAL_CAP = 56;

    uint256 private _nonce;

    function setUp() public {
        vm.warp(365 days);
        _expiredFixtureSetUp();
        CcipExpiredReturnGasToken probe = new CcipExpiredReturnGasToken();
        vm.etch(address(token), address(probe).code);
        _bridge(FUNDED);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(FUNDED);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
    }

    // ------------------------------------------------------------------ helpers

    function _gasToken() internal view returns (CcipExpiredReturnGasToken) {
        return CcipExpiredReturnGasToken(address(token));
    }

    /// @dev An expired recall at the queue head: its token-bearing send was refused when it was queued, the deadline
    ///      has passed, and sends are let through again, so only the token (or the gas) decides the attempt.
    function _expiredHead() internal returns (uint64 head) {
        _blockTokenSends();
        uint256 deadline = _recall(RECALL);
        head = dispatcher.responseQueueHead();
        vm.warp(deadline + 1);
        _unblockSends();
    }

    function _flush(uint256 gasLimit_) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(dispatcher).call{gas: gasLimit_}(
            abi.encodeCall(CcipCrosschainDispatcher.flushExpiredReturn, ())
        );
    }

    /// @dev Everything the call must leave alone when it reverts early.
    function _digest() internal view returns (bytes32) {
        uint64 head = dispatcher.responseQueueHead();
        (bytes memory data, , uint256 amountLD) = dispatcher.queuedResponse(head);
        return
            keccak256(
                abi.encode(
                    head,
                    dispatcher.responseQueueTail(),
                    dispatcher.trackedIdle(),
                    dispatcher.queuedTokenAmount(),
                    dispatcher.stateVersion(),
                    dispatcher.queuedReturnDeadline(head),
                    data,
                    amountLD,
                    token.balanceOf(address(dispatcher)),
                    token.balanceOf(address(executor)),
                    router.heldCount()
                )
            );
    }

    function _insufficientGas(
        bytes memory ret_
    ) internal pure returns (bool matches, uint256 gasLeft, uint256 required) {
        if (ret_.length != 68 || bytes4(ret_) != InsufficientGasForExpiredReturn.selector) return (false, 0, 0);
        bytes memory args = new bytes(64);
        for (uint256 i; i < 64; ++i) args[i] = ret_[i + 4];
        (gasLeft, required) = abi.decode(args, (uint256, uint256));
        return (true, gasLeft, required);
    }

    /// @dev The smallest caller gas limit that passes the precheck: with limit `L` the precheck sees `L - c`, where
    ///      `c` is the gas spent before it (the same for every limit), so one probe below the threshold gives `c`.
    ///      Run inside a snapshot: the probe reverts, but the helper does not rely on that.
    function _minimalLimit() internal returns (uint256 limit) {
        uint256 probe = 1_000_000;
        (bool ok, bytes memory ret) = _flush(probe);
        assertFalse(ok, "probe reverts");
        (bool matches, uint256 gasLeft, uint256 required) = _insufficientGas(ret);
        assertTrue(matches, "probe: InsufficientGasForExpiredReturn");
        assertEq(required, REQUIRED, "probe: required");
        limit = probe + (required - gasLeft);
    }

    /// @dev `foundry.toml` has `isolate = false` and `vm.revertToState` restores values, not warmth: a run that follows
    ///      another one sees the slots and accounts of the first as warm. A dry run before the first measurement
    ///      makes every later run start from the same (warm) access state, so the gas the attempt sees is comparable.
    function _warmUp() internal {
        uint256 snap = vm.snapshotState();
        _flush(30_000_000);
        vm.revertToState(snap);
    }

    /// @dev Sweeps the caller's gas limit for a token that makes the attempt SUCCEED (burn below the budget, or an
    ///      early-revert threshold the budget always meets): below `required` the selector and no state change,
    ///      from the minimal limit up `false` with the tokens delivered, never `true`.
    function _sweepAttemptSucceeds() internal {
        uint256 minimal = _minimalLimit();
        uint256[3] memory below = [uint256(1_000_000), minimal - 1_000, minimal - 1];
        for (uint256 i; i < below.length; ++i) {
            uint256 snap = vm.snapshotState();
            bytes32 before_ = _digest();
            (bool ok, bytes memory ret) = _flush(below[i]);
            assertFalse(ok, "below required reverts");
            (bool matches, uint256 gasLeft, uint256 required) = _insufficientGas(ret);
            assertTrue(matches, "selector InsufficientGasForExpiredReturn");
            assertEq(required, REQUIRED);
            assertLt(gasLeft, required);
            assertEq(_digest(), before_, "no state change below required");
            vm.revertToState(snap);
        }
        uint256[6] memory above = [minimal, minimal + 1, minimal + 100_000, 3_000_000, 10_000_000, 30_000_000];
        for (uint256 i; i < above.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 idle = dispatcher.trackedIdle();
            uint256 executorBefore = token.balanceOf(address(executor));
            (bool ok, bytes memory ret) = _flush(above[i]);
            assertTrue(ok, "above required: no revert");
            assertFalse(abi.decode(ret, (bool)), "attempt succeeded: false, never true");
            assertEq(dispatcher.responseQueueHead(), 0, "head sent");
            assertEq(dispatcher.trackedIdle(), idle, "idle untouched: the tokens left");
            assertEq(dispatcher.queuedTokenAmount(), 0);
            assertEq(token.balanceOf(address(executor)) - executorBefore, RECALL, "the tokens were delivered");
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------ (e) pins

    function testShouldPinAttemptBudgetAndRequiredFormula() public {
        _expiredHead();
        assertEq(REQUIRED, ATTEMPT_GAS + ATTEMPT_GAS / 32, "required = B + B / 32");
        // Touch the token's configuration slots (the compiler may read them before `gasleft()`), so that the measured
        // run and the configured runs below see them equally warm.
        _gasToken().configure(CcipExpiredReturnGasToken.Mode.NORMAL, 0);
        _warmUp();
        uint256 minimal = _minimalLimit();

        // The precheck sees `limit - c`: one gas less than the minimal limit is one gas less than `required`.
        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory ret) = _flush(minimal - 1);
        assertFalse(ok);
        (bool matches, uint256 gasLeft, uint256 required) = _insufficientGas(ret);
        assertTrue(matches);
        assertEq(required, REQUIRED, "required is B * 33 / 32 = 2,062,500");
        assertEq(gasLeft, REQUIRED - 1, "the minimal limit is exact");
        vm.revertToState(snap);

        snap = vm.snapshotState();
        (ok, ret) = _flush(minimal);
        assertTrue(ok, "the minimal limit passes the precheck");
        assertFalse(abi.decode(ret, (bool)), "and the send with tokens succeeds");
        uint256 seen = _gasToken().lastGasLeft();
        vm.revertToState(snap);

        // B: the token sees `B` less the gas spent on the way to it (router, token call), never more.
        assertLe(seen, ATTEMPT_GAS, "the token never sees more than B");
        assertGt(seen, ATTEMPT_GAS - 200_000, "and B less a bounded overhead");

        // Exact edge: a token that rejects below `seen` is satisfied, one that rejects below `seen + 1` is not.
        snap = vm.snapshotState();
        _gasToken().configure(CcipExpiredReturnGasToken.Mode.REJECT_BELOW, seen);
        (ok, ret) = _flush(minimal);
        assertTrue(ok);
        assertFalse(abi.decode(ret, (bool)), "threshold == seen: the attempt passes");
        vm.revertToState(snap);

        snap = vm.snapshotState();
        _gasToken().configure(CcipExpiredReturnGasToken.Mode.REJECT_BELOW, seen + 1);
        (ok, ret) = _flush(minimal);
        assertTrue(ok);
        assertTrue(abi.decode(ret, (bool)), "threshold == seen + 1: the attempt fails, released without tokens");
        vm.revertToState(snap);
    }

    // ------------------------------------------------------------------ (a) a token that burns below the budget

    function testShouldNeverReleaseWhenTokenBurnsGasBelowTheBudget() public {
        _expiredHead();
        _gasToken().configure(CcipExpiredReturnGasToken.Mode.BURN, 1_500_000);
        _sweepAttemptSucceeds();
    }

    // ------------------------------------------------------------------ (b) early revert on low gas

    function testShouldNeverReleaseWhenTokenRejectsOnlyBelowAThresholdTheBudgetMeets() public {
        _expiredHead();
        _gasToken().configure(CcipExpiredReturnGasToken.Mode.REJECT_BELOW, 1_500_000);
        _sweepAttemptSucceeds();
    }

    /// @dev Control for (b): the same token with a threshold ABOVE the budget rejects in the attempt, so the early
    ///      revert path is reached and the call releases the return, at the minimal limit and at a much higher one.
    function testShouldReleaseWhenTokenRejectsBelowAThresholdAboveTheBudget() public {
        uint64 head = _expiredHead();
        _gasToken().configure(CcipExpiredReturnGasToken.Mode.REJECT_BELOW, ATTEMPT_GAS + 1);
        uint256 minimal = _minimalLimit();
        uint256[3] memory limits = [minimal + 400_000, 5_000_000, 30_000_000];
        for (uint256 i; i < limits.length; ++i) {
            uint256 snap = vm.snapshotState();
            (bytes32 operationId, , , ) = _decodeReturn(_returnPayload(head));
            vm.expectEmit(address(dispatcher));
            emit ReturnExpiredUnwound(operationId, RECALL, head);
            (bool ok, bytes memory ret) = _flush(limits[i]);
            assertTrue(ok);
            assertTrue(abi.decode(ret, (bool)), "released without tokens");
            assertEq(dispatcher.trackedIdle(), FUNDED, "the tokens are idle again");
            vm.revertToState(snap);
        }
    }

    function _returnPayload(uint64 id_) internal view returns (bytes memory payload) {
        CcipMsgType messageType;
        (messageType, payload) = _queuedPayload(id_);
        assertEq(uint8(messageType), uint8(CcipMsgType.RETURN_TRANSFER));
    }

    // ------------------------------------------------------------------ (c) determinism

    function testShouldGiveTheAttemptTheSameGasForAnyCallerLimit() public {
        _expiredHead();
        _warmUp();
        uint256 minimal = _minimalLimit();
        uint256[4] memory limits = [minimal, minimal + 250_000, 10_000_000, 30_000_000];
        uint256 firstSeen;
        for (uint256 i; i < limits.length; ++i) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = _flush(limits[i]);
            assertTrue(ok);
            assertFalse(abi.decode(ret, (bool)));
            uint256 seen = _gasToken().lastGasLeft();
            if (i == 0) firstSeen = seen;
            assertEq(seen, firstSeen, "the token sees the same gasleft() at every caller limit");
            vm.revertToState(snap);
        }
        assertGt(firstSeen, 0);
    }

    // ------------------------------------------------------------------ (d) a send more expensive than the budget

    function testShouldReleaseAtEveryLimitWhenTheSendNeedsMoreThanTheBudget() public {
        uint64 head = _expiredHead();
        _gasToken().configure(CcipExpiredReturnGasToken.Mode.BURN_ALL, 0);
        uint256 minimal = _minimalLimit();
        (bytes32 operationId, , , ) = _decodeReturn(_returnPayload(head));
        // Between the minimal limit and what the unwind and the token-less send need after the attempt used up its
        // budget the call may run out of gas as a whole, but it never returns `false` (a send with tokens).
        uint256[3] memory edge = [minimal, minimal + 1, minimal + 100_000];
        for (uint256 i; i < edge.length; ++i) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = _flush(edge[i]);
            assertTrue(!ok || abi.decode(ret, (bool)), "never false");
            vm.revertToState(snap);
        }
        uint256[4] memory limits = [uint256(3_000_000), 5_000_000, 10_000_000, 30_000_000];
        for (uint256 i; i < limits.length; ++i) {
            uint256 snap = vm.snapshotState();
            vm.expectEmit(address(dispatcher));
            emit ReturnExpiredUnwound(operationId, RECALL, head);
            (bool ok, bytes memory ret) = _flush(limits[i]);
            assertTrue(ok, "released");
            assertTrue(abi.decode(ret, (bool)), "true at every limit");
            assertEq(dispatcher.responseQueueHead(), 0);
            assertEq(dispatcher.trackedIdle(), FUNDED, "the tokens are idle again");
            assertEq(dispatcher.queuedTokenAmount(), 0);
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------ cold measurements

    function _nextCommandId() private returns (bytes32) {
        return bytes32(((block.timestamp + 1 days) << 192) | ++_nonce);
    }

    function _inject(bytes memory data_, uint256 tokenAmount_) private {
        _inject(data_, tokenAmount_, tokenAmount_ != 0);
    }

    /// @dev `withEntry_` delivers one configured-asset token entry even when its amount is zero (a pool fee plus
    ///      decimal downscaling can deliver nothing, IL-8635); `_receiveOutbound` accepts that as a zero credit.
    function _inject(bytes memory data_, uint256 tokenAmount_, bool withEntry_) private {
        CcipClient.EVMTokenAmount[] memory delivered = new CcipClient.EVMTokenAmount[](withEntry_ ? 1 : 0);
        if (tokenAmount_ != 0) token.mint(address(dispatcher), tokenAmount_);
        if (withEntry_) delivered[0] = CcipClient.EVMTokenAmount({token: address(token), amount: tokenAmount_});
        vm.prank(address(router));
        dispatcher.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256(abi.encode("gas-test", ++_nonce)),
                sourceChainSelector: EXECUTOR_SELECTOR,
                sender: abi.encode(address(executor)),
                data: data_,
                destTokenAmounts: delivered
            })
        );
    }

    /// @dev A successful empty `UPDATE_VAULTS` command: queues one `COMMAND_ACK`.
    function _injectAck() private {
        _inject(
            CcipMessages.encode(
                CcipMsgType.UPDATE_VAULTS,
                abi.encode(
                    CcipMsgType.UPDATE_VAULTS,
                    Command({
                        commandId: _nextCommandId(),
                        sequence: dispatcher.nextCommandSequence(),
                        commandConfigEpoch: dispatcher.commandConfigEpoch(),
                        action: 0,
                        minExecutionGas: 0,
                        actionData: ""
                    }),
                    abi.encode(new address[](0), true, false, new SweepFloor[](0))
                )
            ),
            0
        );
    }

    function _injectOutbound(uint256 amount_) private {
        _inject(
            CcipMessages.encode(CcipMsgType.OUTBOUND_TRANSFER, abi.encode(keccak256(abi.encode(++_nonce)))),
            amount_,
            true
        );
    }

    function _live() private view returns (uint256) {
        uint64 head = dispatcher.responseQueueHead();
        return head == 0 ? 0 : uint256(dispatcher.responseQueueTail() - head) + 1;
    }

    /// @dev Queue composition counters (zero balances count the entries whose carried balance is 0).
    function _composition()
        internal
        view
        returns (uint256 returns_, uint256 acks, uint256 settled, uint256 zeroBalances)
    {
        uint64 head = dispatcher.responseQueueHead();
        uint64 tail = dispatcher.responseQueueTail();
        for (uint64 id = head; id != 0 && id <= tail; ++id) {
            (CcipMsgType messageType, ) = _queuedPayload(id);
            if (messageType == CcipMsgType.RETURN_TRANSFER) ++returns_;
            else if (messageType == CcipMsgType.COMMAND_ACK) ++acks;
            else if (messageType == CcipMsgType.TRANSFER_SETTLED) ++settled;
            (bool hasBalance, uint256 balance) = _queuedBalance(id);
            if (hasBalance && balance == 0) ++zeroBalances;
        }
    }

    /// @dev The worst queue `_enqueueResponse` admits behind an expired head: the head recall takes ALL the idle (so
    ///      every `COMMAND_ACK` queued behind encodes balance 0), then 55 `COMMAND_ACK` up to the neutral cap of 56,
    ///      then 8 value-carrying `TRANSFER_SETTLED` in the reserved band (they carry the tiny idle they credited).
    function _worstQueue() internal returns (uint64 head) {
        return _worstQueue(0);
    }

    /// @dev `settledAmount_` is the token amount of each of the 8 `TRANSFER_SETTLED`; 0 (K12) delivers a zero-amount
    ///      token entry, so every balance word behind the head starts at 0. A positive amount is the weaker fixture
    ///      that the first IL-9621 measurement used.
    function _worstQueue(uint256 settledAmount_) internal returns (uint64 head) {
        _blockTokenSends();
        uint256 deadline = _recall(FUNDED);
        head = dispatcher.responseQueueHead();
        for (uint256 i; i < NEUTRAL_CAP - 1; ++i) _injectAck();
        assertEq(_live(), NEUTRAL_CAP, "head + 55 acks");
        for (uint256 i; i < 8; ++i) _injectOutbound(settledAmount_);
        assertEq(_live(), 64, "hard cap");
        // Token sends stay blocked: the attempt fails, the worst path (unwind of 63 entries, token-less send).
        vm.warp(deadline + 1);
    }

    /// @dev Cold gross gas of `flushExpiredReturn` in the current state: one dry run records the touched accounts, the
    ///      state is rolled back, the accounts are cooled and the call is measured. Returns the gross gas (without
    ///      the cold account penalty) and the penalty `ColdGas` adds for the accounts the dry run touched.
    function _coldFlush() internal returns (uint256 gross, uint256 penalty, bool unwound) {
        uint256 snap = vm.snapshotState();
        _beginRecording();
        dispatcher.flushExpiredReturn();
        address[] memory touched = _endRecording();
        vm.revertToState(snap);
        _cool(touched);
        penalty = _coldAccountPenalty(touched);
        uint256 before_ = gasleft();
        unwound = dispatcher.flushExpiredReturn();
        gross = before_ - gasleft();
    }

    function _report(string memory label_, uint256 gross_, uint256 penalty_) internal {
        emit log_named_uint(string.concat(label_, " gross gas (cold slots)"), gross_);
        emit log_named_uint(string.concat(label_, " cold account penalty"), penalty_);
        emit log_named_uint(string.concat(label_, " gross + penalty"), gross_ + penalty_);
        emit log_named_uint("HyperEVM small block gas limit", SMALL_BLOCK);
        if (gross_ + penalty_ > SMALL_BLOCK) {
            emit log_named_uint(string.concat(label_, " over the small block by"), gross_ + penalty_ - SMALL_BLOCK);
        } else {
            emit log_named_uint(string.concat(label_, " under the small block by"), SMALL_BLOCK - gross_ - penalty_);
        }
    }

    /// @dev Proof that the first fixture was weaker: with positive settled credits 8 of the 64 carried balances start
    ///      non-zero, so the full queue then holds only 56 zero-to-nonzero rewrites.
    function testShouldShowThePositiveCreditFixtureStartsWithNonZeroBalances() public {
        _worstQueue(1e18);
        (, , , uint256 zeroBalances) = _composition();
        uint256 nonZero = 64 - zeroBalances;
        emit log_named_uint("positive-credit fixture: carried balances that start non-zero", nonZero);
        assertEq(nonZero, 8, "the weaker fixture starts 8 balances non-zero");
    }

    function testColdGasFlushExpiredReturnWorstQueue() public {
        uint64 head = _worstQueue();
        (uint256 returns_, uint256 acks, uint256 settled, uint256 zeroBalances) = _composition();
        emit log_named_uint("queue: RETURN_TRANSFER (head)", returns_);
        emit log_named_uint("queue: COMMAND_ACK", acks);
        emit log_named_uint("queue: TRANSFER_SETTLED", settled);
        emit log_named_uint("queue: entries with a zero carried balance", zeroBalances);
        emit log_named_uint("queue: carried balances that start non-zero", 64 - zeroBalances);
        assertEq(returns_, 1);
        assertEq(acks, 55);
        assertEq(settled, 8);
        // K12: every one of the 64 carried balances (head included) starts at zero.
        assertEq(zeroBalances, 64, "all 64 carried balances start at zero");

        (uint256 gross, uint256 penalty, bool unwound) = _coldFlush();
        assertTrue(unwound, "released without tokens");
        _report("flushExpiredReturn 64 entries", gross, penalty);
        assertEq(dispatcher.responseQueueHead(), head + 1, "only the head left");
        // Every one of the 63 successors was raised by exactly the released amount.
        for (uint64 id = head + 1; id <= dispatcher.responseQueueTail(); ++id) {
            (bool hasBalance, uint256 balance) = _queuedBalance(id);
            if (!hasBalance) continue;
            assertEq(balance, _toShared(FUNDED), "successor balance raised by the released amount");
        }
    }

    /// @dev Token-bearing administrative skip of the same full queue: `raiseQueuedBalances` rewrites all 63 successors.
    ///      Measured cold (setup and scheduling excluded) and reported, not asserted against the benchmark.
    function testColdGasSkipTokenBearingHeadWorstQueue() public {
        uint64 head = _worstQueue();
        (, , , uint256 zeroBalances) = _composition();
        assertEq(zeroBalances, 64, "all 64 carried balances start at zero");
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = dispatcher.scheduleSkipStuckResponse(head);
        vm.warp(block.timestamp + RESCUE_DELAY);

        uint256 snap = vm.snapshotState();
        _beginRecording();
        vm.prank(RESCUE_ADMIN);
        dispatcher.executeSkipStuckResponse(rescueId, head);
        address[] memory touched = _endRecording();
        vm.revertToState(snap);
        _cool(touched);
        uint256 penalty = _coldAccountPenalty(touched);
        vm.prank(RESCUE_ADMIN);
        uint256 before_ = gasleft();
        dispatcher.executeSkipStuckResponse(rescueId, head);
        uint256 gross = before_ - gasleft();
        _report("executeSkipStuckResponse 64 entries", gross, penalty);

        assertEq(dispatcher.responseQueueHead(), head + 1, "the head is dropped");
        for (uint64 id = head + 1; id <= dispatcher.responseQueueTail(); ++id) {
            (bool hasBalance, uint256 balance) = _queuedBalance(id);
            if (!hasBalance) continue;
            assertEq(balance, _toShared(FUNDED), "successor balance raised exactly once");
        }
        assertEq(dispatcher.trackedIdle(), FUNDED, "the skipped tokens are idle again");
    }

    function testColdGasFlushExpiredReturnHeadOnly() public {
        _expiredHead();
        _blockTokenSends(); // the attempt fails: unwind and token-less send, as in the worst queue
        (uint256 gross, uint256 penalty, bool unwound) = _coldFlush();
        assertTrue(unwound);
        _report("flushExpiredReturn head only", gross, penalty);
    }

    /// @dev `RETURN_REQUEST` that stays queued (the deadline is written into the entry), delivered by the router
    ///      with exactly the route's `messageGasLimit`, cold.
    function testColdGasReturnRequestStaysQueuedWithinMessageGasLimit() public {
        _blockTokenSends();
        router.setAutoDeliver(false);
        _recall(RECALL);
        uint256 index = router.heldCount() - 1;
        uint256 snap = vm.snapshotState();
        _beginRecording();
        router.deliverHeld(index);
        address[] memory touched = _endRecording();
        vm.revertToState(snap);
        _cool(touched);
        uint256 before_ = gasleft();
        router.deliverHeldExact(index, ROUTE_GAS_LIMIT);
        uint256 gross = before_ - gasleft();
        uint64 head = dispatcher.responseQueueHead();
        assertTrue(head != 0, "the return stays queued");
        assertGt(dispatcher.queuedReturnDeadline(head), 0, "with its deadline");
        emit log_named_uint("RETURN_REQUEST (queued, deadline written) gross gas incl. router", gross);
        emit log_named_uint("RETURN_REQUEST cold account penalty", _coldAccountPenalty(touched));
        emit log_named_uint("route messageGasLimit", ROUTE_GAS_LIMIT);
    }

    /// @dev D2: the cost of the extra zero field cleared when a response is sent. A `RETURN_TRANSFER` head (three
    ///      fields: data, amount, deadline) and a `COMMAND_ACK` head (data, amount, deadline all deleted too, the
    ///      deadline slot being zero already), each sent by `flushResponse` cold. Reported, not asserted.
    function testColdGasSendingAResponseClearsTheDeadlineSlot() public {
        uint256 withDeadline = _coldFlushResponseOf(true);
        uint256 withoutDeadline = _coldFlushResponseOf(false);
        emit log_named_uint("flushResponse of a RETURN_TRANSFER head with a deadline, gross gas", withDeadline);
        emit log_named_uint("flushResponse of a COMMAND_ACK head, gross gas", withoutDeadline);
    }

    function _coldFlushResponseOf(bool returnHead_) private returns (uint256 gross) {
        uint256 outer = vm.snapshotState();
        if (returnHead_) {
            _blockTokenSends();
            _recall(RECALL);
            _unblockSends();
        } else {
            router.setFailSend(address(dispatcher), true); // stalls the head so the ack stays queued
            _injectAck();
            router.setFailSend(address(dispatcher), false);
        }
        uint256 snap = vm.snapshotState();
        _beginRecording();
        dispatcher.flushResponse();
        address[] memory touched = _endRecording();
        vm.revertToState(snap);
        _cool(touched);
        uint256 before_ = gasleft();
        dispatcher.flushResponse();
        gross = before_ - gasleft();
        assertEq(dispatcher.responseQueueHead(), 0, "sent");
        vm.revertToState(outer);
    }
}
