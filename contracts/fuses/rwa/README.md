# RWA Fuses (IL-7205)

Generic integration family for **Real World Asset** strategies inside IPOR Fusion plasma vaults.
The feature bundles four fuses (operation, balance, unpause, rescue), one user-operation
pre-hook, one persistent per-market executor, and two libraries (substrate encoding +
ERC-7201 vault storage). This document is the single reference needed to configure, deploy,
and operate a complete RWA market — from fuse deployment through substrate grants,
pre-hook registration, and ongoing custodian operations.

---

## Table of Contents

1. [Architecture overview](#1-architecture-overview)
2. [Component reference](#2-component-reference)
3. [Substrate reference](#3-substrate-reference)
4. [Flow diagrams](#4-flow-diagrams)
5. [Accounting model](#5-accounting-model)
6. [Custodian dual-approval mechanics](#6-custodian-dual-approval-mechanics)
7. [Pause system (big-change detection + unpause)](#7-pause-system)
8. [Pre-hook gating](#8-pre-hook-gating)
9. [Setup checklist — step by step](#9-setup-checklist)
10. [Substrate configuration playbooks](#10-substrate-configuration-playbooks)
11. [Trust assumptions (M-1..M-4)](#11-trust-assumptions)
12. [Oracle requirements](#12-oracle-requirements)
13. [Operations runbooks](#13-operations-runbooks)
14. [Events reference](#14-events-reference)
15. [Error reference](#15-error-reference)
16. [Testing](#16-testing)

---

## 1. Architecture overview

```
                    ┌──────────────────────────────────────────────────────────────┐
                    │                        PlasmaVault                           │
                    │                (ERC-4626, holds user share tokens)          │
                    │                                                              │
                    │   ┌──────────────┐   ┌─────────────┐   ┌──────────────────┐  │
                    │   │ ALPHA_ROLE   │   │ ATOMIST     │   │ User (deposit/   │  │
                    │   │ operator     │   │ (governance)│   │ mint/withdraw)   │  │
                    │   └──────┬───────┘   └──────┬──────┘   └────────┬─────────┘  │
                    │          │ execute()        │ govern           │  gated     │
                    │          ▼                  ▼                  ▼            │
                    │  ┌──────────────────┐  ┌────────────┐  ┌──────────────────┐  │
                    │  │ RWAOperationFuse │  │ Grants     │  │ RWAPausePreHook  │  │
                    │  │ RWABalanceFuse   │  │ substrates │  │ (per selector)   │  │
                    │  │ RWAUnpauseFuse   │  │ via Plasma │  │                  │  │
                    │  │ RWARescueFuse    │  │ Vault Gov. │  │                  │  │
                    │  └─────┬────────────┘  └────────────┘  └────────┬─────────┘  │
                    │        │ delegatecall                           │            │
                    │        │                                        │            │
                    │        │ reads/writes ERC-7201 RWAStorage ──────┘            │
                    │        │ at slot 0x2c33642f...9400                           │
                    └────────┼─────────────────────────────────────────────────────┘
                             │ calls (normal external)
                             ▼
                    ┌────────────────────────────────┐
                    │ RWAExecutor (per vault+market) │
                    │ --------------------------------│
                    │ • holds asset tokens            │           ┌────────────────┐
                    │ • tracks balances[ba]           │  actions  │ External RWA   │
                    │ • caches substrates             │──────────▶│ protocol /     │
                    │ • dual-approval propose/confirm │           │ router /       │
                    │ • `Address.functionCall(target)`│           │ treasury, etc. │
                    └─────────┬──────────────────────┘           └────────────────┘
                              │ propose / confirm
                              ▼
                    ┌─────────────────────┐
                    │ Custodians (2..N)   │
                    │ off-chain signers   │
                    └─────────────────────┘
```

### Key invariants

- **Single executor per `(vault, marketId)`.** First `enter` / `createExecutor` call lazy-deploys
  `RWAExecutor(address(this), marketId)`; subsequent calls return the cached address. Attempting
  to use the same vault slot for a second market reverts `RWAMultipleMarketsNotSupported(existing, requested)`.
- **Vault storage is ERC-7201 namespaced.** All fuses read/write through `RWAExecutorStorageLib`
  at slot `0x2c33642f9f95a2ae96c65138627f6a55480cec20290d678b3efcc2db4caa9400`. This isolates
  RWA state from every other fuse's storage and makes it safe to delegatecall.
- **Substrate whitelist is the primary security boundary.** Every asset, balance account,
  custodian, and action target+selector must be granted by the atomist via
  `PlasmaVaultGovernance.grantMarketSubstrates(marketId, ...)`.
- **Dual-custodian reporting.** Any balance update requires two different custodians: one to
  propose, a second to confirm within `STALENESS_MAX`, with per-account rate-limiting via
  `MIN_UPDATE_INTERVAL`.

---

## 2. Component reference

### 2.1 `RWAOperationFuse`

| Attribute | Value |
|---|---|
| Kind | Stateless fuse (delegatecall from PlasmaVault) |
| Constructor | `(uint256 marketId)` — reverts `RWAZeroMarketId` on 0 |
| Immutables | `VERSION = address(this)`, `MARKET_ID` |
| Entry points | `enter(RWAOperationFuseEnterData)`, `exit(RWAOperationFuseExitData)`, `createExecutor()` |

**Enter semantics:**
1. `_resolveExecutorAndValidate` — revert `RWAEmptyAssetAndActions` if both `amount == 0` and `actions.length == 0`.
2. `getOrCreateExecutor(MARKET_ID)` — lazy-deploys executor if missing.
3. If `amount > 0`: validate `ASSET` + `BALANCE_ACCOUNT` substrates. Validate every action's
   `(target, selector)` pair.
4. If `amount > 0`: `safeTransfer(asset, executor, amount)` → convert to underlying via oracle
   → `executor.addBalance(ba, valueInUnderlying)`.
5. If `actions.length > 0`: `executor.execute(actions)`.

**Exit semantics:**
1. `_resolveExecutorAndValidate` with `createIfMissing_ = false` — revert `RWAOperationExecutorNotDeployed` if the
   executor has not yet been deployed.
2. Same substrate validation as enter.
3. If `actions.length > 0`: `executor.execute(actions)` **first** (to free funds).
4. If `amount > 0`: convert to underlying → `executor.removeBalance(ba, valueInUnderlying, asset, amount)`.

### 2.2 `RWAExecutor`

| Attribute | Value |
|---|---|
| Kind | Persistent contract (one per `(vault, marketId)`) |
| Storage | Regular contract storage (NOT ERC-7201 namespaced — the executor owns its own slots) |
| Reentrancy | `ReentrancyGuard` on `removeBalance`, `execute`, `proposeBalance`, `confirmBalance` |
| Immutables | `VAULT`, `MARKET_ID` |

**State:**
- `mapping(address => uint256) balances` — tracked underlying balance per balance account.
- `mapping(address => uint256) lastUpdated` — timestamp of last confirmed custodian update per account.
- `mapping(address => PendingProposal) pendingProposals` — current pending propose per account.
- Cached substrate arrays: `balanceAccounts[]`, `custodians[]`, `assets[]`.
- Cached singletons: `stalenessMax`, `bigChangeBps`, `dustThreshold`, `minUpdateInterval`.
- `lastCustodianUpdateTimestamp` — global timestamp of any `confirmBalance`.
- `nonce` — monotonically incremented on each `proposeBalance`.

**Access control:**
- `onlyVault` — `addBalance`, `removeBalance`, `execute`, `withdrawAssetBalance`.
- `onlyCustodian` — `proposeBalance`, `confirmBalance` (linear scan over cached `custodians[]`).
- Public — `syncSubstrates()`, view functions.

### 2.3 `RWABalanceFuse`

Stateless fuse implementing `IMarketBalanceFuse`. `balanceOf()` is **not view** — it writes to
`RWAExecutorStorageLib` to update `lastTotalBalance` and `lastCheckedCustodianTimestamp`, and
may set the pause flag on big-change detection. Returns USD WAD value of the total underlying
balance, computed via the vault's `PriceOracleMiddleware`.

### 2.4 `RWAPausePreHook`

Pre-hook implementing `IPreHook`. Registered via `PlasmaVaultGovernance.setPreHookImplementations`
against user-facing ERC-4626 selectors (`deposit`, `mint`, `withdraw`, `redeem`,
`depositWithPermit`). Enforces:
1. Executor deployed (`RWAPreHookExecutorNotDeployed`).
2. Pause flag clear (`RWAPreHookPaused`).
3. Inline big-change check (`RWAPreHookBigChangeDetected`) — closes the window between
   `confirmBalance` and the next `balanceOf()`.
4. Staleness gate (`RWAPreHookStale`) — aggregate staleness based on oldest balance account update.

### 2.5 `RWAUnpauseFuse`

Signature-gated fuse that verifies an atomist ECDSA signature over
`keccak256(abi.encodePacked(vault, MARKET_ID, confirmedTotalBalance, nonce, expirationTime, chainid))`
and clears the pause flag. Rejects expired or replayed nonces. Uses OpenZeppelin `ECDSA.recover`
(rejects high-s signatures / malleable signatures).

### 2.6 `RWARescueFuse`

Sweeper fuse that calls `executor.withdrawAssetBalance(asset)` to return the executor's full
balance of any ERC20 back to the vault. Useful for airdrops or stuck tokens. Reverts
`RWAZeroAddress` if `asset == address(0)`.

### 2.7 Libraries

- `RWASubstrateLib` — encode / decode / classify / validate substrates. 8-bit type + 248-bit
  payload packed in a single `bytes32`.
- `RWAExecutorStorageLib` — ERC-7201 namespaced vault storage at slot
  `0x2c33642f9f95a2ae96c65138627f6a55480cec20290d678b3efcc2db4caa9400`
  = `keccak256(abi.encode(uint256(keccak256("io.ipor.rwa.Executor")) - 1)) & ~0xff`.

---

## 3. Substrate reference

All substrates are packed into a single `bytes32`:

```
 ┌─────────┬───────────────────────────────────────────────────────────┐
 │ type    │                       payload                             │
 │ (8 bits)│                     (248 bits)                            │
 └─────────┴───────────────────────────────────────────────────────────┘
   byte31                           bytes 0..30
```

### 3.1 Supported types

| Code | Type | Encoder | Payload layout | Cardinality | Purpose |
|:---:|---|---|---|:---:|---|
| `0` | `UNDEFINED` | — | — | — | Reserved / sentinel. Reverts `RWAUnsupportedSubstrate` on decode. |
| `1` | `ASSET` | `encodeAssetSubstrate(address)` | `address` in low 160 bits | N | ERC20 allowed for enter/exit accounting. |
| `2` | `TARGET` | `encodeTargetSubstrate(address, bytes4)` | `address` low 160 bits, `bytes4` at bits 160..191 | N | Authorizes Alpha to call `(target, selector)` from executor context. |
| `3` | `CUSTODIAN` | `encodeCustodianSubstrate(address)` | `address` in low 160 bits | ≥2 | Authorized propose/confirm caller. Dual-approval requires at least 2. |
| `4` | `BALANCE_ACCOUNT` | `encodeBalanceAccountSubstrate(address)` | `address` in low 160 bits | N | Logical balance bucket. Each account is rate-limited independently. |
| `5` | `STALENESS_MAX` | `encodeStalenessMaxSubstrate(uint256)` | `uint248` in low 248 bits | **1** | Seconds. Maximum staleness before user ops are blocked. Also serves as `confirmBalance` TTL. |
| `6` | `BIG_CHANGE_BPS` | `encodeBigChangeBpsSubstrate(uint256)` | `uint248` in low 248 bits | **1** | Basis points. `|delta|/prevTotal > bigChangeBps` → pause. |
| `7` | `DUST_THRESHOLD` | `encodeDustThresholdSubstrate(uint256)` | `uint248` in low 248 bits | **1** | Percent of one base token allowed on executor during propose/confirm (100 = 1 token). |
| `8` | `MIN_UPDATE_INTERVAL` | `encodeMinUpdateIntervalSubstrate(uint256)` | `uint248` in low 248 bits | **1** | Seconds. Per-account rate-limit between confirmed custodian updates. |

Cardinality: **N** = multiple allowed; **1** = strict singleton, duplicate grants revert
`RWADuplicateSingletonSubstrate` on `syncSubstrates()`.

### 3.2 Mandatory substrates

`syncSubstrates()` reverts `RWAMandatorySingletonMissing(uint8 typeCode)` unless the following
are granted:

| Type | Code | Why mandatory |
|---|:---:|---|
| `STALENESS_MAX` | 5 | Missing → user operations would permanently pass the staleness gate. |
| `BIG_CHANGE_BPS` | 6 | Missing → the big-change pause would silently disable. Critical safety net. |

Optional singletons (`DUST_THRESHOLD`, `MIN_UPDATE_INTERVAL`) default to 0 if absent. That means:

- `dustThreshold == 0` → zero tolerance; any non-zero executor asset balance blocks propose/confirm
  (safest default — forces airdrop rescue before reporting).
- `minUpdateInterval == 0` → no per-account rate-limit (custodians can confirm as fast as they want).

### 3.3 Encoder examples

```solidity
// ASSET
bytes32 sub = RWASubstrateLib.encodeAssetSubstrate(USDC);
// sub = 0x01 00..00 <USDC address in last 20 bytes>

// TARGET — authorize `IRWAProtocol.deposit(address,uint256)` on `rwaProtocol`
bytes4  selector = IRWAProtocol.deposit.selector;             // e.g. 0xf45346dc
bytes32 sub = RWASubstrateLib.encodeTargetSubstrate(address(rwaProtocol), selector);
// sub = 0x02 00..<selector 4 bytes at offset 20..24><rwaProtocol address in last 20 bytes>

// STALENESS_MAX = 24h
bytes32 sub = RWASubstrateLib.encodeStalenessMaxSubstrate(24 hours);
// sub = 0x05 00..00 <seconds in low bits>
```

### 3.4 Decoding / classification

```solidity
RWASubstrateType t = RWASubstrateLib.decodeSubstrateType(sub);
if (t == RWASubstrateType.ASSET) {
    address asset = RWASubstrateLib.decodeAddressPayload(sub);
}
if (t == RWASubstrateType.TARGET) {
    (address target, bytes4 selector) = RWASubstrateLib.decodeTargetPayload(sub);
}
if (t == RWASubstrateType.STALENESS_MAX) {
    uint256 seconds_ = RWASubstrateLib.decodeUint248Payload(sub);
}
```

Classifiers `isAssetSubstrate`, `isTargetSubstrate`, ... `isMinUpdateIntervalSubstrate` return
`bool` without reverting.

### 3.5 Runtime validation

`RWAOperationFuse.enter` / `exit` call `validateAssetGranted`, `validateBalanceAccountGranted`,
and `validateTargetSelectorGranted` per action — each reverts `RWAUnsupportedSubstrate` if the
substrate is absent from `PlasmaVaultConfigLib.isMarketSubstrateGranted(marketId, encoded)`.

---

## 4. Flow diagrams

### 4.1 Alpha enter with actions (end-to-end)

```
Alpha                   PlasmaVault               RWAOperationFuse          ExecutorStorageLib         RWAExecutor         External Protocol
  │                         │                           │                          │                         │                     │
  │ execute([RWAEnter])     │                           │                          │                         │                     │
  │────────────────────────▶│                           │                          │                         │                     │
  │                         │ delegatecall enter(...)   │                          │                         │                     │
  │                         │──────────────────────────▶│                          │                         │                     │
  │                         │                           │  _resolveExecutorAndValidate:             │                         │                     │
  │                         │                           │    validate amount/actions│                        │                     │
  │                         │                           │    getOrCreateExecutor───▶│                         │                    │
  │                         │                           │                          │ new RWAExecutor() ──────▶│ (constructor)      │
  │                         │                           │                          │ executor.syncSubstrates─▶│ cache populated    │
  │                         │                           │◀─ executor addr ─────────│                         │                     │
  │                         │                           │                                                                         │
  │                         │                           │ validateAssetGranted                                                      │
  │                         │                           │ validateBalanceAccountGranted                                             │
  │                         │                           │ validateTargetSelectorGranted (per action)                                │
  │                         │                           │                                                                         │
  │                         │                           │ safeTransfer(asset, executor, amount)                                     │
  │                         │                           │ valueInUnderlying = oracle convert                                        │
  │                         │                           │ executor.addBalance(ba, valueInUnderlying)─────────▶│                     │
  │                         │                           │                                                     │ balances[ba] += v  │
  │                         │                           │                                                     │ emit BalanceChangedByFuse
  │                         │                           │                                                                         │
  │                         │                           │ executor.execute(actions)──────────────────────────▶│                     │
  │                         │                           │                                                     │ Address.functionCall(target, data)
  │                         │                           │                                                     │─────────────────────▶│
  │                         │                           │                                                     │◀─────────────────────│
  │                         │                           │                                                     │ emit ActionsExecuted │
  │                         │                           │                                                                         │
  │                         │                           │ emit RWAOperationFuseEnter                                               │
  │                         │◀──────────────────────────│                                                                         │
  │◀────────────────────────│                                                                                                     │
```

### 4.2 Alpha exit (actions then withdraw)

```
Alpha ──execute([RWAExit])──▶ PlasmaVault
                                  │
                                  │ delegatecall exit(RWAOperationFuseExitData)
                                  ▼
                           RWAOperationFuse
                                  │
                                  │ _resolveExecutorAndValidate (createIfMissing_=false → revert
                                  │  RWAOperationExecutorNotDeployed if missing)
                                  │
                                  │ executor.execute(actions)        // withdraw from external protocol first
                                  │       │
                                  │       ▼
                                  │   External Protocol sends back asset
                                  │
                                  │ valueInUnderlying = oracle convert
                                  │ executor.removeBalance(ba, valueInUnderlying, asset, amount)
                                  │       │
                                  │       ├─ balances[ba] -= valueInUnderlying   (revert RWAExitExceedsTrackedBalance if >)
                                  │       └─ safeTransfer(asset, VAULT, amount)
                                  │
                                  │ emit RWAOperationFuseExit
                                  ▼
                                 done
```

### 4.3 Custodian dual approval

```
Custodian A                    RWAExecutor                    Custodian B
     │                              │                              │
     │ proposeBalance(ba, newValue) │                              │
     │─────────────────────────────▶│                              │
     │                              │ check: onlyCustodian (A ∈ custodians[])
     │                              │ check: _checkDust() for each asset
     │                              │ nonce++ ; proposedAt = block.timestamp
     │                              │ pending[ba] = {value, A, proposedAt, nonce}
     │                              │ h = _proposalHash(ba, value, A, proposedAt, nonce)
     │                              │ emit BalanceProposed(ba, A, value, nonce, proposedAt, h)
     │◀─────────────────────────────│
     │                              │
     │                              │         .. off-chain: A shares (ba, h) with B ..
     │                              │
     │                              │ confirmBalance(ba, h)        │
     │                              │◀─────────────────────────────│
     │                              │ check: onlyCustodian (B ∈ custodians[])
     │                              │ check: pending.proposer != 0       → else RWAExecutorNoPendingProposal
     │                              │ check: pending.proposer != msg.sender → else RWAExecutorSameProposerAndConfirmer
     │                              │ check: now - proposedAt ≤ stalenessMax → else RWAExecutorProposalExpired
     │                              │ _checkDust()
     │                              │ check: _proposalHash(...) == h      → else RWAExecutorProposalHashMismatch
     │                              │ check: (lastUpdated==0) || (now-lastUpdated ≥ minUpdateInterval)
     │                              │                                    → else RWAExecutorMinUpdateIntervalNotMet
     │                              │ balances[ba] = pending.value
     │                              │ lastUpdated[ba] = now
     │                              │ lastCustodianUpdateTimestamp = now
     │                              │ delete pending[ba]
     │                              │ emit BalanceConfirmed(ba, B, oldValue, newValue, nonce)
     │                              │──────────────────────────────▶
     │                              │
```

If Custodian A (or another custodian) submits a fresh propose while another is still pending,
the executor emits `ProposalOverwritten(ba, oldProposer, newProposer, oldNonce, newNonce)` and
replaces the pending slot. The old hash becomes invalid — off-chain tooling MUST listen to that
event to discard stale hashes.

### 4.4 Big-change detection + pause + unpause

```
Custodians confirm                        PlasmaVault.execute(...)                PlasmaVault.deposit (user)
new balance @ T0                          triggers balance fuse readout            blocked by pre-hook
       │                                              │                                      │
       ▼                                              ▼                                      ▼
┌──────────────────┐                      ┌──────────────────────┐                ┌──────────────────────┐
│ RWAExecutor      │                      │ RWABalanceFuse       │                │ RWAPausePreHook      │
│ confirmBalance() │                      │ balanceOf()          │                │ run()                │
│ lastCustodianTS  │                      │                      │                │                      │
│   = T0           │                      │ (total, bps, ts)     │                │ if executor==0:       │
└─────────┬────────┘                      │  = executor.getBalance│               │   revert PreHookExecutorNotDeployed
          │                               │       Data()         │                │ if paused: revert PreHookPaused
          │                               │                      │                │                      │
          │ (no state write yet)          │ if ts != lastChecked:│                │ if ts != lastChecked:│
          │                               │   |Δ| = |total-prev| │                │   |Δ| = |total-prev| │
          │                               │   if |Δ|/prev > bps: │                │   if |Δ|/prev > bps: │
          │                               │     setPaused(true)  │                │     revert PreHookBigChangeDetected
          │                               │     emit RWABigChangeDetected
          │                               │   setLastChecked(ts)  │                │ (pre-hook does NOT write lastChecked)
          │                               │ setLastTotalBalance(total)             │                      │
          │                               │                      │                │ if oldest != 0 && now - oldest > stalenessMax:
          │                               │ return total·price   │                │   revert PreHookStale │
          │                               │   /1e(dec+priceDec)  │                │                      │
          │                               └──────────────────────┘                └──────────────────────┘
          │
          │ After pause flag is set:
          │
          ▼
┌──────────────────────┐
│ Atomist signs:       │          unpause(RWAUnpauseData)
│   vault, MARKET_ID,  │──────────────────────────┐
│   confirmedTotal,    │                          ▼
│   nonce, expiration, │                  ┌──────────────────┐
│   chainid            │                  │ RWAUnpauseFuse   │
└──────────────────────┘                  │ • verifies       │
                                          │ • recovers signer│
                                          │ • hasRole(ATOMIST)│
                                          │ • confirmedTotal │
                                          │   == current     │
                                          │ • nonce !used    │
                                          │ • now ≤ exp      │
                                          │ → setPaused(false)│
                                          │ → markNonceUsed  │
                                          └──────────────────┘
```

### 4.5 Rescue sweep

```
Alpha ──execute([RWARescue.rescue(airdroppedToken)])──▶ PlasmaVault
                                                           │
                                                           │ delegatecall rescue(asset)
                                                           ▼
                                                  RWARescueFuse
                                                           │
                                                           │ require asset != 0
                                                           │ require executor != 0
                                                           │ executor.withdrawAssetBalance(asset)
                                                           │       │
                                                           │       ▼
                                                           │ RWAExecutor
                                                           │   bal = IERC20(asset).balanceOf(this)
                                                           │   if bal > 0: safeTransfer(asset, VAULT, bal)
                                                           │   emit AssetWithdrawn(asset, bal)
                                                           │
                                                           │ emit RWAAssetRescued(asset)
```

Note: `withdrawAssetBalance` does **not** touch `balances[]`. If the swept token is also an ASSET
substrate, tracked balances remain whatever the last `addBalance`/`removeBalance`/`confirmBalance`
set them to. That is intentional — rescue is for tokens that were never accounted (airdrops,
accidental sends), not for reconciling tracked state.

---

## 5. Accounting model

### 5.1 Units

- **Asset amount** — in ERC20 decimals (e.g. 6 for USDC, 18 for WETH). Passed as `amount` in
  `enter` / `exit` data.
- **Underlying** — vault underlying units (`IERC4626(address(this)).asset()`). Conversion from
  asset → underlying runs via `PriceOracleMiddleware.getAssetPrice(asset)` + the underlying's
  own price, producing a USD WAD intermediate that is then converted to underlying decimals.
- **Tracked balance** — stored per balance account in underlying units
  (`executor.balances[ba]`).
- **`RWABalanceFuse.balanceOf()` return** — USD WAD (18 decimals), suitable for ERC-4626 NAV
  aggregation.

### 5.2 Conversion math (enter / exit)

```
valueInUnderlying =
    IporMath.convertToWad(amount * assetPrice, assetDecimals + assetPriceDecimals)    // asset → USD WAD
    * 10^underlyingDecimals
    / IporMath.convertToWad(underlyingPrice, underlyingPriceDecimals)                  // USD WAD → underlying
```

Implementation matches `AsyncExecutor._convertUsdToUnderlyingAmount` in the async-action fuses.
Flash-loan-manipulable oracles let an attacker inflate / deflate this value — see
[Oracle requirements](#12-oracle-requirements).

### 5.3 State mutation per operation

| Operation | `balances[ba]` | `lastUpdated[ba]` | `lastCustodianUpdateTimestamp` | Tokens |
|---|---|---|---|---|
| `addBalance` (enter) | `+= valueInUnderlying` | untouched | untouched | vault → executor |
| `removeBalance` (exit) | `-= valueInUnderlying` (revert if >) | untouched | untouched | executor → vault |
| `execute` (actions) | untouched | untouched | untouched | executor ⇄ external protocol |
| `confirmBalance` | `= pending.value` (overwrite) | `= now` | `= now` | none |
| `withdrawAssetBalance` (rescue) | untouched | untouched | untouched | executor → vault |

Custodian updates **overwrite** the tracked balance (they reflect ground truth from bank /
custodian reports), whereas fuse operations **increment/decrement** (they reflect funds flow).
The two reconcile when custodians confirm after a round-trip — custodian-reported value is
authoritative.

### 5.4 Airdrop handling

Tokens that arrive at the executor without going through `addBalance` are NOT counted in
`balances[]`. They sit on the executor until:
- An Alpha operation moves them out via `execute(actions)` (only if the `(target, selector)` is
  substrate-granted); or
- `RWARescueFuse.rescue(asset)` sweeps them back to the vault.

Non-zero executor balances of cached ASSET substrates **block** new `proposeBalance` /
`confirmBalance` calls via the dust check — custodians must clear them before reporting.

---

## 6. Custodian dual-approval mechanics

### 6.1 Proposal hash

```solidity
keccak256(abi.encode(address(executor), block.chainid, balanceAccount, value, proposer, proposedAt, nonce))
```

Bound fields:
- `address(executor)` — prevents cross-executor replay in case the same `(chainid, marketId)` tuple
  is ever re-deployed.
- `block.chainid` — prevents cross-chain replay (e.g. mainnet vs Sepolia).
- `balanceAccount` — prevents moving a proposal between accounts.
- `value`, `proposer`, `proposedAt`, `nonce` — intrinsic proposal identity.

### 6.2 Custodian modifier

`onlyCustodian` linearly scans the cached `custodians[]` array on every call. Addresses grants
via `grantMarketSubstrates` on the vault do NOT take effect until `syncSubstrates()` is called on
the executor. See M-2 runbook.

### 6.3 Dust check

Runs inside both `proposeBalance` and `confirmBalance` before any state mutation:

```
for each asset in cached assets[]:
    balance = IERC20(asset).balanceOf(executor)
    allowed = 10^decimals(asset) * dustThreshold / 100
    if balance > allowed: revert RWAExecutorDustCheckFailed(asset, balance, allowed)
```

The `/100` denominator is extracted as a constant (`DUST_THRESHOLD_DENOMINATOR`) so
`dustThreshold` reads as "percent of one base token". Examples with `decimals(USDC) = 6`:

| `dustThreshold` | `allowed` on USDC | Semantics |
|---:|---:|---|
| `0` | 0 USDC | Zero tolerance — safest default |
| `50` | 0.5 USDC | Half-token dust allowance |
| `100` | 1 USDC | One-token dust allowance |
| `10_000` | 100 USDC | Permissive (only for tokens with tiny unit value) |

### 6.4 Proposal lifecycle

```
  ┌──────────────┐
  │   no pending │◀──────────────────────────────────────┐
  └──────┬───────┘                                        │
         │ proposeBalance                                  │
         ▼                                                 │
  ┌──────────────┐   proposeBalance (overwrite,            │
  │   pending    │── emits ProposalOverwritten) ──┐        │
  │              │                                │        │
  │              │── confirmBalance (happy) ──────┼──── balance updated
  │              │                                │        │
  │              │── stalenessMax expiry (TTL) ───┤        │
  │              │   (confirm reverts              │        │
  │              │    RWAExecutorProposalExpired,  │        │
  │              │    pending stays until next    │        │
  │              │    propose overwrites it)      │        │
  └──────────────┘                                │        │
                                                  └────────┘
```

Edge cases:
- **Same proposer confirms** → `RWAExecutorSameProposerAndConfirmer(msg.sender)`.
- **Hash mismatch** (propose was overwritten between propose and confirm) →
  `RWAExecutorProposalHashMismatch(expected, given)`. The old hash becomes invalid — off-chain
  tooling MUST subscribe to `ProposalOverwritten` to invalidate outstanding proposals.
- **Rate-limit** (per-account) — `block.timestamp - lastUpdated[ba] < minUpdateInterval` and
  `lastUpdated[ba] != 0` → `RWAExecutorMinUpdateIntervalNotMet`. First-ever update for an
  account is exempt (so bootstrap doesn't block).

---

## 7. Pause system

### 7.1 Big-change detection (balance fuse)

`RWABalanceFuse.balanceOf()` compares current total to previously observed `lastTotalBalance`,
but **only when a new custodian update has landed** (`lastCustodianTs != lastChecked`). This is
critical: alpha-driven enter/exit naturally changes the total in underlying units, and those
changes must NOT trip the pause.

```
delta = |totalBalance - prevTotal|
if lastCustodianTs != lastChecked:
    if prevTotal != 0 and delta * 10_000 / prevTotal > bigChangeBps:
        setPaused(true)
        emit RWABigChangeDetected(prevTotal, totalBalance, bigChangeBps)
    setLastCheckedCustodianTimestamp(lastCustodianTs)
setLastTotalBalance(totalBalance)
```

Baseline: the first observation after deployment (`prevTotal == 0`) is always accepted without
triggering pause.

### 7.2 Inline big-change in pre-hook

The pre-hook performs the same delta check **before** `balanceOf()` runs, to close the window
between `confirmBalance` and the next balance-fuse readout. This is stateless: the pre-hook
reads `lastCustodianUpdateTimestamp`, `lastCheckedCustodianTimestamp`, `lastTotalBalance`, and
`bigChangeBps` but does NOT write `lastChecked` — only the balance fuse advances that cursor.

Consequence: between a custodian confirm and the first `balanceOf` call:
1. User attempts `deposit` → pre-hook computes delta > bps → reverts `RWAPreHookBigChangeDetected`.
2. Keeper / alpha call flows through `_updateMarketsBalances` → balance fuse sets pause flag.
3. User attempts `deposit` again → pre-hook reverts `RWAPreHookPaused` instead.

The error code transitions are expected; both are fail-closed.

### 7.3 Unpause

The atomist builds the payload:
```
signedMessage = keccak256(abi.encodePacked(
    vaultAddress,          // address(plasmaVault)
    MARKET_ID,             // uint256
    confirmedTotalBalance, // uint256 — must match executor.getBalanceFuseSnapshot().totalBalance at call time
    nonce,                 // uint256 — atomist-chosen, tracked in RWAStorage.usedUnpauseNonces
    expirationTime,        // uint256 — seconds since epoch
    block.chainid          // uint256
))
```

Signs it with an atomist EOA, then Alpha calls `PlasmaVault.execute([RWAUnpauseFuse.unpause(data)])`
with the signature. The fuse verifies signer role, balance match, nonce/expiration, and clears
the pause flag. Signature replay is prevented by `markUnpauseNonceUsed(nonce)`. Expired payloads
revert `RWAUnpauseSignatureExpired`.

---

## 8. Pre-hook gating

### 8.1 Selectors to register

Pre-hook must be registered against every ERC-4626 entry point that creates or redeems shares.
Verify selectors against your exact vault build with `cast sig "<signature>"` before registering —
the table below lists the canonical IPOR Fusion PlasmaVault selectors at the time of writing.

| Selector | Function | Action type |
|---|---|---|
| `0x6e553f65` | `deposit(uint256,address)` | share mint |
| `0x94bf804d` | `mint(uint256,address)` | share mint |
| `0x00f714ce` | `depositWithPermit(...)` (exact selector deployment-specific) | share mint |
| `0xba087652` | `redeem(uint256,address,address)` | share burn |
| `0xb460af94` | `withdraw(uint256,address,address)` | share burn |

### 8.2 Pre-hook flow

```
user calls deposit/mint/withdraw/redeem
           │
           ▼
  PlasmaVault._runPreHooks(selector)
           │
           ▼
  RWAPausePreHook.run(selector)
           │
           ├─ executor = RWAExecutorStorageLib.getExecutor()
           ├─ if executor == 0: revert RWAPreHookExecutorNotDeployed
           │
           ├─ if RWAExecutorStorageLib.getPaused(): revert RWAPreHookPaused
           │
           ├─ (total, bps, lastCustodianTs) = executor.getBalanceFuseSnapshot()
           ├─ lastChecked = getLastCheckedCustodianTimestamp()
           ├─ if lastCustodianTs != lastChecked:
           │     prevTotal = getLastTotalBalance()
           │     if prevTotal != 0 and |total-prevTotal|*10000/prevTotal > bps:
           │         revert RWAPreHookBigChangeDetected
           │
           ├─ oldest = executor.getOldestUpdateTimestamp()
           ├─ if oldest != 0:
           │     max = executor.stalenessMax()
           │     if block.timestamp - oldest > max: revert RWAPreHookStale(oldest, now, max)
           │
           └─ return (all gates passed)
```

Note: `getOldestUpdateTimestamp()` returns the minimum **non-zero** `lastUpdated[ba]` across
cached balance accounts, or 0 when every account still has `lastUpdated == 0` (pre-first-confirm
bootstrap state). Zero exempts the staleness gate — users can deposit into a freshly deployed
executor before custodians have reported.

---

## 9. Setup checklist

Below is the complete, ordered sequence to stand up a new RWA market from zero. Every step maps
to a specific on-chain call (or a well-defined off-chain task). Run each step atomically; if any
step fails, abort the runbook and investigate before proceeding.

### Prerequisites

- PlasmaVault deployed and the caller has `ATOMIST_ROLE` (governance role for `addFuses`,
  `grantMarketSubstrates`, `setPreHookImplementations`).
- `PriceOracleMiddleware` is configured on the vault, audited against the acceptable feed
  types (see [Oracle requirements](#12-oracle-requirements)), and covers the vault underlying
  + every ASSET you plan to grant.
- `AccessManager` on the vault has `ATOMIST_ROLE` granted to the off-chain signing EOA(s) that
  will sign unpause payloads.
- At least **two** custodian EOAs (or multisigs behaving as EOAs for signatures).
- The dedicated `MARKET_ID = IporFusionMarkets.RWA` (`= 49`). Defined in
  `contracts/libraries/IporFusionMarkets.sol`. One vault hosts at most one RWA market via this
  fuse family — `RWAExecutorStorageLib.getOrCreateExecutor` reverts with
  `RWAMultipleMarketsNotSupported` if a second market id is later attempted.

### Step 1 — Deploy fuses + pre-hook

Deploy one instance of each contract, all bound to the same `MARKET_ID`:

```solidity
RWAOperationFuse opFuse    = new RWAOperationFuse(MARKET_ID);
RWABalanceFuse   balanceFuse = new RWABalanceFuse(MARKET_ID);
RWAUnpauseFuse   unpauseFuse = new RWAUnpauseFuse(MARKET_ID);
RWARescueFuse    rescueFuse  = new RWARescueFuse(MARKET_ID);
RWAPausePreHook  preHook     = new RWAPausePreHook(MARKET_ID);
```

The executor itself is NOT deployed here — it is lazy-deployed by the first `enter` (or an
explicit `opFuse.createExecutor()` via `PlasmaVault.execute(...)`).

### Step 2 — Register fuses on the vault

Register all four fuses as addable for this vault (atomist-only):

```solidity
address[] memory fuses = new address[](4);
fuses[0] = address(opFuse);
fuses[1] = address(balanceFuse);
fuses[2] = address(unpauseFuse);
fuses[3] = address(rescueFuse);
PlasmaVaultGovernance(vault).addFuses(fuses);
```

### Step 3 — Bind the balance fuse to `MARKET_ID`

```solidity
PlasmaVaultGovernance(vault).setBalanceFuse(MARKET_ID, address(balanceFuse));
```

This wires `balanceOf()` into NAV aggregation. If omitted, the market contributes 0 to the
vault's gross assets.

### Step 4 — Register the pre-hook against gated selectors

```solidity
bytes4[] memory selectors = new bytes4[](5);
selectors[0] = 0x6e553f65; // deposit(uint256,address)
selectors[1] = 0x94bf804d; // mint(uint256,address)
selectors[2] = 0x00f714ce; // depositWithPermit(...) — verify for your build
selectors[3] = 0xba087652; // redeem(uint256,address,address)
selectors[4] = 0xb460af94; // withdraw(uint256,address,address)

address[] memory impls = new address[](5);
for (uint256 i; i < selectors.length; ++i) impls[i] = address(preHook);

bytes32[] memory substrates = new bytes32[](5); // empty per-selector substrates

PlasmaVaultGovernance(vault).setPreHookImplementations(selectors, impls, substrates);
```

### Step 5 — Grant substrates

Build the full substrate set and grant atomically. Mandatory singletons:
`STALENESS_MAX`, `BIG_CHANGE_BPS`. Recommended: `DUST_THRESHOLD`, `MIN_UPDATE_INTERVAL`.

```solidity
bytes32[] memory subs = new bytes32[](N); // sized to your configuration
uint256 i;
// --- Assets ---
subs[i++] = RWASubstrateLib.encodeAssetSubstrate(USDC);
subs[i++] = RWASubstrateLib.encodeAssetSubstrate(USDT);
// --- Balance accounts (logical buckets; can match custodian organisation) ---
subs[i++] = RWASubstrateLib.encodeBalanceAccountSubstrate(bucketBrokerA);
subs[i++] = RWASubstrateLib.encodeBalanceAccountSubstrate(bucketBrokerB);
// --- Custodians (≥2, MUST be distinct) ---
subs[i++] = RWASubstrateLib.encodeCustodianSubstrate(custodianA);
subs[i++] = RWASubstrateLib.encodeCustodianSubstrate(custodianB);
// --- Targets (action whitelist) ---
subs[i++] = RWASubstrateLib.encodeTargetSubstrate(address(rwaProtocol), IRWAProtocol.deposit.selector);
subs[i++] = RWASubstrateLib.encodeTargetSubstrate(address(rwaProtocol), IRWAProtocol.withdraw.selector);
subs[i++] = RWASubstrateLib.encodeTargetSubstrate(USDC, IERC20.approve.selector); // if alpha approves USDC
// --- Singletons (mandatory) ---
subs[i++] = RWASubstrateLib.encodeStalenessMaxSubstrate(24 hours);
subs[i++] = RWASubstrateLib.encodeBigChangeBpsSubstrate(500);        // 5%
// --- Singletons (recommended) ---
subs[i++] = RWASubstrateLib.encodeDustThresholdSubstrate(100);       // 1 token per asset
subs[i++] = RWASubstrateLib.encodeMinUpdateIntervalSubstrate(1 hours);

PlasmaVaultGovernance(vault).grantMarketSubstrates(MARKET_ID, subs);
```

**Pre-grant review MUST verify** TARGET addresses do NOT overlap with ASSET addresses (see M-3).

### Step 6 — Deploy the executor and sync substrates

Either call `createExecutor()` via `PlasmaVault.execute(...)` explicitly, or wait for the first
`enter`. The explicit path is recommended so substrate sync errors surface before live alpha ops:

```solidity
FuseAction[] memory calls = new FuseAction[](1);
calls[0] = FuseAction({
    fuse: address(opFuse),
    data: abi.encodeCall(RWAOperationFuse.createExecutor, ())
});
PlasmaVault(vault).execute(calls);
```

If any of the following conditions hold after sync, the transaction reverts:
- Duplicate singleton grants → `RWADuplicateSingletonSubstrate`.
- Missing `STALENESS_MAX` or `BIG_CHANGE_BPS` → `RWAMandatorySingletonMissing(typeCode)`.
- Unknown substrate type (raw byte > 8) → `RWAUnsupportedSubstrate`.

Fix the substrate set and re-try. `RWAExecutor.syncSubstrates()` is public — after fixing
grants, anyone (including a keeper) can invoke it.

### Step 7 — Smoke test

Before enabling user deposits, run an end-to-end smoke test via `PlasmaVault.execute(...)`:

1. **Enter dry-run:** `opFuse.enter({asset: USDC, amount: 1e6, balanceAccount: bucketBrokerA, actions: [approve + deposit]})`.
2. **Custodian round-trip:** custodian A proposes, custodian B confirms, assert `balances[bucketBrokerA]` matches expected.
3. **Balance readout:** trigger `_updateMarketsBalances` → assert `_getGrossTotalAssets()` moves by the expected USD delta.
4. **Pre-hook smoke:** as a non-role user attempt `deposit(0, user)` → assert revert
   `RWAPreHookExecutorNotDeployed` is NOT emitted (executor exists) and the call passes the
   pre-hook chain.
5. **Exit dry-run:** `opFuse.exit({...})` closes the position.

Only after all smoke tests pass should the vault be published / user deposits enabled.

### Step 8 — Enable user deposits

Outside the scope of this module. Typically involves flipping a published / paused flag at the
vault layer, publicly advertising the vault, or similar.

### Step 9 — Ongoing operations

- **Adding / revoking custodians:** `grantMarketSubstrates` / `revokeMarketSubstrates` followed
  by `executor.syncSubstrates()` atomically (see M-2 runbook below).
- **Regular NAV updates:** keeper / alpha invokes `PlasmaVault.updateMarketsBalances(marketIds)`
  so `RWABalanceFuse.balanceOf()` runs and advances `lastCheckedCustodianTimestamp`.
- **Custodian reporting:** custodians propose/confirm as reports arrive.
- **Unpause after big-change:** atomist signs a payload matching the current confirmed balance;
  alpha submits it via `RWAUnpauseFuse.unpause`.
- **Rescuing airdrops:** alpha submits `rescueFuse.rescue(token)` via `PlasmaVault.execute`.

---

## 10. Substrate configuration playbooks

### 10.1 Minimal viable market (single asset, single account)

```solidity
subs = [
    encodeAssetSubstrate(USDC),
    encodeBalanceAccountSubstrate(ba1),
    encodeCustodianSubstrate(custA),
    encodeCustodianSubstrate(custB),
    encodeTargetSubstrate(protocol, deposit.selector),
    encodeTargetSubstrate(protocol, withdraw.selector),
    encodeStalenessMaxSubstrate(24 hours),
    encodeBigChangeBpsSubstrate(500),
    encodeDustThresholdSubstrate(100),        // 1 USDC
    encodeMinUpdateIntervalSubstrate(1 hours)
];
```

### 10.2 Multi-asset, multi-account (bank-custodian operation)

```solidity
subs = [
    // 3 assets
    encodeAssetSubstrate(USDC),
    encodeAssetSubstrate(USDT),
    encodeAssetSubstrate(DAI),
    // 5 balance accounts — one per settlement bucket
    encodeBalanceAccountSubstrate(bucketA),
    encodeBalanceAccountSubstrate(bucketB),
    encodeBalanceAccountSubstrate(bucketC),
    encodeBalanceAccountSubstrate(bucketD),
    encodeBalanceAccountSubstrate(bucketE),
    // 3 custodians (dual approval with rotation)
    encodeCustodianSubstrate(custA),
    encodeCustodianSubstrate(custB),
    encodeCustodianSubstrate(custC),
    // Targets — treasury flow
    encodeTargetSubstrate(treasury, IRWATreasury.mintNote.selector),
    encodeTargetSubstrate(treasury, IRWATreasury.redeemNote.selector),
    encodeTargetSubstrate(USDC, IERC20.approve.selector),
    encodeTargetSubstrate(USDT, IERC20.approve.selector),
    encodeTargetSubstrate(DAI,  IERC20.approve.selector),
    // Singletons
    encodeStalenessMaxSubstrate(48 hours),
    encodeBigChangeBpsSubstrate(300),       // 3% — tighter because multi-account drift risk
    encodeDustThresholdSubstrate(50),       // 0.5 token
    encodeMinUpdateIntervalSubstrate(12 hours)
];
```

### 10.3 Restrictive test-net setup (for staging)

```solidity
subs = [
    encodeAssetSubstrate(testUSDC),
    encodeBalanceAccountSubstrate(testBA),
    encodeCustodianSubstrate(testCustA),
    encodeCustodianSubstrate(testCustB),
    encodeTargetSubstrate(testProtocol, testProtocol.mock.selector),
    encodeStalenessMaxSubstrate(1 hours),
    encodeBigChangeBpsSubstrate(10_000),    // 100% — disables big-change for staging only
    encodeDustThresholdSubstrate(0),        // Zero tolerance — forces clean slate
    encodeMinUpdateIntervalSubstrate(0)     // No rate limit on staging
];
```

⚠️ Never deploy staging parameters to mainnet. `bigChangeBps = 10_000` effectively disables
the pause (any ≤100% delta is "fine"), removing the last defense against malicious custodians.

### 10.4 Invalid grants (will revert on `syncSubstrates`)

| Configuration | Revert |
|---|---|
| Two `STALENESS_MAX` substrates with different values | `RWADuplicateSingletonSubstrate(5)` |
| No `BIG_CHANGE_BPS` granted | `RWAMandatorySingletonMissing(6)` |
| `encodeStalenessMaxSubstrate(type(uint248).max + 1)` at encode time | `RWASubstratePayloadOverflow(5, value)` |
| `encodeAssetSubstrate(address(0))` | `RWAZeroAddress` |
| Granted raw `bytes32(uint256(9) << 248)` (type code 9) | `RWAUnsupportedSubstrate(9, raw)` |

---

## 11. Trust assumptions

This section documents security properties that are **not enforced on-chain** and MUST be held
by off-chain operational controls.

### M-1. Cross-account cumulative drift

`MIN_UPDATE_INTERVAL` rate-limits confirmed custodian updates **per balance account**, not
globally. With N balance accounts a colluding custodian pair can produce up to N sub-threshold
updates per interval window — each individual update stays below `bigChangeBps` so the on-chain
big-change pause never triggers, while cumulative NAV drift across accounts can materially
diverge from the real portfolio value.

- **Why accepted:** making the interval global would block legitimate same-day updates across a
  multi-account portfolio (one bank custodian updating 5 accounts on a monthly reporting
  cadence), a hard operational requirement for RWA operators.
- **Off-chain mitigation (MUST be in place before mainnet):**
  1. Monitor `BalanceConfirmed` events and track `sum(balances)` across all balance accounts over
     rolling windows (e.g. 24h / 7d / 30d).
  2. Alert when the rolling delta exceeds a policy threshold (typically `bigChangeBps` applied to
     the aggregate, not per-account).
  3. On alert, atomist triggers a pause (via forced balance-fuse readout on crafted confirm, or
     by revoking custodian substrates + `syncSubstrates` to stop further reports).

### M-2. Custodian revocation requires `syncSubstrates`

`RWAExecutor.onlyCustodian` reads the cached `custodians[]` array, populated only by
`syncSubstrates()`. Revoking a custodian via `revokeMarketSubstrates(...)` does NOT take effect
on the executor until the next sync. Between those two calls, the revoked address can still
`proposeBalance` / `confirmBalance` for **balance accounts that remain granted** on the vault.
(Note: revoking a `BalanceAccountSubstrate` takes effect on `proposeBalance` / `confirmBalance`
**immediately**, without waiting for `syncSubstrates`, thanks to audit fix 17.2 — see M-6.)

- **Why accepted:** enforcing a live check would cost ~2.5k gas per propose/confirm. Dual-custodian
  requirement still holds — a single revoked custodian cannot act unilaterally.
- **Mandatory runbook (MUST be in place before mainnet):**
  ```
  vault.revokeMarketSubstrates(MARKET_ID, [encodeCustodianSubstrate(X)])
  executor.syncSubstrates()
  ```
  Single atomic bundle (multicall / scheduled batch / back-to-back tx in same runbook step).
  Never leave the second call to keeper delay.
- **Out-of-runbook fallback:** `syncSubstrates()` is public — any third party (keeper,
  security firm watcher, etc.) can re-sync if the primary runbook step is missed.

### M-3. TARGET substrates must not overlap with ASSET substrates

Granting an ASSET address as a TARGET (e.g. `(USDC, transfer.selector)`) lets Alpha drain the
executor's token balance via:

```solidity
actions = [{ target: USDC, data: abi.encodeCall(IERC20.transfer, (attacker, bal)) }];
```

The call passes `_validateActionTargets` (TARGET substrate granted), `executor.execute` forwards
it, and the executor's USDC balance lands on the attacker — without any `balances[]` decrement.
Users withdraw at inflated NAV until somebody notices.

- **Why accepted:** no realistic legitimate use case exists for granting an asset as a TARGET —
  assets flow vault ↔ executor via `safeTransfer`, not via batched actions. Adding an on-chain
  check costs ~2.1k gas per action without protecting a real workflow.
- **Mandatory pre-grant review (MUST be in place before mainnet):**
  1. Enumerate ASSET substrates via `vault.getMarketSubstrates(MARKET_ID)` and filter
     `isAssetSubstrate`.
  2. For each proposed TARGET substrate, reject the grant if `target == decodeAddressPayload(assetSub)`
     for any granted asset.
  3. Encode this check as a governance-level pre-flight script (Safe tx simulation) so human
     error is caught before the grant reaches the vault.

### M-4. Oracle manipulation surface

`RWAOperationFuse._convertAmountToUnderlying` and `RWABalanceFuse.balanceOf` consult
`PriceOracleMiddleware.getAssetPrice(...)` at execution time. The price is a direct input to
tracked balances (enter/exit accounting) and to the USD value reported by the balance fuse.

A flash-loanable oracle (raw Uniswap V2 spot, single-block pool price, pool-derived price
without an accumulator) lets an attacker with `ALPHA_ROLE` inflate `valueInUnderlying` on enter,
unwind the flash loan in the same block, and exit later at the real price — pocketing the delta.

See [Oracle requirements](#12-oracle-requirements) for the pre-deployment checklist.

### M-5. Atomist cannot orphan tracked balance (audit fix 17.1)

`syncSubstrates()` enforces an on-chain invariant: any balance account being removed from the
substrate set MUST have `balances[ba] == 0`. Otherwise the call reverts with
`RWAExecutorBalanceAccountStillFunded(ba, residualBalance)` and the cache replacement is
aborted atomically. This closes audit finding 17.1 (NAV-jump via revoke + re-grant cycle):
a careless or compromised atomist cannot zero `getBalanceFuseSnapshot()` while underlying-equivalent
value still exists on external protocols.

- **What is enforced on-chain:** `∀ BA. balances[BA] != 0 ⟹ BA ∈ balanceAccounts[]`.
- **What is also cleaned up:** when a BA is purged, `pendingProposals[BA]` and
  `lastUpdated[BA]` are deleted alongside `balances[BA]`. Re-granting the same address later
  starts from a fully clean state (also closing audit finding 17.3).
- **Operator runbook:** see §13.8 ("Adding/Revoking a balance account") for the strict
  exit-then-revoke order, and §13.8 "Recovery from wrong-order revoke" for the recovery flow
  when the order is mistakenly inverted.
- **Off-chain monitoring:** alert on `BalanceAccountPurged(BA)` events that are not preceded
  by an authorized `revokeMarketSubstrates(BA)` on the vault — potential griefing or
  unexpected re-sync.

### M-6. Custodian operations are gated by vault substrates (audit fix 17.2)

`proposeBalance` and `confirmBalance` validate `balanceAccount` against the vault substrate
set (`IPlasmaVaultGovernance.isMarketSubstrateGranted(MARKET_ID, ...)`), not the executor
cache. This closes audit finding 17.2: a compromised custodian pair cannot inject phantom
balance into a balance account that has been revoked from the vault, even during the race
window between `revokeMarketSubstrates(...)` and `executor.syncSubstrates()`.

- **What is enforced on-chain:** every successful `proposeBalance(BA, _)` or
  `confirmBalance(BA, _)` requires that `BalanceAccountSubstrate(BA)` is currently granted on
  the vault. Reverts with `RWAUnsupportedSubstrate(BALANCE_ACCOUNT, encoded)` otherwise — the
  same selector emitted by fuse-side validation in `RWAOperationFuse._validateSubstratesAndActions`,
  for off-chain log consistency.
- **Why vault, not cache:** the executor cache may lag behind the vault substrate set between
  `revokeMarketSubstrates` and the subsequent `syncSubstrates`. The vault is the source of
  truth.
- **Off-chain monitoring:** alert on `RWAUnsupportedSubstrate(BALANCE_ACCOUNT, ...)` reverts
  in custodian transactions — possible attempt to propose/confirm on a revoked BA. Flag any
  `BalanceProposed` / `BalanceConfirmed` event for an account that is NOT in the current
  `getMarketSubstrates(MARKET_ID)` (should never happen post-fix; if it does, that's a bug
  alert with critical priority).

### `syncSubstrates` — access control & cache stability

`syncSubstrates()` is intentionally **public** (no access modifier). Safety rests on the fact
that the function's data source is `IPlasmaVaultGovernance(VAULT).getMarketSubstrates(MARKET_ID)`
— atomist governance controls what that list contains. A call cannot set the cache to anything
the atomist has not already granted.

- **Why public (design rationale):** emergency fallback. Restricting the function would create a
  governance single-point-of-failure around custodian revocations.
- **What a caller CAN achieve:** bring the executor cache in line with the vault's current
  substrate list. Trigger array-index reordering. Emit `SubstratesSynced` event.
- **What a caller CANNOT achieve:** add or remove substrates (only `grantMarketSubstrates` /
  `revokeMarketSubstrates` on the vault can). Modify singleton values. Corrupt balance
  accounting.

**Cache-order stability — NOT guaranteed.** Substrate arrays (`balanceAccounts[]`,
`custodians[]`, `assets[]`) are rebuilt from scratch on every `syncSubstrates` call, mirroring
the order returned by `getMarketSubstrates`. If the atomist has inserted or removed grants
between sync calls, array indices of remaining entries can shift. Off-chain tooling MUST NOT
persist array positions across `syncSubstrates` calls — always re-read and re-match by address.

---

## 12. Oracle requirements

Every asset (and the vault underlying) registered on an RWA market MUST be priced by an oracle
feed resistant to single-block manipulation.

### Acceptable feed types

- **Chainlink push feeds** with enforced heartbeat + deviation checks.
- **Chainlink pull (Data Streams) / Pyth** with `publishTime` staleness checks.
- **Uniswap V3 TWAP** with a ≥30-minute window.
- **Equivalent TWAP / aggregated-price middleware.**

### Not acceptable

- Raw Uniswap V2 spot prices.
- Single-block DEX quotes.
- Any oracle returning a pool-derived price without an accumulator.

### Attack scenario (flash-loan inflate on enter)

1. Flash-loan 1M units of `asset` from a DEX.
2. Swap into the pool that `PriceOracleMiddleware` reads, pushing `getAssetPrice(asset)` from
   true price `p` to inflated `p × k`, `k > 1`.
3. Call `RWAOperationFuse.enter` with a small real `asset` amount;
   `valueInUnderlying = amount × p × k / underlyingPrice`. Executor records inflated value
   against `balances[balanceAccount]`.
4. Swap back / unwind / repay flash loan in the same block. `getAssetPrice` returns to `p`.
5. In a later block, call `RWAOperationFuse.exit`. The pulled underlying amount is computed
   from the now-real price, but `balances[balanceAccount]` is already inflated — Alpha pockets
   the delta. Other depositors see NAV deflate.

The same vector applies in reverse on `exit` (deflate price, small exit, `removeBalance`
under-decrements, NAV over-states honest depositors).

### Pre-deployment checklist (off-chain enforcement)

Not enforced on-chain. Governance reviewers MUST complete the following before enabling user
deposits on the market:

1. Verify `PlasmaVaultLib.getPriceOracleMiddleware()` returns the expected middleware address.
2. For every ASSET substrate granted on `MARKET_ID` and for the vault's underlying:
   - Inspect the price source the middleware resolves to (`getSourceOfAsset(asset)` or
     equivalent).
   - Confirm the source is one of the acceptable feed types listed above.
   - Confirm staleness / heartbeat thresholds are configured at the source level (Chainlink
     heartbeat ≤24h, Pyth `publishTime` checks active, Uni V3 TWAP window ≥30min).
3. Document the verified oracle topology in the runbook accompanying the market launch.
4. Re-run this checklist any time `PlasmaVaultGovernance.setPriceOracleMiddleware(...)` is
   called or any new ASSET substrate is granted via `grantMarketSubstrates`.

---

## 13. Operations runbooks

### 13.1 Adding a new custodian

1. `vault.grantMarketSubstrates(MARKET_ID, [encodeCustodianSubstrate(newCustodian)])`
2. `executor.syncSubstrates()`
3. Wait for `SubstratesSynced` event. Smoke test: new custodian proposes; existing custodian
   confirms.

Both steps can run in the same transaction (multicall) or as two back-to-back txs. Off-chain
monitor should alert if (1) fires without (2) in the same block.

### 13.2 Revoking a custodian

**MUST** be atomic — see M-2. Exact runbook:

```
multicall([
    vault.revokeMarketSubstrates(MARKET_ID, [encodeCustodianSubstrate(compromised)]),
    executor.syncSubstrates()
])
```

If running as two separate txs, the gap between them is the M-2 exposure window. Emergency
keeper SHOULD be able to call `syncSubstrates()` if operator misses step 2.

### 13.3 Adding a new asset

1. Confirm `PriceOracleMiddleware` has an acceptable feed for the new asset (Oracle checklist).
2. `vault.grantMarketSubstrates(MARKET_ID, [encodeAssetSubstrate(newAsset)])`
3. Confirm the new asset is NOT overlapping with any TARGET substrate (M-3 pre-grant review).
4. `executor.syncSubstrates()`
5. Smoke test: alpha enter with small amount of new asset, custodian round-trip, alpha exit.

### 13.4 Adding a new action target+selector

1. Security review: confirm `target` is NOT in the ASSET set (M-3).
2. `vault.grantMarketSubstrates(MARKET_ID, [encodeTargetSubstrate(target, selector)])`
3. `executor.syncSubstrates()` (not strictly required because TARGET is not cached on executor —
   it's validated at `enter`/`exit` time against `PlasmaVaultConfigLib.isMarketSubstrateGranted`,
   but sync is harmless).
4. Smoke test: alpha enter with an action targeting the new `(target, selector)`.

### 13.5 Updating `bigChangeBps`, `stalenessMax`, `dustThreshold`, `minUpdateInterval`

Singletons cannot be updated in place. Sequence:

1. `vault.revokeMarketSubstrates(MARKET_ID, [encodeXxxSubstrate(oldValue)])`
2. `vault.grantMarketSubstrates(MARKET_ID, [encodeXxxSubstrate(newValue)])`
3. `executor.syncSubstrates()`

If the market is currently paused (pending unpause), the sequence still works — singletons are
re-read from the vault during sync.

### 13.6 Recovering from an accidental pause

1. Identify the cause by reading recent `RWABigChangeDetected` / `RWAPreHookBigChangeDetected`
   events plus the last `BalanceConfirmed`.
2. Decide whether the reported balance is trustworthy:
   - **Trustworthy** (the real economic change exceeded `bigChangeBps`) → atomist signs an
     unpause payload matching the current balance, alpha submits via `RWAUnpauseFuse.unpause`.
   - **Untrusted** (custodian error or compromise) → revoke the custodian pair, `syncSubstrates`,
     investigate off-chain, re-propose correct balance via honest custodians, THEN atomist
     unpauses.

### 13.7 Handling airdrops / stuck tokens

1. Identify the token balance on the executor (`IERC20(token).balanceOf(executor)`).
2. If the token is an ASSET substrate AND part of an expected flow: do NOT rescue; address via
   normal exit flow.
3. If it's an airdrop / unexpected: `PlasmaVault.execute([rescueFuse.rescue(token)])`.
4. Token lands in the vault's underlying balance; NAV reflects the gain at the next
   `_updateMarketsBalances`.

Note: rescue runs dust-check-free because it does not go through `proposeBalance` /
`confirmBalance`. After rescue, the next custodian round-trip will pass the dust check cleanly.

### 13.8 Adding / Revoking a balance account

**Adding a new balance account:**

1. `vault.grantMarketSubstrates(MARKET_ID, [encodeBalanceAccountSubstrate(newBA)])`
2. `executor.syncSubstrates()`

The new balance account starts with `balances[newBA] == 0`, `pendingProposals[newBA] == empty`,
and `lastUpdated[newBA] == 0`. The first custodian update establishes the baseline (no
big-change trigger, see §7).

**Revoking a balance account — STRICT order:**

A revoke that orphans tracked balance is rejected by `syncSubstrates()` to prevent NAV-jump
attacks (audit finding 17.1). Required sequence:

1. **Drain the bucket.**
   `vault.execute([opFuse.exit({balanceAccount: oldBA, amount: <full position>, asset, actions: [...]})])`
   until `executor.balances(oldBA) == 0`. The `actions` array typically liquidates the external
   protocol position back to the vault underlying.
2. **Verify zero.** Off-chain check: `executor.balances(oldBA) == 0`. If non-zero, repeat step 1.
3. **Revoke substrate.**
   `vault.revokeMarketSubstrates(MARKET_ID, [encodeBalanceAccountSubstrate(oldBA)])`.
4. **Sync.** `executor.syncSubstrates()`.
   - Reverts with `RWAExecutorBalanceAccountStillFunded(oldBA, residualBalance)` if step 1 was
     incomplete. Operator must redo step 1 — see "Recovery from wrong-order revoke" below.
   - On success, emits `BalanceAccountPurged(oldBA)` and clears `pendingProposals[oldBA]` and
     `lastUpdated[oldBA]` alongside the cache removal.

**Re-granting a previously revoked balance account.** Same as "Adding a new balance account" —
the address starts with a clean slate (no residual mappings).

**Recovery from wrong-order revoke (atomist mistake).** If `revokeMarketSubstrates(BA)` was
executed before draining `balances[BA]` to zero, both `syncSubstrates()` and
`opFuse.exit({balanceAccount: BA, ...})` will revert (the latter with `RWAUnsupportedSubstrate`
because BA is no longer in the vault substrate set). To recover:

1. `vault.grantMarketSubstrates(MARKET_ID, [encodeBalanceAccountSubstrate(BA)])` — regrant the
   same address.
2. `vault.execute([opFuse.exit({balanceAccount: BA, amount: ..., ...})])` — drain to zero.
3. Verify `executor.balances(BA) == 0`.
4. `vault.revokeMarketSubstrates(MARKET_ID, [encodeBalanceAccountSubstrate(BA)])`.
5. `executor.syncSubstrates()`.

The intermediate `executor.syncSubstrates()` between steps 1 and 4 is harmless — when BA is back
in the substrate set, no purge happens.

**Why the strict order?** Without the `balances[oldBA] == 0` invariant, a revoke + sync would
zero `getBalanceFuseSnapshot()` (cache empty) while the underlying-equivalent value still exists on
external protocols. Re-granting later would resurrect the phantom value, bypassing the
big-change pause via the `prevTotal == 0` short-circuit in `RWABalanceFuse.balanceOf`. See
audit finding 17.1 for the full attack walkthrough.

**Compromised custodian protection (audit fix 17.2).** `proposeBalance` and `confirmBalance`
validate `balanceAccount` against `getMarketSubstrates(MARKET_ID)` (vault — source of truth),
not the executor cache. A compromised custodian pair cannot inject phantom balance into a BA
that has been revoked from the vault substrate set, even during the race window between
`revokeMarketSubstrates(...)` and `executor.syncSubstrates()`.

---

## 14. Events reference

### `RWAExecutor`

| Event | Fields | Emission site |
|---|---|---|
| `BalanceProposed` | `balanceAccount (i)`, `proposer (i)`, `newValue`, `nonce`, `proposedAt`, `proposalHash` | `proposeBalance` |
| `ProposalOverwritten` | `balanceAccount (i)`, `oldProposer (i)`, `newProposer (i)`, `oldNonce`, `newNonce` | `proposeBalance` when pending exists |
| `BalanceConfirmed` | `balanceAccount (i)`, `confirmer (i)`, `oldValue`, `newValue`, `nonce` | `confirmBalance` |
| `BalanceChangedByFuse` | `balanceAccount (i)`, `delta (int256)`, `newBalance` | `addBalance`, `removeBalance` |
| `ActionsExecuted` | `count` | `execute` |
| `SubstratesSynced` | `balanceAccountCount`, `custodianCount`, `assetCount`, `stalenessMax`, `bigChangeBps`, `dustThreshold`, `minUpdateInterval` | `syncSubstrates` |
| `BalanceAccountPurged` | `balanceAccount (i)` | `syncSubstrates` (per orphaned BA, audit fix 17.1) |
| `AssetWithdrawn` | `asset (i)`, `amount` | `withdrawAssetBalance` |
| `RWAExecutorDeployed` (on the storage lib) | `executor`, `marketId` | `getOrCreateExecutor` first call |

### `RWAOperationFuse`

| Event | Fields |
|---|---|
| `ExecutorCreated` | `executor (i)`, `marketId (i)` |
| `RWAOperationFuseEnter` | `version (i)`, `asset (i)`, `amount`, `balanceAccount (i)`, `valueInUnderlying`, `actionsCount` |
| `RWAOperationFuseExit` | `version (i)`, `asset (i)`, `amount`, `balanceAccount (i)`, `valueInUnderlying`, `actionsCount` |

### `RWABalanceFuse`

| Event | Fields |
|---|---|
| `RWABigChangeDetected` | `prevTotal`, `newTotal`, `bigChangeBps` |

### `RWAUnpauseFuse`

| Event | Fields |
|---|---|
| `RWAUnpaused` | `signer (i)`, `confirmedTotalBalance`, `nonce` |

### `RWARescueFuse`

| Event | Fields |
|---|---|
| `RWAAssetRescued` | `asset (i)` |

`(i)` = indexed topic.

---

## 15. Error reference

Key custom errors with diagnostic parameters. All declared in `contracts/fuses/rwa/errors/RWAErrors.sol`.

### Substrate

| Error | Meaning |
|---|---|
| `RWAUnsupportedSubstrate(uint8 type, bytes32 encoded)` | Substrate type byte > 8, or grant is missing from `isMarketSubstrateGranted`. |
| `RWADuplicateSingletonSubstrate(uint8 type)` | More than one of `STALENESS_MAX` / `BIG_CHANGE_BPS` / `DUST_THRESHOLD` / `MIN_UPDATE_INTERVAL` granted. |
| `RWASubstratePayloadOverflow(uint8 type, uint256 value)` | `uint248` payload exceeded. |
| `RWAMandatorySingletonMissing(uint8 type)` | `STALENESS_MAX` or `BIG_CHANGE_BPS` missing after sync. |
| `RWAZeroAddress()` | Encoder called with `address(0)` / rescue called with zero asset. |

### Operation fuse

| Error | Meaning |
|---|---|
| `RWAZeroMarketId()` | Constructor called with `marketId == 0`. |
| `RWAEmptyAssetAndActions()` | `enter`/`exit` called with both `amount == 0` and `actions.length == 0`. |
| `RWAExitExceedsTrackedBalance(address ba, uint256 requested, uint256 tracked)` | `removeBalance` requested > current tracked. |
| `RWAPriceOracleNotSet()` | `PlasmaVaultLib.getPriceOracleMiddleware() == address(0)`. |
| `RWAInvalidPrice(address asset)` | Oracle returned `price == 0`. |
| `RWAOperationExecutorNotDeployed()` | Exit before any enter / createExecutor. |
| `RWAActionDataTooShort(uint256 actionIndex, uint256 dataLength)` | Action calldata < 4 bytes (cannot extract selector). |
| `RWAMultipleMarketsNotSupported(uint256 existingMarketId, uint256 requestedMarketId)` | Vault slot reused for different market. |

### Executor

| Error | Meaning |
|---|---|
| `RWAExecutorUnauthorizedVault()` | `onlyVault` mismatch on `msg.sender`. |
| `RWAExecutorUnauthorizedCustodian(address caller)` | `onlyCustodian` miss (address not in cached `custodians[]`). |
| `RWAExecutorDustCheckFailed(address asset, uint256 balance, uint256 allowed)` | Asset balance above dust allowance. |
| `RWAExecutorSameProposerAndConfirmer(address custodian)` | Same custodian tried to confirm their own proposal. |
| `RWAExecutorProposalHashMismatch(bytes32 expected, bytes32 given)` | Confirm hash does not match pending. |
| `RWAExecutorProposalExpired(uint256 proposedAt, uint256 now, uint256 ttl)` | `now - proposedAt > stalenessMax`. |
| `RWAExecutorMinUpdateIntervalNotMet(uint256 lastUpdated, uint256 now, uint256 minInterval)` | Confirm too soon after previous confirm. |
| `RWAExecutorNoPendingProposal(address ba)` | Confirm before any propose. |
| `RWAExecutorZeroAddressConstructor()` | Executor constructor called with `vault == address(0)`. |
| `RWAExecutorZeroMarketId()` | Executor constructor called with `marketId == 0`. |
| `RWAExecutorBalanceAccountStillFunded(address ba, uint256 residualBalance)` | `syncSubstrates` cannot purge `ba` because `balances[ba] != 0`. Atomist must drain via `RWAOperationFuse.exit` before revoking the substrate (audit fix 17.1, see §13.8). |

### Pre-hook

| Error | Meaning |
|---|---|
| `RWAPreHookExecutorNotDeployed()` | Pre-hook triggered before executor deployed. |
| `RWAPreHookPaused()` | Pause flag set. |
| `RWAPreHookBigChangeDetected(uint256 prevTotal, uint256 newTotal, uint256 bigChangeBps)` | Inline delta check > bps. |
| `RWAPreHookStale(uint256 oldest, uint256 now, uint256 stalenessMax)` | Oldest balance account exceeded staleness. |

### Unpause fuse

| Error | Meaning |
|---|---|
| `RWAUnpauseNotPaused()` | Called when not paused (or executor not deployed). |
| `RWAUnpauseSignatureExpired()` | `block.timestamp > expirationTime`. |
| `RWAUnpauseSignatureReplay(uint256 nonce)` | Nonce already consumed. |
| `RWAUnpauseSignerNotAtomist(address signer)` | Recovered signer lacks `ATOMIST_ROLE`. |
| `RWAUnpauseBalanceMismatch(uint256 signed, uint256 current)` | `confirmedTotalBalance` ≠ `executor.getBalanceFuseSnapshot().totalBalance`. |

### Rescue fuse

| Error | Meaning |
|---|---|
| `RWARescueExecutorNotDeployed()` | Rescue before executor exists. |

---

## 16. Testing

- **Unit tests:** `forge test --match-path 'test/unitTest/fuses/rwa/**'`.
- **Fork integration tests:** `forge test --match-path 'test/fuses/rwa/**'` (require valid RPC
  URLs in `.env`).
- Total test suite covers substrate encoding/decoding, executor semantics (add/remove/execute/
  propose/confirm/sync/rescue), fuse entry points, pre-hook guards, unpause signature paths,
  dust checks, big-change math, and mainnet-fork smoke tests over USDC / USDT / WETH.
