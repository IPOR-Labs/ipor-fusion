# Agua Global Carry Vault Integration

Fuse set that lets an IPOR Fusion **PlasmaVault** allocate into Reservoir's
**Agua Global Carry Vault** (`aguaUSDCgc`) on Ethereum mainnet.

| | |
|---|---|
| **Vault / share token** | `0xa98b4A70E17e55045CDE4972B95Bc2E8CEC22a0F` (the contract is its own ERC-4626 share token) |
| **Underlying asset** | USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` (6 decimals) |
| **Share decimals** | 18 (decimal offset `1e12` between shares and asset) |
| **Market ID** | `IporFusionMarkets.AGUA_GLOBAL_CARRY = 51` |
| **Lockup period** | `lockupPeriod = 432000s` (5 days) — on-chain at the integrated block |
| **Early-redemption fee** | `earlyRedemptionFee = 500 bps` (5%) — on-chain at the integrated block |

> **Asset-generic fuses, USDC-specific config.** The fuse logic reads `vault.asset()` and its
> decimals dynamically — it is **not** hardcoded to USDC. The `USDC` / `aguaUSDCgc` / 6-decimal values
> throughout this document describe the concrete **market-51** instance integrated here; a future Agua
> vault with a different underlying would be supported by configuration alone (new market id + ASSET
> substrate + oracle price feed for that asset), with no change to the fuse code.

---

## 1. Why a dedicated fuse set (motivation)

Agua is an ERC-4626-shaped vault whose **deposit is synchronous and 4626-compliant**, but whose
**exit is asynchronous**:

- `withdraw` / `redeem` / `mint` **revert**;
- `maxWithdraw` / `maxRedeem` return **0**;
- exits go through a **request → complete** lifecycle (5-day lockup), with an optional fee-charging
  instant `redeemEarly` path.

Wiring Agua through the generic `Erc4626SupplyFuse` would make its instant-withdraw path
(`vault.withdraw`) revert, and that revert is **swallowed by a try/catch** in the generic instant
withdraw — so a `PlasmaVault.withdraw` routed through Agua would **silently under-deliver**: a
redemption DoS. This fuse set is therefore **structurally barred from instant withdrawal** (see §7).

The valuation is fully on-chain (Agua's own rate factor), so no RWA custodian-attestation framework
and no standalone price feed are needed; the balance fuse self-values via `convertToAssets` and
`previewCompleteRedemption`.

---

## 2. Architecture & custody model — no executor / no silo

Unlike the Midas integration, this set needs **no external executor or silo**:

- Agua escrows shares **inside the Agua vault itself** on `requestRedemption`
  (`_transfer(holder, address(this), shares)`), and `completeRedemption(receiver)` /
  `redeemEarly(…, receiver, …)` pay **directly** to any address.
- Every fuse runs via **`delegatecall`** from the PlasmaVault, so the `msg.sender` Agua sees is the
  **PlasmaVault**. The PlasmaVault is the **holder, requester, and receiver** for every action.
- Agua allows **at most one active redemption request per holder**, and the whole PlasmaVault is one
  holder. The single pending request is fully queryable on-chain, so **no pending-request storage
  library** is required — the balance fuse reads it live.

> **Operational constraint:** redemptions must be **serialized** at the alpha/keeper level
> (request → complete/cancel before the next request). The redemption fuse pre-checks and reverts a
> typed `AguaRequestRedemptionFuseRequestAlreadyActive(vault)` error.

```
                         ┌──────────────────────────────────────────────┐
   alpha / keeper        │                 PlasmaVault                    │
   ──── FuseAction ────► │  (holds aguaUSDCgc shares; holder & receiver)  │
                         │                                                │
                         │   delegatecall ▼            ▲ delegatecall      │
                         │  ┌──────────────┐   ┌────────────────────────┐ │
                         │  │ AguaSupply   │   │ AguaRequestRedemption  │ │
                         │  │  Fuse        │   │ AguaClaimRedemption    │ │
                         │  │ enter / exit │   │ AguaRedeemEarly  Fuses │ │
                         │  └──────┬───────┘   └───────────┬────────────┘ │
                         │         │  AguaBalanceFuse.balanceOf() (view)  │
                         └─────────┼───────────────────────┼─────────────┘
                          deposit  │   request/complete/    │
                            ▼      │   cancel/redeemEarly    ▼
                         ┌──────────────────────────────────────────────┐
                         │     Agua Global Carry Vault (aguaUSDCgc)       │
                         │   USDC in/out · shares mint/burn/escrow        │
                         └──────────────────────────────────────────────┘
