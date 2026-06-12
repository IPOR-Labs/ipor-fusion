# IL-7311 — RequestFeeRefundFuse Implementation Plan

## 1. Feature Overview

**Goal.** Provide a governance-callable fuse that **refunds** request-fee shares
held by `WithdrawManager` to a specific user instead of burning them via
`BurnRequestFeeFuse`.

Current behaviour (`BurnRequestFeeFuse`):

- reads `PlasmaVaultStorageLib.getWithdrawManager().manager`,
- calls `PlasmaVaultBase.updateInternal(withdrawManager, address(0), amount)`
  via delegatecall — the `WithdrawManager`'s shares are **burned** (destination
  is `address(0)`).

New behaviour (`RequestFeeRefundFuse`):

- same source of shares (`withdrawManager`),
- destination is an arbitrary `recipient` supplied by the caller,
- **precondition:** the recipient's withdraw request **must be expired** at the
  time of execution. "Expired" is defined by strict inequality
  `block.timestamp > request.endWithdrawWindowTimestamp` on the live
  `WithdrawManager.requestInfo(recipient)` view. A recipient that never
  requested anything (i.e. `endWithdrawWindowTimestamp == 0`) is also
  rejected. This avoids refunding a user who is still within an active
  withdraw window and could otherwise double-dip (first request with a fee,
  then reclaim the fee before the window even closes).

The fuse is stateless, runs under `delegatecall` from `PlasmaVault.execute`,
and routes the share movement through `PlasmaVaultBase.updateInternal` so that
ERC20Votes checkpoints and supply-cap invariants stay consistent (same pattern
as `BurnRequestFeeFuse` after the IL-6952 voting-checkpoint fix, and the same
reason the regression test `BurnRequestFeeVotingRegressionTest.t.sol` exists).

Access stays as-is: the fuse is executed through `PlasmaVault.execute` under
the same role that runs `BurnRequestFeeFuse` today (ALPHA). No new roles, no
changes to `IporFusionAccessManagerInitializerLibV1`.

## 2. Architecture Decisions

### 2.1 Why a new fuse and not a new entry on `BurnRequestFeeFuse`

- Fuses are versioned immutables (`VERSION = address(this)`). Adding a second
  `enter` overload changes the ABI surface and, more importantly, pulls a
  different operational semantics (burn vs. transfer-to-user) into the same
  contract. Separate fuse keeps:
  - clean `VERSION` trail for audits,
  - granular governance: a vault can enable burn but disable refund (or vice
    versa) via `FuseManager`,
  - independent access wiring if desired later.

### 2.2 Where the fuse lives

- **Path:** `contracts/fuses/burn_request_fee/RequestFeeRefundFuse.sol`
  - co-located with `BurnRequestFeeFuse.sol`; both fuses operate on the same
    request-fee shares held by `WithdrawManager`, so they live side-by-side
    under `burn_request_fee/`.
- **Market ID:** reuse the same market id that `BurnRequestFeeFuse` is
  deployed under (request-fee market). Decision will be finalised during
  deployment wiring — the fuse only stores `MARKET_ID` as immutable and does
  not depend on any specific value internally.

### 2.3 Source of truth for "expired request"

`WithdrawManager` exposes a view-only aggregate:

```solidity
function requestInfo(address account_) external view returns (WithdrawRequestInfo memory);

struct WithdrawRequestInfo {
    uint256 shares;
    uint256 endWithdrawWindowTimestamp;
    bool    canWithdraw;
    uint256 withdrawWindowInSeconds;
}
```

The fuse reads it and treats the request as **expired** iff:

- `endWithdrawWindowTimestamp != 0` (a request exists), **and**
- `block.timestamp > endWithdrawWindowTimestamp` (strict `>`).

**Why not the storage library?** `WithdrawManagerStorageLib` uses hard-coded
storage slots scoped to the `WithdrawManager` contract (ERC-7201-style). The
fuse executes under `delegatecall` in **PlasmaVault's** storage context, so
reading via the library would target the wrong contract. `requestInfo(...)`
is a regular external view on `WithdrawManager` and is the only correct way
to reach that namespace from the fuse.

