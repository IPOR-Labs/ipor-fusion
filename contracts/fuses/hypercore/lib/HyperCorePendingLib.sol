// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {HyperCoreLib} from "./HyperCoreLib.sol";
import {PlasmaVaultLib} from "../../../libraries/PlasmaVaultLib.sol";
import {IRewardsClaimManager, VestingData} from "../../../interfaces/IRewardsClaimManager.sol";

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

    /// @dev Lower bound for `Config{WindowTransferSeconds}`, enforced by every fuse that reads it (send, deposit,
    ///      margin, builder fee): a smaller value reverts with the fuse's `<Fuse>InvalidWindow` error; unset = 2.
    ///      A window of 1 s could pass the time gate in the EVM block in which a Core debit is already visible while
    ///      its Core -> EVM credit is still queued for the next block (IL-8927, IL-9529).
    uint64 internal constant MIN_WINDOW_TRANSFER_SECONDS = 2;

    /// @dev Transfer without a cross-domain effect to wait for (time-based settlement only).
    uint8 internal constant EFFECT_NONE = 0;
    /// @dev Settles only once the vault's Core spot balance of `effectTokenIndex` reaches `expectedBalance`.
    uint8 internal constant EFFECT_CORE_SPOT = 1;
    /// @dev Settles only once the vault's EVM balance of `effectEvmAsset` reaches `expectedBalance` (plus, for a record
    ///      bound to the rewards manager by `bindRewardsEffect`, the manager's pushes since the send) and both rewards
    ///      sums reach their thresholds (see `isEffectObserved`).
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
        // Rewards-manager binding of an `EFFECT_EVM_BALANCE` record (appended, IL-9529; new in this release, so its
        // order is set here once: `effectRewardsUpdateBalanceTimestamp` fills the last 4 bytes of the
        // `lastOrderL1Block` + `effectRewardsManager` slot, the two counter fields share one new slot). Zeroed by
        // every enqueue, written only by `bindRewardsEffect`, deleted by `_clearRecord`. Both sums are thresholds
        // like `expectedBalance`, read before the action is sent and including the bridged amount A:
        // `expectedRewardsRawSum = vault balance + manager's token balance + A` and
        // `expectedRewardsVestedSum = vault balance + IRewardsClaimManager.balanceOf() + A`.
        // The three `effectRewards*` vesting fields are the manager's `getVestingData()` at send:
        // `updateBalanceTimestamp`, `transferredTokens` (the push counter) and `lastUpdateBalance`.
        address effectRewardsManager;
        uint32 effectRewardsUpdateBalanceTimestamp;
        uint256 expectedRewardsRawSum;
        uint256 expectedRewardsVestedSum;
        uint128 effectRewardsTransferredTokens;
        uint128 effectRewardsLastUpdateBalance;
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
    ///      `EFFECT_EVM_BALANCE` first requires `balanceOf(vault) >= expectedBalance`. When the bridged token is the
    ///      vault's underlying and a rewards manager was set at send time, the record is bound to that manager
    ///      (`effectRewardsManager != address(0)`, IL-9529) and holds its `getVestingData()` at send. The
    ///      manager's pushes into the vault (PUBLIC_ROLE `transferVestedTokensToVault`, and the push inside the
    ///      keeper's `updateBalance` or an ATOMIST reschedule) move underlying that NAV already counts, and the
    ///      manager adds every PUBLIC push to `transferredTokens`. The bound record is observed only when all of:
    ///      - the vault's rewards manager is still `effectRewardsManager` (a change inside the window waits for
    ///        `timeoutAt`);
    ///      - the schedule was not re-anchored: `updateBalanceTimestamp` and `lastUpdateBalance` are unchanged and
    ///        `transferredTokens` did not go down (`updateBalance` and `rescheduleVesting` re-anchor; keeper and
    ///        ATOMIST only, the wait for `timeoutAt` is the exit);
    ///      - `balanceOf(vault) >= expectedBalance + (transferredTokens - effectRewardsTransferredTokens)`: the vault
    ///        balance minus the counted pushes grew by A;
    ///      - `balanceOf(vault) + balanceOf(manager) >= expectedRewardsRawSum` and
    ///        `balanceOf(vault) + IRewardsClaimManager(manager).balanceOf() >= expectedRewardsVestedSum` (D-004).
    ///      So before `timeoutAt` neither a push, nor vesting accrual, nor underlying sent to the manager (a donation
    ///      or a keeper claim), nor any combination of them can stand in for the credit: they move the manager's
    ///      balance or the counted pushes, not the vault balance net of pushes. What still opens the gate early is the
    ///      credit or underlying sent straight to the vault (a donation, priced in NAV, so the donor pays at least
    ///      what the early opening is worth). The two sums are implied by the counter rule for a standard
    ///      RewardsClaimManager; they stay as defence in depth for a push the counter does not see (a non-standard
    ///      manager, or the same-second re-anchor with `vestingTime == 0`, where only underlying new to the manager
    ///      can then pass them).
    ///      An unbound record of the vault's underlying (no rewards manager at send) is not observed while a rewards
    ///      manager is set, so a manager set inside the window also waits for `timeoutAt`. Without a rewards manager,
    ///      or for another token, the effect is the plain vault-balance threshold.
    ///      The manager reads (`getVestingData()`, the token's `balanceOf(manager)`, `balanceOf()`) are not guarded:
    ///      a reverting manager reverts the predicate like a reverting effect token (until `timeoutAt`). An ATOMIST
    ///      vesting change that lowers `balanceOf()` can hold the vested sum short until `timeoutAt`. Pricing safety
    ///      while Core lags still rests on the time and L1-block gates and on
    ///      `WindowTransferSeconds >= MIN_WINDOW_TRANSFER_SECONDS` (2, enforced by the fuses).
    function isEffectObserved() internal view returns (bool) {
        PendingAction storage pending = get();
        if (pending.effectKind == EFFECT_CORE_SPOT) {
            return
                HyperCoreLib.coreUserExists(address(this)) &&
                HyperCoreLib.spotBalance(address(this), pending.effectTokenIndex).total >= pending.expectedBalance;
        }
        if (pending.effectKind == EFFECT_EVM_BALANCE) {
            uint256 vaultBalance = IERC20(pending.effectEvmAsset).balanceOf(address(this));
            if (vaultBalance < pending.expectedBalance) return false;
            address rewardsManager = pending.effectRewardsManager;
            if (rewardsManager == address(0)) {
                // Unbound: a rewards manager set inside the window could push underlying NAV already counts.
                return
                    PlasmaVaultLib.getRewardsClaimManagerAddress() == address(0) ||
                    pending.effectEvmAsset != IERC4626(address(this)).asset();
            }
            return _isRewardsEffectObserved(pending, rewardsManager, vaultBalance);
        }
        return false;
    }

    /// @dev The bound part of `isEffectObserved` (IL-9529, D-034): same manager, same anchor, the vault balance net of
    ///      the counted pushes reached `expectedBalance`, and both D-004 sums reached their thresholds.
    function _isRewardsEffectObserved(
        PendingAction storage pending_,
        address rewardsManager_,
        uint256 vaultBalance_
    ) private view returns (bool) {
        if (PlasmaVaultLib.getRewardsClaimManagerAddress() != rewardsManager_) return false;
        VestingData memory vesting = IRewardsClaimManager(rewardsManager_).getVestingData();
        if (
            vesting.updateBalanceTimestamp != pending_.effectRewardsUpdateBalanceTimestamp ||
            vesting.lastUpdateBalance != pending_.effectRewardsLastUpdateBalance ||
            vesting.transferredTokens < pending_.effectRewardsTransferredTokens
        ) {
            return false;
        }
        if (
            vaultBalance_ <
            pending_.expectedBalance + uint256(vesting.transferredTokens - pending_.effectRewardsTransferredTokens)
        ) {
            return false;
        }
        // Raw sum: flat under a push and under accrual. Vested sum: flat under a push and under unvested inflows.
        return
            vaultBalance_ + IERC20(pending_.effectEvmAsset).balanceOf(rewardsManager_) >=
                pending_.expectedRewardsRawSum &&
            vaultBalance_ + IRewardsClaimManager(rewardsManager_).balanceOf() >= pending_.expectedRewardsVestedSum;
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
    ///      `isEffectObserved`), or unconditionally once `pendingUntil + timeoutSeconds_` has passed. Zeroes the
    ///      rewards-manager binding; a Core -> EVM bridge of the underlying binds it afterwards (`bindRewardsEffect`).
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

    /// @notice Binds the pending `EFFECT_EVM_BALANCE` record to the vault's rewards manager (IL-9529).
    /// @dev Called only by `HyperCoreSendFuse` right after `enqueueTransferWithEffect`, when the bridged token is the
    ///      vault's underlying and a rewards manager is set. Both sums are thresholds read before the action is sent
    ///      and include the bridged amount A; `vesting_` is the manager's `getVestingData()` read at the same time, so
    ///      the gate can subtract the manager's pushes and see a re-anchor (see `isEffectObserved`).
    /// @param rewardsManager_ Rewards manager whose pushes move already-counted underlying into the vault
    /// @param expectedRawSum_ Vault balance + the manager's balance of the effect token + A
    /// @param expectedVestedSum_ Vault balance + `IRewardsClaimManager.balanceOf()` + A
    /// @param vesting_ The manager's vesting data at send (`updateBalanceTimestamp`, `transferredTokens`,
    ///        `lastUpdateBalance` are stored; `vestingTime` is not needed: it changes no push and no anchor)
    function bindRewardsEffect(
        address rewardsManager_,
        uint256 expectedRawSum_,
        uint256 expectedVestedSum_,
        VestingData memory vesting_
    ) internal {
        PendingAction storage pending = get();
        if (pending.effectKind != EFFECT_EVM_BALANCE) revert HyperCorePendingEffectInvalid(pending.effectKind);
        pending.effectRewardsManager = rewardsManager_;
        pending.effectRewardsUpdateBalanceTimestamp = vesting_.updateBalanceTimestamp;
        pending.expectedRewardsRawSum = expectedRawSum_;
        pending.expectedRewardsVestedSum = expectedVestedSum_;
        pending.effectRewardsTransferredTokens = vesting_.transferredTokens;
        pending.effectRewardsLastUpdateBalance = vesting_.lastUpdateBalance;
    }

    /// @dev Writes the effect fields of a new record and zeroes the rewards-manager binding, so a settled but not yet
    ///      cleared record can never leave a binding behind for the next enqueue.
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
        pending.effectRewardsManager = address(0);
        pending.effectRewardsUpdateBalanceTimestamp = 0;
        pending.expectedRewardsRawSum = 0;
        pending.expectedRewardsVestedSum = 0;
        pending.effectRewardsTransferredTokens = 0;
        pending.effectRewardsLastUpdateBalance = 0;
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
    ///      token's `balanceOf` and, for a record bound to the rewards manager, the manager reads (`getVestingData()`,
    ///      `balanceOf()`). Does nothing (returns false) when there is no record or the settlement condition does not
    ///      hold.
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
        delete pending.effectRewardsManager;
        delete pending.effectRewardsUpdateBalanceTimestamp;
        delete pending.expectedRewardsRawSum;
        delete pending.expectedRewardsVestedSum;
        delete pending.effectRewardsTransferredTokens;
        delete pending.effectRewardsLastUpdateBalance;
        emit HyperCoreActionSettled(nonce_);
    }
}