```

---

## 3. Components

| Contract | Role | Interfaces |
|---|---|---|
| `AguaSupplyFuse` | Synchronous deposit only; `exit` reverts | `IFuseCommon` |
| `AguaRequestRedemptionFuse` | Async exit lifecycle: `enter` = request, `exit` = cancel | `IFuseCommon` |
| `AguaClaimRedemptionFuse` | Complete an unlocked request: `enter` = complete | `IFuseCommon` |
| `AguaRedeemEarlyFuse` | Instant fee-charging exit: `enter` = redeemEarly | `IFuseCommon` |
| `AguaBalanceFuse` | NAV in USD (18 decimals) | `IMarketBalanceFuse` |
| `lib/AguaSubstrateLib` | Typed substrate encode / decode / validate | — |
| `ext/IAguaGlobalCarryVault` | Minimal interface to the Agua vault | — |

> **Why three redemption fuses instead of one?** Each IPOR Fusion fuse is independently
> added/removed via `addFuses`/`removeFuses` and follows the generic `enter`/`exit` selector
> convention (see the Midas async integration). Splitting the async exit into request (`enter`)
> + cancel (`exit`), claim, and the fee-charging instant `redeemEarly` lets governance enable or
> disable each path independently — in particular the lossy `redeemEarly` path can be granted
> separately from the free `request → complete` path — and keeps every fuse on the standard
> `enter`/`exit` shape that the FuseAction tooling expects.

All fuses are **stateless** (only `immutable VERSION` / `MARKET_ID`); they hold no storage because
they execute in the PlasmaVault storage context via delegatecall. Each constructor reverts
`Errors.WrongValue()` if `marketId == 0`.

---

## 4. Configuration

### 4.1 Substrate types (`AguaSubstrateLib`)

Standard `[type (96 bits) | address (160 bits)]` `bytes32` layout:

| Type | Name | Meaning |
|---|---|---|
| 0 | `UNDEFINED` | invalid |
| 1 | `VAULT` | the Agua vault address (also its own share token) |
| 2 | `ASSET` | allowed deposit/redemption asset (USDC) |

Grants required for market 51:

```
├── VAULT: aguaUSDCgc (0xa98b4A70E17e55045CDE4972B95Bc2E8CEC22a0F)
└── ASSET: USDC        (0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)
```

### 4.2 Governance wiring checklist

- `addBalanceFuse(51, AguaBalanceFuse)` — register the balance fuse for market 51.
- `addFuses([AguaSupplyFuse, AguaRequestRedemptionFuse, AguaClaimRedemptionFuse, AguaRedeemEarlyFuse])` —
  make the fuses callable via `execute`. Grant `AguaRedeemEarlyFuse` only when the lossy instant-exit
  path is intended (it can be withheld independently of the free `request → complete` path).
- `grantMarketSubstrates(51, [VAULT, ASSET])` — as above.
- **Do NOT** add any of these fuses to `configureInstantWithdrawalFuses` (see §7 — none has an
  `instantWithdraw(bytes32[])` selector and they would revert at runtime anyway).
- Consider a **governance cap** on capital routed to market 51 (Agua admin trust, §8).

---

## 5. Operation paths (detailed)

Every action is an explicit `FuseAction` dispatched by the PlasmaVault `execute` against the fuse's
function selector. All amounts are **clamped** so the action degrades to a safe no-op instead of
reverting on transient conditions. The vault address argument is **always** validated as a granted
`VAULT` substrate first; for deposit the resolved `asset()` is additionally validated as a granted
`ASSET` substrate.

### 5.1 Deposit — `AguaSupplyFuse.enter`

`enter(AguaSupplyFuseEnterData{ address vault; uint256 assetAmount; uint256 minSharesOut })`

| Step | Action |
|---|---|
| 1 | if `assetAmount == 0` → **return** (no-op) |
| 2 | `validateVaultGranted(MARKET_ID, vault)` → revert `AguaFuseUnsupportedSubstrate(VAULT, vault)` if not granted |
| 3 | `asset = vault.asset()`; `validateAssetGranted(MARKET_ID, asset)` → revert `AguaFuseUnsupportedSubstrate(ASSET, asset)` if not granted |
| 4 | `final = min( min(assetAmount, USDC.balanceOf(PlasmaVault)), vault.maxDeposit(PlasmaVault) )` — clamps to held balance **and** the deposit cap, so a deposit never reverts on `DepositExceedsCap` |
| 5 | if `final == 0` → **return** (no-op; e.g. zero held balance or zero cap headroom) |
| 6 | `USDC.forceApprove(vault, final)` → `shares = vault.deposit(final, PlasmaVault)` → `USDC.forceApprove(vault, 0)` (approval cleanup) |
| 7 | if `shares < minSharesOut` → revert `AguaSupplyFuseInsufficientShares(shares, minSharesOut)` |
| 8 | emit `AguaSupplyFuseEnter(VERSION, vault, final, shares)` |

Result: USDC leaves the PlasmaVault, `aguaUSDCgc` shares are minted **to** the PlasmaVault.

```
PlasmaVault ──USDC(final)──► Agua.deposit ──shares──► PlasmaVault
```

### 5.2 `AguaSupplyFuse.exit` — always reverts

`exit(bytes calldata)` → `revert AguaSupplyFuseExitNotSupported()`. Exits go exclusively through the
redemption fuse set (`AguaRequestRedemptionFuse` / `AguaClaimRedemptionFuse` / `AguaRedeemEarlyFuse`).
The selector exists only to keep an `exit(bytes)` shape; it is **not** the instant-withdraw selector
(see §7).

### 5.3 Request redemption — `AguaRequestRedemptionFuse.enter`

`enter(AguaRequestRedemptionFuseEnterData{ address vault; uint256 shares })`

| Step | Action |
|---|---|
| 1 | `validateVaultGranted(MARKET_ID, vault)` |
| 2 | `shares = min(shares, vault.balanceOf(PlasmaVault))` — clamp to held shares |
| 3 | if `shares == 0` → **return** (no-op) |
| 4 | `(activeShares,,,) = vault.getRedemptionRequest(PlasmaVault)`; if `activeShares != 0` → revert `AguaRequestRedemptionFuseRequestAlreadyActive(vault)` (clean error vs. Agua's string revert) |
| 5 | `vault.requestRedemption(shares)` — Agua `_transfer`s the shares into itself (escrow) and freezes `yieldFactorAtRequest`; sets `unlockTime = now + 5 days` |
| 6 | emit `AguaRequestRedemptionFuseRequested(VERSION, vault, shares)` |

Result: `shares` leave `balanceOf(PlasmaVault)` and become the **frozen pending leg** (valued by the
balance fuse via `previewCompleteRedemption`). No USDC moves yet.

### 5.4 Complete redemption — `AguaClaimRedemptionFuse.enter`

`enter(AguaClaimRedemptionFuseEnterData{ address vault })`

| Step | Action |
|---|---|
| 1 | `validateVaultGranted(MARKET_ID, vault)` |
| 2 | `assets = vault.completeRedemption(PlasmaVault)` — Agua reverts `LockupNotFinished` if `now < unlockTime`, or `NoActiveRequest` if none; otherwise burns the escrowed shares and pays USDC at the **frozen** factor (no fee) |
| 3 | emit `AguaClaimRedemptionFuseCompleted(VERSION, vault, assets)` |

Result: escrowed shares burned; **USDC paid directly to the PlasmaVault**; request cleared. The
payout equals the pre-completion `previewCompleteRedemption` snapshot.

```
(after unlockTime)  Agua.completeRedemption ──USDC(frozen value)──► PlasmaVault   [shares burned]
```

### 5.5 Cancel redemption — `AguaRequestRedemptionFuse.exit`

`exit(AguaRequestRedemptionFuseExitData{ address vault })`

| Step | Action |
|---|---|
| 1 | `validateVaultGranted(MARKET_ID, vault)` |
| 2 | `vault.cancelRedemption()` — Agua reverts `NoActiveRequest` if none; otherwise returns the escrowed shares to the PlasmaVault and clears the request |
| 3 | emit `AguaRequestRedemptionFuseCancelled(VERSION, vault)` |

Result: escrowed shares returned to `balanceOf(PlasmaVault)` (back to the free leg); no USDC moves.

### 5.6 Instant early redemption — `AguaRedeemEarlyFuse.enter`

`enter(AguaRedeemEarlyFuseEnterData{ address vault; uint256 shares; uint256 minAssetsOut })`

| Step | Action |
|---|---|
| 1 | `validateVaultGranted(MARKET_ID, vault)` |
| 2 | `shares = min(shares, vault.balanceOf(PlasmaVault))` — clamp to held shares |
| 3 | if `shares == 0` → **return** (no-op) |
| 4 | `assets = vault.redeemEarly(shares, PlasmaVault, minAssetsOut)` — instant; burns from `balanceOf`, charges the **5% early-redemption fee**, pays USDC to the PlasmaVault, and reverts `RedeemSlippageExceeded` if `assets < minAssetsOut` |
| 5 | emit `AguaRedeemEarlyFuseRedeemed(VERSION, vault, shares, assets)` |

Result: immediate USDC to the PlasmaVault, **net of the 5% fee**. This bypasses the lockup and the
async request; it is **not** an instant-withdraw fuse path — it is an explicit, slippage-guarded
alpha action (see §7). Operates on **free** shares only, independent of any pending request. Lives in
its own fuse so governance can grant the lossy fee path separately from the free request/complete path.

### 5.7 Read NAV — `AguaBalanceFuse.balanceOf` (view)

`balanceOf() returns (uint256 balance)` — total Agua NAV held by the PlasmaVault in USD (18 dec).

| Step | Action |
|---|---|
| 1 | `substrates = getMarketSubstrates(MARKET_ID)`; if `len == 0` → **return 0** |
| 2 | for each substrate: decode; skip if `substrateType != VAULT` |
| 3 | `freeUsdc = vault.convertToAssets(vault.balanceOf(PlasmaVault))` — **free leg**, live NAV |
| 4 | `pendingUsdc = vault.previewCompleteRedemption(PlasmaVault)` — **pending leg**, frozen NAV (0 if none) |
| 5 | `usdc = freeUsdc + pendingUsdc`; if `usdc == 0` → continue to next substrate |
| 6 | require price oracle middleware set, else revert `AguaBalanceFusePriceOracleNotSet()` |
| 7 | `(price, priceDecimals) = oracle.getAssetPrice(vault.asset())` |
| 8 | `balance += convertToWad(usdc * price, asset.decimals() + priceDecimals)` |

See §6 for the accounting proof and a worked decimal example.

---

## 6. Balance / NAV accounting (the core correctness argument)

The NAV of the PlasmaVault's Agua position has exactly **two legs**, both denominated in USDC
(6 dec) then priced to 18-dec USD:

| Leg | Source | Rate factor | Behaviour |
|---|---|---|---|
| **Free** | `convertToAssets(balanceOf(PlasmaVault))` | `_getCurrentRateFactor()` (**live**) | grows with yield |
| **Pending** | `previewCompleteRedemption(PlasmaVault)` | `request.yieldFactorAtRequest` (**frozen**) | fixed at request time; 0 when none |

**No double-count, no undercount** — verified against the Agua source:

1. `requestRedemption` executes `_transfer(holder, address(this), shares)`, so escrowed shares
   **leave** `balanceOf(holder)`. The free leg therefore stops counting them.
2. The escrowed shares are valued **exactly once**, via the pending leg.
3. `previewCompleteRedemption` calls the **same** internal `_calculateRedemptionAssets(request)` as
   `completeRedemption`, and the complete path charges **no fee** → the marked pending value equals
   the USDC that will actually be received.
4. During the lockup the free leg grows while the pending leg stays frozen — matching the economic
   reality that escrowed shares accrue no yield during lockup.

> `redeemEarly` and `cancel` need no special handling here: after `cancel` the shares re-enter
> `balanceOf` (free leg); after `redeemEarly` the shares are burned and the resulting USDC is held by
> the PlasmaVault and accounted by the underlying-asset balance fuse, not this one.

### Worked decimal example

USDC has 6 decimals; assume the oracle returns `price = 1e18`, `priceDecimals = 18`.

```
convertToWad(usdc * 1e18, 6 + 18) = usdc * 1e18 * 1e18 / 1e24 = usdc * 1e12
```

So `500.000000 USDC` (`usdc = 500_000000`) → `500 * 1e12 * 1e6` = `500e18` USD (18-dec WAD). ✔

---

## 7. Instant-withdraw exclusion (redemption-DoS impossibility)

None of the Agua fuses (`AguaSupplyFuse`, `AguaRequestRedemptionFuse`, `AguaClaimRedemptionFuse`,
`AguaRedeemEarlyFuse`) implements `IFuseInstantWithdraw`, and **no `instantWithdraw(bytes32[])`
selector exists** on any of them. Consequences:

- No fuse can be registered as an instant-withdraw fuse; even a mis-configuration would revert
  at runtime in `PlasmaVaultMarketsLib.withdrawFromMarkets` (defense in depth).
- A user `PlasmaVault.withdraw` can therefore **never** auto-trigger an Agua exit. All Agua exits are
  explicit alpha `FuseAction`s (request `enter` / cancel `exit` / claim `enter` / redeemEarly `enter`).
- The economically-instant `redeemEarly` is itself gated behind an explicit alpha action with a
  `minAssetsOut` slippage guard — it is never reachable from the generic withdraw path.

This is asserted by `AguaDosImpossibilityTest` (low-level `call` of `instantWithdraw(bytes32[])`
returns `success == false` for every fuse).

---

## 8. Security considerations

- **Agua admin / counterparty trust:** `ADMIN_ROLE` sets the NAV rate (`setRate`, LayerZero-broadcast)
  and can `adminWithdraw` **all** assets (including user deposits) with **no timelock and no cap**.
  Both NAV and principal depend on a trusted Reservoir key. There is **no `pause()`**. This is an
  accepted counterparty trust (same class as Midas's admin-set data feed). **Mitigation:** apply a
  governance cap on capital routed to market 51.
- **Single-active-request serialization:** the whole PlasmaVault is one Agua holder → only one
  pending redemption at a time. The fuse pre-checks and reverts a typed error; alpha/keeper must
  sequence request → complete/cancel before the next request. Rolling/partial redemptions must be
  serialized.
- **Share-escrow accounting:** free shares at live NAV, escrowed/pending leg once at frozen NAV →
  no double-count, no undercount (§6).
- **Oracle:** the balance fuse only needs the well-established USDC price; NAV itself comes from
  Agua's own rate-factor `convertToAssets`, so there is **no spot/AMM price read** and no flash-loan
  price-manipulation vector.
- **Fuse safety:** stateless (delegatecall), no storage beyond immutables; `forceApprove → deposit
  → forceApprove(0)` approval cleanup on the supply path; Agua's mutating functions are
  `nonReentrant`.
- **`redeemEarly` value loss:** the 5% fee path is only reachable via an explicit alpha action with a
  `minAssetsOut` guard; never auto-invoked. Alpha must justify it versus the free `request → complete`
  path.

---

## 9. Events & errors reference

**Events**

| Contract | Event |
|---|---|
| `AguaSupplyFuse` | `AguaSupplyFuseEnter(version, vault, assetAmount, shares)` |
| `AguaRequestRedemptionFuse` | `AguaRequestRedemptionFuseRequested(version, vault, shares)` |
| `AguaRequestRedemptionFuse` | `AguaRequestRedemptionFuseCancelled(version, vault)` |
| `AguaClaimRedemptionFuse` | `AguaClaimRedemptionFuseCompleted(version, vault, assets)` |
| `AguaRedeemEarlyFuse` | `AguaRedeemEarlyFuseRedeemed(version, vault, shares, assets)` |

**Errors**

| Error | Raised by | When |
|---|---|---|
| `AguaSupplyFuseInsufficientShares(shares, minSharesOut)` | supply | minted shares below slippage floor |
| `AguaSupplyFuseExitNotSupported()` | supply | `exit` called |
| `AguaRequestRedemptionFuseRequestAlreadyActive(vault)` | request redemption | request while one is active |
| `AguaFuseUnsupportedSubstrate(substrateType, addr)` | substrate lib | vault/asset not granted |
| `AguaBalanceFusePriceOracleNotSet()` | balance | oracle middleware unset while NAV > 0 |
| `Errors.WrongValue()` | all (constructor) | `marketId == 0` |

> Agua-side reverts (`LockupNotFinished`, `NoActiveRequest`, `RedeemSlippageExceeded`,
> `DepositExceedsCap`, `InsufficientBalance`, …) bubble up unchanged from the vault.

---

## 10. Testing

Fork tests run against the real Agua vault (`ETHEREUM_PROVIDER_URL` required).

```bash
forge test --match-path 'test/fuses/agua/*' -vvv
forge coverage --match-path 'test/fuses/agua/*'   # 100% lines / branches / functions on agua/*
```

| Test file | Covers |
|---|---|
| `AguaSupplyFuseTest` | deposit, maxDeposit/balance clamps, zero & clamp-to-zero no-ops, slippage revert, substrate reverts, `exit` revert |
| `AguaRequestRedemptionFuseTest` | request/escrow, single-active-request guard, clamp, zero no-op, cancel (`exit`) return-shares, cancel-with-no-request revert |
| `AguaClaimRedemptionFuseTest` | complete-after-lockup, revert-before-unlock, complete-with-no-request revert, full lifecycle |
| `AguaRedeemEarlyFuseTest` | redeemEarly (≈5% fee), clamp-to-balance, slippage revert, zero no-op |
| `AguaBalanceFuseTest` | free-only leg, free+pending (no double-count), frozen pending across warp, empty/zero-substrate cases, oracle-not-set revert |
| `AguaSubstrateLibTest` | encode/decode round-trip, grant validation |
| `AguaDosImpossibilityTest` | no fuse exposes `instantWithdraw(bytes32[])` |

---

## 11. Out of scope (this PR)

- **No standalone price feed** for `aguaUSDCgc`: the balance fuse self-values. If standalone pricing
  is ever needed, the generic `price_oracle/price_feed/ERC4626PriceFeed.sol` works as-is against
  Agua's 4626-compliant `convertToAssets` / `decimals`.
- No executor, no `*ExecutorStorageLib`, no `*PendingRequestsStorageLib`, no claim-from-executor fuse
  (Agua pays the holder directly, so `AguaClaimRedemptionFuse` just calls `completeRedemption`).
- Ethereum mainnet only (Monad deployment out of scope).
</content>
</invoke>
