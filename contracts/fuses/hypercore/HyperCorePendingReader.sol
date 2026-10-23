// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {HyperCorePendingLib} from "./lib/HyperCorePendingLib.sol";

/// @title HyperCorePendingReader
/// @notice Stateless read-only helper exposing the vault's HyperCore pending-action state
///         (`HyperCorePendingLib`) through `PlasmaVault`'s `UniversalReader` pattern.
/// @dev This contract is never called directly. It must be invoked through
///      `PlasmaVault.read(reader, abi.encodeCall(HyperCorePendingReader.pendingState, ()))`
///      (or `.isActionPending`), which delegatecalls it in the vault's own storage context so it can
///      read `HyperCorePendingLib`'s namespaced ERC-7201 slot. The ABI-encoded return value is
///      decoded from the resulting `ReadResult.data`.
///
///      Settled actions are evidence predicates, not state transitions: `enqueuedL1Block`,
///      `actionClass` and the rest of the raw `PendingAction` struct are left untouched by
///      settlement until a pre-hook latches it via `settleIfReady()`.
///      Inspecting the raw storage slot directly therefore cannot tell "pending" apart from "settled but not yet cleared" — `isActionSettled()`/`isActionPending()` are
///      the only correct predicates. This reader is the authoritative source of that predicate for
///      off-chain consumers such as the action broadcaster's preflight check;
///      they must call it instead of decoding the raw slot themselves.
contract HyperCorePendingReader {
    /// @notice Address of the HyperCore L1-block-number read precompile.
    /// @dev Mirrors `HyperCoreLib.L1_BLOCK_NUMBER_PRECOMPILE`, which is private to that library.
    ///      Queried here via a low-level `staticcall` (rather than `HyperCoreLib.l1BlockNumber()`)
    ///      so a revert (e.g. on a fork where the precompile is unavailable) can be caught and
    ///      surfaced as `l1BlockAvailable == false` instead of reverting the whole read. The fallback covers
    ///      only this 0x809 read and the predicates evaluated after it: when a pending record exists and the
    ///      probe failed, `pendingState()` does not evaluate the library predicates and reports the action as pending.
    address internal constant L1_BLOCK_NUMBER_PRECOMPILE = 0x0000000000000000000000000000000000000809;

    /// @notice Bundled return payload of `pendingState()`.
    /// @dev Solidity's legacy (non-IR) ABI encoder hits "stack too deep" when `pendingState()`
    ///      returns the `PendingAction` struct alongside six more loose scalars (via_ir is
    ///      forbidden in this repository's Foundry builds). Bundling every field into a single
    ///      struct keeps the encoder to one memory pointer instead of seven live return slots.
    ///      The wire-level ABI encoding is a tuple of the same types in the same order either way,
    ///      so callers decode `abi.decode(result.data, (PendingStateResult))`.
    struct PendingStateResult {
        HyperCorePendingLib.PendingAction state;
        bool actionPending;
        bool actionSettled;
        uint64 currentL1Block;
        uint64 currentTimestamp;
        bool l1BlockAvailable;
    }

    /// @notice Returns the full pending-action snapshot together with the derived predicates.
    /// @dev Field meanings (see `PendingStateResult`):
    ///      - `state`: the raw `HyperCorePendingLib.PendingAction` struct, as stored in the vault.
    ///      - `actionPending`: whether `HyperCorePendingLib.isActionPending()` currently blocks ordinary vault calls.
    ///      - `actionSettled`: whether `HyperCorePendingLib.isActionSettled()` (the settlement-condition predicate).
    ///      - `currentL1Block`: the current HyperCore L1 block number, or 0 if unavailable.
    ///      - `currentTimestamp`: the current EVM block timestamp (`block.timestamp`).
    ///      - `l1BlockAvailable`: whether the L1-block-number precompile call succeeded.
    ///
    ///      When `l1BlockAvailable == false` and a pending record exists (`state.actionClass != None`), the library
    ///      predicates are not evaluated (they would revert on the unavailable 0x809) and the result fails closed:
    ///      `actionPending = true`, `actionSettled = false`, matching the chain, where the pre-hooks revert and the
    ///      vault stays blocked. With no record the predicates are evaluated as usual (`false` / `true`).
    ///      The fallback covers 0x809 only. The effect read is evaluated only after the time and L1-block gates pass
    ///      and only before `timeoutAt` (once `timeoutAt` has passed the effect is not read). In that window it can
    ///      still revert `pendingState()` for both effect kinds: the 0x810/0x801 precompile reads of an
    ///      `EFFECT_CORE_SPOT` record and the effect token's `balanceOf` of an `EFFECT_EVM_BALANCE` record.
    function pendingState() external view returns (PendingStateResult memory result) {
        result.state = HyperCorePendingLib.get();
        result.currentTimestamp = uint64(block.timestamp);
        (result.l1BlockAvailable, result.currentL1Block) = _tryL1BlockNumber();
        if (result.l1BlockAvailable || result.state.actionClass == uint8(HyperCorePendingLib.ActionClass.None)) {
            result.actionPending = HyperCorePendingLib.isActionPending();
            result.actionSettled = HyperCorePendingLib.isActionSettled();
        } else {
            result.actionPending = true;
            result.actionSettled = false;
        }
    }

    /// @notice Whether a HyperCore action currently blocks ordinary vault calls.
    /// @dev Thin wrapper around `HyperCorePendingLib.isActionPending()`; see the contract-level NatSpec
    ///      for why this predicate (not the raw slot) is authoritative. Unlike `pendingState()` it has no 0x809
    ///      fallback: with a record whose `pendingUntil` has passed and a failing precompile it reverts
    ///      `HyperCoreLib.HyperCorePrecompileFailed`. Off-chain consumers should use `pendingState()`.
    function isActionPending() external view returns (bool) {
        return HyperCorePendingLib.isActionPending();
    }

    /// @notice Whether a TIMING order sent in the current Core L1 block is still unprocessed (capital-flow mini-gate).
    /// @dev Independent of `isActionPending()`; `state.lastOrderL1Block` in `pendingState()` exposes the raw value.
    function isOrderInFlight() external view returns (bool) {
        return HyperCorePendingLib.isOrderInFlight();
    }

    /// @dev Low-level staticcall to the L1-block-number precompile so a revert does not propagate.
    function _tryL1BlockNumber() private view returns (bool ok, uint64 blockNumber) {
        (bool success, bytes memory returnData) = L1_BLOCK_NUMBER_PRECOMPILE.staticcall(bytes(""));
        if (!success || returnData.length < 32) {
            return (false, 0);
        }
        return (true, abi.decode(returnData, (uint64)));
    }
}
