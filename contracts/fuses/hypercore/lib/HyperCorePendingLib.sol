// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HyperCoreLib} from "./HyperCoreLib.sol";

/// @title HyperCorePendingLib
/// @notice Per-vault pending-action state for HyperCore CoreWriter interactions.
/// @dev All writes happen in the PlasmaVault delegatecall context. The namespaced slot
///      is intentionally independent from PlasmaVault's ordinary storage layout.
library HyperCorePendingLib {
    /// @dev `Order` is retained only for storage/event compatibility: since IL-8543 no fuse enqueues an Order record
    ///      (orders and cancels settle TIMING-only through the `lastOrderL1Block` mini-gate), and `enqueue` is
    ///      Transfer-only. A legacy record left in storage by a pre-IL-8543 build is treated like any timing record.
    enum ActionClass {
        None,
        Transfer,
        Order
    }

    /// @dev Lower bound for `Config{TransferTimeoutSeconds}` (about 30x the measured ~2 s mainnet credit
    ///      latency). A timeout opens the gate without the observed effect, so a tiny value would recreate
    ///      the IL-8526 in-transit mispricing.
    uint64 internal constant MIN_TRANSFER_TIMEOUT_SECONDS = 60;

    /// @dev Transfer without a cross-domain effect to wait for (time-based settlement only).
    uint8 internal constant EFFECT_NONE = 0;
    /// @dev Settles only once the vault's Core spot balance of `effectTokenIndex` reaches `expectedBalance`.
    uint8 internal constant EFFECT_CORE_SPOT = 1;
    /// @dev Settles only once the vault's EVM balance of `effectEvmAsset` reaches `expectedBalance`.
    uint8 internal constant EFFECT_EVM_BALANCE = 2;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.hypercore.pending")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PENDING_SLOT = 0xff3841d45e92b4b113213ebf16e5e18527d87d1b739008d460c4a8565edaf200;

    /// @custom:storage-location erc7201:io.ipor.hypercore.pending
    /// @dev Field order is frozen (a deployed vault uses this ERC-7201 slot). Fields prefixed `deprecated` were used
    ///      only by the REPORTED settlement mode removed in IL-8543; they are never written any more and are only
    ///      deleted by `_clearRecord` so a record left by an older build cannot linger.
    struct PendingAction {
        uint64 pendingUntil;
        uint64 enqueuedL1Block;
        uint64 enqueuedEvmBlock;
        uint8 actionClass;
        uint8 deprecatedSettlementMode;
        uint8 deprecatedReportedResult;
        uint64 deprecatedResultL1Block;
        uint24 actionId;
        bytes32 payloadHash;
        bool deprecatedRefreshing;
        uint256 cachedValueWad;
        uint256 actionNonce;
        // Effect-bound settlement fields (appended; never reorder the fields above).
        uint8 effectKind;
        uint64 effectTokenIndex;
        address effectEvmAsset;
        uint64 timeoutAt;
        uint256 expectedBalance;
        // TIMING order mini-gate (appended; persistent: never reset by enqueue/clear).
        uint64 lastOrderL1Block;
    }

    error HyperCoreActionPending(uint64 pendingUntil);
    error HyperCoreActionNotSettled();
    error HyperCorePendingWindowOverflow();
    error HyperCorePendingEffectInvalid(uint8 effectKind);
    /// @notice A TIMING order was sent in the current Core L1 block and has not been processed yet.
    error HyperCoreOrderInFlight(uint64 orderL1Block);
    /// @notice At most one TIMING order may be sent per Core L1 block.
    error HyperCoreOrderRateLimited(uint64 lastOrderL1Block);

    /// @notice Emitted by the PlasmaVault (fuse delegatecall context) when a HyperCore transfer is sent and recorded
    ///         as pending.
    /// @dev Keep every field unindexed per the repository event policy. The signature is unchanged since
    ///      IL-8543 for indexers; `actionClass` is always 1 (Transfer) and `settlementMode` is always 0.
    ///      While the action is pending, ordinary vault calls are blocked and `HyperCoreBalanceFuse` reports
    ///      `cachedValueWad` instead of the live HyperCore value.
    /// @param nonce Per-vault, strictly increasing action counter (starts at 1)
    /// @param actionClass `ActionClass` of the action: always 1 = Transfer (deposit, send, USD class transfer,
    ///        builder fee approval); orders and cancels are not enqueued
    /// @param settlementMode Always 0 (legacy field, kept for event-signature compatibility)
    /// @param pendingUntil Unix timestamp (seconds) of the earliest timing-based settlement
    ///        (`block.timestamp + window`); the action settles once this time has passed and the L1 block has
    ///        advanced past `enqueuedL1Block`; an EVM -> Core deposit and a Core -> EVM bridge additionally wait
    ///        for their cross-domain effect (or a configured timeout)
    /// @param cachedValueWad HyperCore value of the vault (18 decimals, USD) snapshotted right before the action;
    ///        returned by `HyperCoreBalanceFuse` while the action is pending
    /// @param enqueuedL1Block HyperCore L1 block number at enqueue
    /// @param enqueuedEvmBlock HyperEVM block number of the enqueue transaction
    /// @param actionId CoreWriter action id (`HyperCoreLib.ACTION_*`); 0 for EVM-side deposits that do not go
    ///        through CoreWriter
    /// @param payloadHash `keccak256` of the exact CoreWriter payload sent (version ++ actionId ++ abi-encoded
    ///        fields); for EVM-side deposits `keccak256(abi.encode(tokenIndex, amount))`
    event HyperCoreActionEnqueued(
        uint256 nonce,
        uint8 actionClass,
        uint8 settlementMode,
        uint64 pendingUntil,
        uint256 cachedValueWad,
        uint64 enqueuedL1Block,
        uint64 enqueuedEvmBlock,
        uint24 actionId,
        bytes32 payloadHash
    );
    /// @notice Emitted by the PlasmaVault when a pending action record is cleared. It marks the on-chain end of
    ///         every action. In practice it is emitted by `settleIfReady()`, which the pre-hooks call when a transfer
    ///         is first observed settled; `clear()` also clears a settled record, but no contract calls it.
    /// @param nonce Nonce of the cleared action, as emitted in `HyperCoreActionEnqueued`
    event HyperCoreActionSettled(uint256 nonce);

    function get() internal pure returns (PendingAction storage pending) {
        assembly {
            pending.slot := PENDING_SLOT
        }
    }

    /// @notice Whether an action still blocks ordinary vault calls.
    function isActionPending() internal view returns (bool) {
        if (get().actionClass == uint8(ActionClass.None)) return false;
        return !isActionSettled();
    }

    /// @notice Whether the snapshotted settlement condition has been met.
    /// @dev A settled record is latched (cleared) by the pre-hooks via `settleIfReady()`, so this predicate is only
    ///      re-evaluated until the first hook run after settlement.
    ///      - Intra-Core transfers (margin, self-send, builder fee): an operational assumption only (the time
    ///        window has elapsed and a later L1 block has been observed). It is NOT proof that the Core action
    ///        executed or was rejected. Orders and cancels create no record (IL-8527).
    ///      - Cross-domain transfers (EVM -> Core deposit, Core -> EVM bridge, IL-8526): additionally requires
    ///        the balance effect to be observed (`isEffectObserved()`) or the transfer timeout to have passed.
    ///      The timeout is evaluated first, so once `timeoutAt` has passed the effect balance is not read at all.
    ///      The time and L1-block gates (including the 0x809 read) still apply before it: an unavailable 0x809 or an
    ///      unchanged L1 block still blocks (fail-closed). Before `timeoutAt` the effect is still required and a
    ///      reverting effect read still reverts.
    function isActionSettled() internal view returns (bool) {
        PendingAction storage pending = get();
        if (pending.actionClass == uint8(ActionClass.None)) return true;

        if (block.timestamp < pending.pendingUntil || HyperCoreLib.l1BlockNumber() <= pending.enqueuedL1Block) {
            return false;
        }
        if (pending.actionClass == uint8(ActionClass.Transfer) && pending.effectKind != EFFECT_NONE) {
            // Timeout first: once the timing and L1-block gates pass, no balance-effect read after `timeoutAt` (IL-8908).
            return block.timestamp >= pending.timeoutAt || isEffectObserved();
        }
        return true;
    }

    /// @notice Whether the cross-domain effect of the pending Transfer has landed.
    /// @dev Only the two transfers whose value is "in the void" carry an effect: an EVM -> Core deposit
    ///      (`EFFECT_CORE_SPOT`: the Core spot balance must reach `expectedBalance`) and a Core -> EVM bridge
    ///      (`EFFECT_EVM_BALANCE`: the vault's ERC20 balance must reach `expectedBalance`). Returns false for a
    ///      record without an effect. Residual risk: once `timeoutAt` has passed (and the timing and L1-block gates
    ///      hold) the gate opens without reading the effect, so neither a rejected transfer nor a reverting effect
    ///      token can hold it shut beyond the timeout (it cannot freeze the vault); if Core merely lags beyond
    ///      the timeout, NAV is read live without the in-transit amount and the GUARDIAN must pause the vault.
    function isEffectObserved() internal view returns (bool) {
        PendingAction storage pending = get();
        if (pending.effectKind == EFFECT_CORE_SPOT) {
            return
                HyperCoreLib.coreUserExists(address(this)) &&
                HyperCoreLib.spotBalance(address(this), pending.effectTokenIndex).total >= pending.expectedBalance;
        }
        if (pending.effectKind == EFFECT_EVM_BALANCE) {
            return IERC20(pending.effectEvmAsset).balanceOf(address(this)) >= pending.expectedBalance;
        }
        return false;
    }

    function requireNotPendingAction() internal view {
        if (isActionPending()) revert HyperCoreActionPending(get().pendingUntil);
    }

    /// @notice Records that a TIMING-mode order was sent in the current Core L1 block.
    /// @dev TIMING orders create no pending record; this single persistent field is the whole mini-gate.
    function recordTimingOrder() internal {
        get().lastOrderL1Block = HyperCoreLib.l1BlockNumber();
    }

    /// @notice Whether a TIMING order was sent in the current Core L1 block (not yet processed by a later block).
    /// @dev Deliberately separate from `isActionPending()`: `HyperCoreBalanceFuse` returns `cachedValueWad` while pending,
    ///      and a TIMING order has no cached value.
    function isOrderInFlight() internal view returns (bool) {
        uint64 last = get().lastOrderL1Block;
        return last != 0 && HyperCoreLib.l1BlockNumber() <= last;
    }

    /// @notice Reverts while a TIMING order sent in the current Core L1 block has not yet been processed.
    function requireNoOrderInFlight() internal view {
        if (isOrderInFlight()) revert HyperCoreOrderInFlight(get().lastOrderL1Block);
    }

    /// @notice Reverts when a TIMING order was already sent in the current Core L1 block.
    function requireOrderRateLimit() internal view {
        if (isOrderInFlight()) revert HyperCoreOrderRateLimited(get().lastOrderL1Block);
    }

    /// @notice Record one in-flight Transfer that settles by time only (no cross-domain effect).
    /// @dev Transfer-only since IL-8543: orders and cancels are never enqueued.
    function enqueue(
        uint256 cachedValueWad_,
        uint64 windowSeconds_,
        uint24 actionId_,
        bytes32 payloadHash_
    ) internal {
        _enqueue(cachedValueWad_, windowSeconds_, actionId_, payloadHash_);
        _setEffect(EFFECT_NONE, 0, address(0), 0, 0);
        _emitEnqueued();
    }

    /// @notice Record an in-flight Transfer whose settlement additionally waits for its cross-domain effect.
    /// @dev Settles once the time window and L1 block gates pass AND the effect is observed (see
    ///      `isEffectObserved`), or unconditionally once `pendingUntil + timeoutSeconds_` has passed.
    /// @param effectKind_ `EFFECT_CORE_SPOT` or `EFFECT_EVM_BALANCE`
    /// @param tokenIndex_ Core token index (CoreSpot only)
    /// @param evmAsset_ ERC20 whose vault balance is observed (EvmBalance only)
    /// @param expectedBalance_ Balance (Core wei for CoreSpot, EVM units for EvmBalance) the effect must reach
    /// @param timeoutSeconds_ Seconds after `pendingUntil` at which the effect requirement is waived
    function enqueueTransferWithEffect(
        uint256 cachedValueWad_,
        uint64 windowSeconds_,
        uint24 actionId_,
        bytes32 payloadHash_,
        uint8 effectKind_,
        uint64 tokenIndex_,
        address evmAsset_,
        uint256 expectedBalance_,
        uint64 timeoutSeconds_
    ) internal {
        if (effectKind_ != EFFECT_CORE_SPOT && effectKind_ != EFFECT_EVM_BALANCE) {
            revert HyperCorePendingEffectInvalid(effectKind_);
        }
        _enqueue(cachedValueWad_, windowSeconds_, actionId_, payloadHash_);
        PendingAction storage pending = get();
        uint256 timeoutAt_ = uint256(pending.pendingUntil) + uint256(timeoutSeconds_);
        if (timeoutAt_ > type(uint64).max) revert HyperCorePendingWindowOverflow();
        _setEffect(effectKind_, tokenIndex_, evmAsset_, expectedBalance_, uint64(timeoutAt_));
        _emitEnqueued();
    }

    function _setEffect(
        uint8 effectKind_,
        uint64 tokenIndex_,
        address evmAsset_,
        uint256 expectedBalance_,
        uint64 timeoutAt_
    ) private {
        PendingAction storage pending = get();
        pending.effectKind = effectKind_;
        pending.effectTokenIndex = tokenIndex_;
        pending.effectEvmAsset = evmAsset_;
        pending.expectedBalance = expectedBalance_;
        pending.timeoutAt = timeoutAt_;
    }

    function _enqueue(
        uint256 cachedValueWad_,
        uint64 windowSeconds_,
        uint24 actionId_,
        bytes32 payloadHash_
    ) private {
        requireNotPendingAction();

        uint256 pendingUntil_ = block.timestamp + uint256(windowSeconds_);
        if (pendingUntil_ > type(uint64).max) revert HyperCorePendingWindowOverflow();

        PendingAction storage pending = get();
        unchecked {
            ++pending.actionNonce;
        }
        pending.pendingUntil = uint64(pendingUntil_);
        pending.enqueuedL1Block = HyperCoreLib.l1BlockNumber();
        pending.enqueuedEvmBlock = uint64(block.number);
        pending.actionClass = uint8(ActionClass.Transfer);
        pending.actionId = actionId_;
        pending.payloadHash = payloadHash_;
        pending.cachedValueWad = cachedValueWad_;
    }

    function _emitEnqueued() private {
        PendingAction storage pending = get();
        emit HyperCoreActionEnqueued(
            pending.actionNonce,
            pending.actionClass,
            uint8(0),
            pending.pendingUntil,
            pending.cachedValueWad,
            pending.enqueuedL1Block,
            pending.enqueuedEvmBlock,
            pending.actionId,
            pending.payloadHash
        );
    }

    function cachedValueWad() internal view returns (uint256) {
        return get().cachedValueWad;
    }

    /// @notice Clears a settled action, preserving its monotonic nonce.
    /// @dev Reverts with `HyperCoreActionNotSettled` when there is no record or its settlement condition does not
    ///      hold yet. No contract calls it; the pre-hooks clear through `settleIfReady()`.
    function clear() internal {
        PendingAction storage pending = get();
        if (pending.actionClass == uint8(ActionClass.None) || !isActionSettled()) {
            revert HyperCoreActionNotSettled();
        }
        _clearRecord();
    }

    /// @notice Latches settlement: clears the record once an action is observed settled.
    /// @dev Does not revert by itself, but propagates reverts of the reads behind the settlement predicate: a failed
    ///      precompile read (`HyperCorePrecompileFailed`, fail-closed by design) and, before `timeoutAt`, the effect
    ///      token's `balanceOf`. Does nothing (returns false) when there is no record or the settlement condition does
    ///      not hold.
    ///      Called first by the pre-hooks so that a later balance change (e.g. a user redeem lowering the EVM
    ///      balance after a Core -> EVM bridge settled) cannot re-open the pending state of a settled transfer.
    ///      Emits `HyperCoreActionSettled` exactly once per settled action.
    /// @return settled True when a record was cleared by this call
    function settleIfReady() internal returns (bool settled) {
        PendingAction storage pending = get();
        if (pending.actionClass == uint8(ActionClass.None) || !isActionSettled()) {
            return false;
        }
        _clearRecord();
        return true;
    }

    /// @dev Deletes every record field except `actionNonce` and `lastOrderL1Block`, then emits
    ///      `HyperCoreActionSettled`.
    function _clearRecord() private {
        PendingAction storage pending = get();
        uint256 nonce_ = pending.actionNonce;
        delete pending.pendingUntil;
        delete pending.enqueuedL1Block;
        delete pending.enqueuedEvmBlock;
        delete pending.actionClass;
        delete pending.deprecatedSettlementMode;
        delete pending.deprecatedReportedResult;
        delete pending.deprecatedResultL1Block;
        delete pending.actionId;
        delete pending.payloadHash;
        delete pending.deprecatedRefreshing;
        delete pending.cachedValueWad;
        delete pending.effectKind;
        delete pending.effectTokenIndex;
        delete pending.effectEvmAsset;
        delete pending.timeoutAt;
        delete pending.expectedBalance;
        emit HyperCoreActionSettled(nonce_);
    }
}