**Why strict `>`?** `WithdrawManager._canWithdrawFromRequest` uses
`block.timestamp <= endWithdrawWindowTimestamp`, i.e. the request is still
valid **including** the boundary second. Using strict `>` in the fuse
guarantees there is no overlap: at `block.timestamp == endWithdrawWindowTimestamp`
the user can still withdraw via `WithdrawManager`, so the fuse must refuse
the refund — otherwise the user could withdraw and get refunded in the same
block.

**Why require `endWithdrawWindowTimestamp != 0`?** Default struct values
would otherwise satisfy `block.timestamp > 0`, and a fresh address that
never requested anything would pass the check. The explicit guard keeps the
semantic "user had a request, it expired".

### 2.4 How shares are moved

Same vehicle as `BurnRequestFeeFuse`, only with a non-zero destination:

```solidity
PlasmaVaultStorageLib.getPlasmaVaultBase().functionDelegateCall(
    abi.encodeWithSelector(
        IPlasmaVaultBase.updateInternal.selector,
        withdrawManager,   // from
        recipient,         // to  (non-zero, expired request)
        amount
    )
);
```

Routing through `updateInternal` (which calls `_update`) is required so that
`ERC20VotesUpgradeable` checkpoints are updated on both sides of the transfer
— exactly the pitfall that `BurnRequestFeeVotingRegressionTest.t.sol`
documents for the burn case. No new functions or access-manager entries are
introduced; the fuse reuses the existing generic vehicle.

### 2.5 No storage, no transient, no exit

- No storage variables (stateless fuse, runs via delegatecall).
- No `enterTransient`/`exitTransient` — this fuse is not meant for transient
  input chaining.
- `exit()` reverts with `RequestFeeRefundExitNotImplemented`, mirroring
  `BurnRequestFeeFuse`.

### 2.6 Amount semantics

- Caller passes explicit `amount` so governance can partially refund (for
  example the fee split across multiple users).
- `amount == 0` is a no-op, for parity with `BurnRequestFeeFuse` — the
  function returns immediately without validating the recipient or emitting
  an event.
- Capping to `ERC20(address(this)).balanceOf(withdrawManager)` happens
  organically: if `_update` underflows the balance, the standard OpenZeppelin
  `ERC20InsufficientBalance(sender, balance, needed)` error bubbles up. No
  pre-check is added.

### 2.7 Recipient guards

- `recipient == address(0)` ⇒ explicit revert
  `RequestFeeRefundInvalidRecipient`. Without the guard, `updateInternal`
  would burn the shares, which is semantically the job of `BurnRequestFeeFuse`
  — we refuse to silently drift into burn semantics.
- `recipient == withdrawManager` is **not** guarded explicitly — it naturally
  fails via `RequestFeeRefundNoActiveRequest`, because the withdraw manager
  never calls `requestShares` on itself and therefore has no `WithdrawRequest`
  entry.

### 2.8 Request lifecycle after refund

The recipient's `WithdrawRequest` is left **untouched** by the refund. Example
trace: user requested 100 shares with fee 5, so `request.shares = 95` and
`WithdrawManager` holds 5 shares. Once the window expires and governance
refunds 5 shares to the user, the user's request still reads 95 pending
shares — but the window is closed, so `WithdrawManager.canWithdrawFromRequest`
returns `false`. Cleanup of the stale request is a separate concern (user
opens a new request, or governance sweeps via a separate mechanism) and is
out of scope for this fuse. Keeping the fuse responsible only for moving fee
shares avoids a cross-contract write path and keeps the access-manager
surface unchanged.

## 3. Files to Create / Modify

### Created

| File | Purpose |
|------|---------|
| `contracts/fuses/burn_request_fee/RequestFeeRefundFuse.sol` | New fuse contract |
| `test/fuses/burn_request_fee/RequestFeeRefundFuseTest.t.sol` | Foundry fork-based tests (same style as `BurnRequestFeeVotingRegressionTest.t.sol`) |

### Modified

None. `PlasmaVaultBase.updateInternal`, `PlasmaVaultStorageLib.getWithdrawManager`,
`PlasmaVaultStorageLib.getPlasmaVaultBase`, `IPlasmaVaultBase` and
`WithdrawManager.requestInfo` already provide everything the fuse consumes.

## 4. Contract Layout

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuse.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {IPlasmaVaultBase} from "../../interfaces/IPlasmaVaultBase.sol";
import {
    WithdrawManager,
    WithdrawRequestInfo
} from "../../managers/withdraw/WithdrawManager.sol";

/**
 * @title RequestFeeRefundFuse - Fuse for Refunding Request Fee Shares
 * @notice Specialized fuse contract that refunds request-fee shares collected
 *         by WithdrawManager to a user whose withdraw request has already
 *         expired. Counterpart to BurnRequestFeeFuse.
 * @dev Routes the share transfer through PlasmaVaultBase.updateInternal so
 *      that ERC20Votes checkpoints and supply-cap validations stay
 *      consistent — the same pattern that was mandated for the burn path in
 *      IL-6952 (audit R4H7) and is covered by
 *      BurnRequestFeeVotingRegressionTest.
 *
 * Execution Context:
 * - All fuse operations are executed via delegatecall from PlasmaVault.
 * - Storage operations affect PlasmaVault's state, not the fuse contract.
 * - msg.sender refers to the caller of PlasmaVault.execute.
 * - address(this) refers to PlasmaVault's address during execution.
 *
 * Inheritance Structure:
 * - IFuseCommon: Base fuse interface implementation.
 *
 * Core Features:
 * - Refunds fee shares from WithdrawManager to a specified recipient.
 * - Enforces that the recipient's WithdrawRequest has expired (strict `>`
 *   against endWithdrawWindowTimestamp).
 * - Routes transfer through the vault's _update pipeline for proper hook
 *   execution.
 * - Maintains version and market tracking.
 * - Implements fuse enter/exit pattern (exit reverts).
 *
 * Integration Points:
 * - PlasmaVault: Main vault interaction (via delegatecall).
 * - PlasmaVaultBase: Token state management (via nested delegatecall).
 * - WithdrawManager: Source of fee shares and authority on request expiry.
 * - Fuse System: Execution framework.
 *
 * Security Considerations:
 * - Transfer routes through vault's _update pipeline to maintain voting
 *   checkpoints on both the withdraw manager and the recipient.
 * - Recipient guard against address(0) prevents accidental burn semantics.
 * - Strict-`>` expiry check prevents double-dip with active withdraw
 *   requests (WithdrawManager uses inclusive `<=` on the boundary).
 * - No storage variables; fuse is stateless.
 * - Amount overflow bounded by ERC20 balance of WithdrawManager.
 * - Delegatecall targets are hard-coded storage reads from
 *   PlasmaVaultStorageLib (WithdrawManager and PlasmaVaultBase slots).
 */

/// @notice Data structure for the enter function parameters
/// @param recipient Address that will receive the refunded fee shares.
///                  Must have a previously submitted withdraw request whose
///                  window has strictly expired.
/// @param amount    Amount of fee shares to refund. `0` is a no-op.
struct RequestFeeRefundDataEnter {
    address recipient;
    uint256 amount;
}

/// @title RequestFeeRefundFuse
/// @notice Contract responsible for refunding request fee shares from
///         PlasmaVault's WithdrawManager to a user with an expired request.
contract RequestFeeRefundFuse is IFuseCommon {
    using Address for address;

    /// @notice Thrown when WithdrawManager address is not set in PlasmaVault.
    error RequestFeeRefundWithdrawManagerNotSet();

    /// @notice Thrown when the recipient address is address(0).
    /// @dev Guards against drifting into BurnRequestFeeFuse semantics.
    error RequestFeeRefundInvalidRecipient();

    /// @notice Thrown when the recipient has never submitted a withdraw request.
    /// @param recipient The recipient address with no prior request.
    error RequestFeeRefundNoActiveRequest(address recipient);

    /// @notice Thrown when the recipient's withdraw request has not yet expired.
    /// @param recipient                   Recipient address whose request is still active.
    /// @param endWithdrawWindowTimestamp  Stored expiry of the recipient's request.
    /// @param nowTimestamp                `block.timestamp` at the time of the call.
    error RequestFeeRefundRequestStillActive(
        address recipient,
        uint256 endWithdrawWindowTimestamp,
        uint256 nowTimestamp
    );

    /// @notice Thrown when exit function is called (not implemented).
    error RequestFeeRefundExitNotImplemented();

    /// @notice Emitted when request fee shares are refunded to a recipient.
    /// @param version                    Address of the fuse contract version.
    /// @param recipient                  Address that received the refund (indexed).
    /// @param amount                     Amount of shares transferred.
    /// @param endWithdrawWindowTimestamp Expiry timestamp of the recipient's request
    ///                                   at the time of refund.
    event RequestFeeRefundEnter(
        address version,
        address indexed recipient,
        uint256 amount,
        uint256 endWithdrawWindowTimestamp
    );

    /// @notice Address of this fuse contract version.
    /// @dev Immutable value set in constructor; equals `address(this)`.
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on.
    /// @dev Immutable value set in constructor.
    uint256 public immutable MARKET_ID;

    /// @notice Initializes the RequestFeeRefundFuse contract.
    /// @param marketId_ The market ID this fuse will operate on.
    constructor(uint256 marketId_) {
        VERSION   = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Refunds request-fee shares from WithdrawManager to `recipient`.
    /// @dev Routes through PlasmaVaultBase.updateInternal via delegatecall to
    ///      ensure ERC20Votes checkpoint updates on both sides.
    ///
    /// Operation Flow:
    /// - Zero-amount: immediate return, no-op (parity with BurnRequestFeeFuse).
    /// - Validates recipient is non-zero.
    /// - Verifies WithdrawManager is set in PlasmaVault.
    /// - Reads recipient's WithdrawRequest via WithdrawManager.requestInfo.
    /// - Requires a request to exist AND `block.timestamp >
    ///   endWithdrawWindowTimestamp` (strict).
    /// - Transfers `amount` shares from WithdrawManager to recipient via
    ///   delegatecall to PlasmaVaultBase.updateInternal.
    /// - Emits RequestFeeRefundEnter.
    ///
    /// Security:
    /// - Routes through vault's _update pipeline to maintain voting
    ///   checkpoints on both WithdrawManager and recipient.
    /// - Checks WithdrawManager existence.
    /// - Validates recipient against address(0).
    /// - Validates request existence and expiry.
    ///
    /// @param data_ Struct containing the recipient and the amount to refund.
    /// @dev IMPORTANT: The fuse reads the WITHDRAW_MANAGER storage slot via
    /// PlasmaVaultStorageLib.getWithdrawManager(). This slot was corrected in
    /// IL-6952 (audit R4H7) to avoid collision with CALLBACK_HANDLER. Any
    /// changes to that slot must be coordinated with all fuses that access
    /// it, because fuses execute via delegatecall in the PlasmaVault storage
    /// context.
    function enter(RequestFeeRefundDataEnter memory data_) public {
        if (data_.amount == 0) {
            return;
        }

        if (data_.recipient == address(0)) {
            revert RequestFeeRefundInvalidRecipient();
        }

        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;
        if (withdrawManager == address(0)) {
            revert RequestFeeRefundWithdrawManagerNotSet();
        }

        WithdrawRequestInfo memory info = WithdrawManager(withdrawManager).requestInfo(data_.recipient);

        if (info.endWithdrawWindowTimestamp == 0) {
            revert RequestFeeRefundNoActiveRequest(data_.recipient);
        }

        if (block.timestamp <= info.endWithdrawWindowTimestamp) {
            revert RequestFeeRefundRequestStillActive(
                data_.recipient,
                info.endWithdrawWindowTimestamp,
                block.timestamp
            );
        }

        PlasmaVaultStorageLib.getPlasmaVaultBase().functionDelegateCall(
            abi.encodeWithSelector(
                IPlasmaVaultBase.updateInternal.selector,
                withdrawManager,
                data_.recipient,
                data_.amount
            )
        );

        emit RequestFeeRefundEnter(
            VERSION,
            data_.recipient,
            data_.amount,
            info.endWithdrawWindowTimestamp
        );
    }

    /// @notice Exit function (not implemented).
    /// @dev Always reverts; this fuse only supports refunding via `enter`.
    function exit() external pure {
        revert RequestFeeRefundExitNotImplemented();
    }
}
```

Notes:

- `IFuseCommon` requires `enter` and `exit` — we provide both; `exit` reverts.
- `enterTransient`/`exitTransient` are intentionally omitted.
- `MARKET_ID` is provided via constructor, matching `BurnRequestFeeFuse`.

## 5. Implementation Steps

- [ ] **Step 1.** Create `RequestFeeRefundFuse.sol` in
      `contracts/fuses/burn_request_fee/` per §4 (full NatSpec, strict-`>`
      expiry check, recipient guard, read via `WithdrawManager.requestInfo`).
- [ ] **Step 2.** Run `forge build` inside the worktree. Resolve lint notes
      only for files we own; don't touch unrelated lint noise from `main`.
- [ ] **Step 3.** Create `test/fuses/burn_request_fee/RequestFeeRefundFuseTest.t.sol`
      per §6 (fork-based, modelled on `BurnRequestFeeVotingRegressionTest`).
- [ ] **Step 4.** `forge test --match-path test/fuses/burn_request_fee/RequestFeeRefundFuseTest.t.sol -vv`.
- [ ] **Step 5.** `forge test` in full to confirm no regression — in
      particular `BurnRequestFeeVotingRegressionTest.t.sol` must still pass.
- [ ] **Step 6.** `forge coverage --match-path 'test/fuses/burn_request_fee/RequestFeeRefundFuseTest.t.sol'`
      and confirm ≥ 98% line/branch on the fuse file.
- [ ] **Step 7.** Self-review via
      `/review-branch feature/IL-7311-request-fee-refund-fuse`.

## 6. Test Plan

Style: fork-based test suite. The real stack template is
`test/vaults/PlasmaVaultScheduledWithdraw.t.sol` — it forks Arbitrum, spins
up a real `PlasmaVault` + `WithdrawManager` + `AccessManager`, wires
`BurnRequestFeeFuse` + `UpdateWithdrawManagerMaintenanceFuse` via
`PlasmaVaultConfigurator`, and submits `FuseAction` via
`PlasmaVault.execute`. Reuse that scaffolding, add
`RequestFeeRefundFuse` to the fuse set, and exercise it from tests. For the
voting-checkpoint regression (§6.3) additionally reuse the mock-based
pattern from `test/vaults/BurnRequestFeeVotingRegressionTest.t.sol`. File
path: `test/fuses/burn_request_fee/RequestFeeRefundFuseTest.t.sol`.

### 6.1 Happy paths

1. `testEnter_refundsSharesFromWithdrawManagerToRecipient_whenRequestExpired`
   - Setup: user U calls `requestShares(X)` with a non-zero request fee, so
     `WithdrawManager` holds `feeAmount` shares and U has a `WithdrawRequest`
     with `endWithdrawWindowTimestamp = ts1`.
   - `vm.warp(ts1 + 1)` to expire the window.
   - Governance executes `RequestFeeRefundFuse.enter({recipient: U, amount: feeAmount})`
     through `PlasmaVault.execute`.
   - Assertions:
     - `balanceOf(U)` increased by `feeAmount`,
     - `balanceOf(withdrawManager)` decreased by `feeAmount`,
     - `getVotes(U)` increased by `feeAmount`,
     - `getVotes(withdrawManager)` decreased by `feeAmount`,
     - Event `RequestFeeRefundEnter(version, U, feeAmount, ts1)` emitted.

2. `testEnter_partialRefund_allowsMultipleCalls`
   - Two successive refunds of `feeAmount / 2` to the same expired recipient.
   - Balances and votes move by the expected delta each time.

3. `testEnter_refundToDifferentRecipient_whenRecipientExpired`
   - User A requests (then expires). User B requests (still inside window).
   - Refund to A ⇒ OK.
   - Refund to B ⇒ reverts with `RequestFeeRefundRequestStillActive(B, …)`.

### 6.2 Reverts / branches

4. `testEnter_reverts_whenRecipientIsZero`
   - `enter({recipient: 0, amount: X})` ⇒ `RequestFeeRefundInvalidRecipient`.

5. `testEnter_reverts_whenRecipientHasNoRequest`
   - Fresh address with no prior `requestShares` ⇒
     `RequestFeeRefundNoActiveRequest(recipient)`.

6. `testEnter_reverts_whenRecipientIsWithdrawManager`
   - `enter({recipient: withdrawManager, amount: X})` ⇒
     `RequestFeeRefundNoActiveRequest(withdrawManager)` — documents that the
     withdraw-manager case is rejected *via the no-request branch*
     (no dedicated guard).

7. `testEnter_reverts_whenRequestStillActive`
   - Request created at `ts0`, no `vm.warp` ⇒
     `RequestFeeRefundRequestStillActive(recipient, ts0 + window, block.timestamp)`.

8. `testEnter_reverts_atExactExpiryBoundary`
   - `block.timestamp == endWithdrawWindowTimestamp` must still revert
     (strict `>`). Documents the boundary decision.

9. `testEnter_isNoOp_whenAmountZero`
   - Pre- and post-state identical, no event, no revert. Importantly: the
     zero-amount short-circuit runs **before** recipient / expiry validation,
     so passing `recipient = 0` alongside `amount = 0` must also be a no-op.

10. `testEnter_reverts_whenWithdrawManagerNotSet`
    - Vault configured without a `WithdrawManager` (or the slot zeroed in a
      fixture) ⇒ `RequestFeeRefundWithdrawManagerNotSet`.

11. `testEnter_reverts_whenAmountExceedsBalance`
    - Refund more than `withdrawManager` holds ⇒ OpenZeppelin
      `ERC20InsufficientBalance(sender, balance, needed)` bubbles up.
      Confirms there is no silent cap.

12. `testExit_reverts` ⇒ `RequestFeeRefundExitNotImplemented`.

### 6.3 Voting-checkpoint regression

Mirror `BurnRequestFeeVotingRegressionTest.t.sol` pattern — mocked
`PlasmaVaultBase` + `DelegateCaller` + `vm.store` of `WITHDRAW_MANAGER_SLOT`
and `PLASMA_VAULT_BASE_SLOT`, as regression against bypassing the vault's
`_update` pipeline:

13. `testFixedFuse_DOES_CallUpdateInternal`
    - Setup: deploy `MockPlasmaVaultBase`, `RequestFeeRefundFuse`, a
      `DelegateCaller`; `vm.store` the caller's WITHDRAW_MANAGER and
      PLASMA_VAULT_BASE slots with the mock manager / mock base addresses;
      seed the caller with request storage for the recipient (direct
      `vm.store` or re-use a real `WithdrawManager` fixture) such that
      `requestInfo(recipient).endWithdrawWindowTimestamp` is in the past.
    - Call `enter` via the delegate caller with a non-zero amount.
    - Expect `UpdateInternalCalled(withdrawManager, recipient, amount)`
      event from the mock base — proves the fuse routed through
      `PlasmaVaultBase.updateInternal`.

14. `testEnter_updatesERC20VotesCheckpoints_onBothSides` (fork-based, real
    stack)
    - Using the real `PlasmaVault` fixture, have the recipient delegate
      their vote power to a `recipientDelegatee`, and have the vault's
      `WithdrawManager` receive delegations from some seed user so that its
      balance contributes to a `managerDelegatee`.
    - Snapshot `getVotes(recipientDelegatee)` and
      `getVotes(managerDelegatee)` before the refund.
    - Execute `enter` post-expiry.
    - Expect both vote tallies to shift by exactly `amount` (recipient
      side +, manager side −) — confirms the path goes through `_update`,
      not a raw `_transfer` that would skip vault hooks.

### 6.4 Access control

15. `testExecute_reverts_whenCallerIsNotAllowed`
    - Call `PlasmaVault.execute(FuseAction[RequestFeeRefundFuse])` from a
      non-alpha address ⇒ standard `AccessManaged` revert. This is inherited
      from the `FuseManager` wiring and documented for completeness.

Target total: 15 tests → expected ≥ 98% line / branch coverage on
`RequestFeeRefundFuse.sol` given the small surface (one non-trivial
function + one reverting stub).

## 7. Coverage Requirements

- `forge coverage --match-path 'test/fuses/burn_request_fee/RequestFeeRefundFuseTest.t.sol'`
- Target: **≥ 98%** lines and branches on
  `contracts/fuses/burn_request_fee/RequestFeeRefundFuse.sol`.
- No coverage target on touched-but-unchanged files.

## 8. Security Checklist

| # | Check | Status |
|---|-------|--------|
| 1 | No storage variables (stateless, runs via delegatecall) | ✅ by design |
| 2 | No `selfdestruct` / delegatecall to untrusted addresses | ✅ only to configured `PlasmaVaultBase` |
| 3 | Uses `PlasmaVaultBase.updateInternal` (not bare `_transfer`) so ERC20Votes checkpoints update on both sides — matches the IL-6952 fix for `BurnRequestFeeFuse` | ✅ two regression tests (§6.3 #13 mock-based, #14 fork-based) |
| 4 | Input validation: `amount` short-circuit on 0, `recipient != 0`, `withdrawManager != 0`, request exists, `block.timestamp > endWithdrawWindowTimestamp` | ✅ §4 + §6.2 |
| 5 | Authorization on the refund path: enforced by `PlasmaVault.execute` → `FuseManager` → `AccessManager` (same role as `BurnRequestFeeFuse`, i.e. ALPHA). Fuse itself stays stateless. | ✅ §6.4 test |
| 6 | No approvals to third parties; only in-vault share accounting moves | ✅ no `approve` anywhere |
| 7 | Replay / double-refund: bounded by `balanceOf(withdrawManager)`; further calls revert with `ERC20InsufficientBalance` | ✅ §6.2 #11 |
| 8 | Timestamp trust: `endWithdrawWindowTimestamp` is written by the user's own `requestShares` call; the fuse reads it via `WithdrawManager.requestInfo` (not a spoofable path). Strict `>` avoids off-by-one overlap with `WithdrawManager`'s inclusive `<=`. | ✅ §6.2 #8 |
| 9 | No new reentrancy surface — single `functionDelegateCall` into a known contract (`PlasmaVaultBase.updateInternal`), same pattern as `BurnRequestFeeFuse`. | ✅ |
| 10 | `VERSION` is `immutable address(this)` — emitted in the event for on-chain audit trail | ✅ |

Out-of-scope follow-ups (not part of this PR):

- FuseManager wiring on each vault that should enable refunds.
- Cleanup of stale `WithdrawRequest` entries after a refund (§2.8).
- Optional dedicated governance role — not requested for this ticket.

## 9. Implementation Order

1. Contract (`RequestFeeRefundFuse.sol`) — per §4.
2. `forge build`.
3. Happy-path tests (§6.1) + voting-checkpoint regression (§6.3).
4. Revert tests (§6.2) + access control (§6.4).
5. Coverage check.
6. `/review-branch`.

## 10. Open Questions / Assumptions

- **MARKET_ID.** Assumed to match the market id used by `BurnRequestFeeFuse`
  in the target vault. Confirm during deployment wiring.
- **"Expired" semantics.** Finalised: `endWithdrawWindowTimestamp != 0`
  **and** `block.timestamp > endWithdrawWindowTimestamp`. No additional
  coupling to `lastReleaseFundsTimestamp`.
- **Request cleanup.** Out of scope; the recipient's `WithdrawRequest` is
  left untouched by the refund (§2.8).
- **Governance role.** No new role added; `PlasmaVault.execute` authorization
  inherits the same role currently used for `BurnRequestFeeFuse`.
