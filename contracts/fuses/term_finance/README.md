# Term Finance Integration

PlasmaVault fuses for [Term Finance](https://www.term.finance/) — a fixed-rate, fixed-term
repo lending protocol that runs **sealed-bid auctions** (commit → reveal → clear). This
integration lets a vault act as a **lender** (post offers, hold `TermRepoToken`, redeem at
maturity) and as a **borrower** (lock collateral, post bids, repurchase debt).

- **Market id:** `IporFusionMarkets.TERM_FINANCE = 52`
- **Net value reporting:** single signed-int balance fuse aggregating 5 legs across both sides

> All NAV math is in **WAD-USD** (USD scaled by `1e18`). All token amounts passed to fuses
> are **raw token units** (not WAD).

---

## Directory layout

```
contracts/fuses/term_finance/
├── TermFinanceBalanceFuse.sol        # NAV: signed-int aggregation over 5 legs (the only balance fuse)
│
├── TermFinanceOfferFuse.sol          # LENDER  enter=lockOffers / exit=unlockOffers (pre-reveal cancel)
├── TermFinanceOfferRevealFuse.sol    # LENDER  enter=revealOffers
├── TermFinanceRedeemFuse.sol         # LENDER  enter=redeemTermRepoTokens (post-maturity)
│
├── TermFinanceBidFuse.sol            # BORROWER enter=lockBids(+collateral) / exit=unlockBids
├── TermFinanceBidRevealFuse.sol      # BORROWER enter=revealBids
├── TermFinanceCollateralFuse.sol     # BORROWER enter=lock collateral / exit=unlock collateral
├── TermFinanceRepurchaseFuse.sol     # BORROWER enter=submitRepurchasePayment (pay down debt)
│
├── TermFinanceCleanupFuse.sol        # MAINT.  enter=prune stale pending offers + bids from storage
│
├── ext/                              # External Term Finance interface surface (IExt*)
│   ├── IExtTermController.sol            # isTermDeployed, auction results, treasury/reserve
│   ├── IExtTermRepoServicer.sol         # mint/redeem repo tokens, debt obligation, component addrs
│   ├── IExtTermRepoCollateralManager.sol# lock/unlock collateral, balances, accepted-token allowlist
│   ├── IExtTermRepoToken.sol            # ERC20 + decimals/redemptionValue/termRepoId
│   ├── IExtTermAuctionOfferLocker.sol   # lender lockOffers/revealOffers/unlockOffers/lockedOffer
│   ├── IExtTermAuctionBidLocker.sol     # borrower lockBids/revealBids/unlockBids/lockedBid
│   └── IExtTermDiscountRateAdapter.sol  # discount rate + repoRedemptionHaircut (Adapter-B)
│
└── lib/
    ├── TermFinanceSubstrateLib.sol          # typed substrate encoding (SERVICER vs COLLATERAL_TOKEN)
    ├── TermFinancePendingOffersStorageLib.sol # ERC-7201 pending-offer tracking (NAV continuity)
    ├── TermFinancePendingBidsStorageLib.sol   # ERC-7201 pending-bid tracking (NAV continuity)
    └── TermFinancePresentValueLib.sol         # pure PV math (pre/post maturity, faceValue)
```

Tests: `test/unitTest/fuses/term_finance/**` (unit + harnesses + mocks) and
`test/integrationTest/termFinanceEthereum/**` (mainnet fork: `TermFinanceBorrowerFork.t.sol`,
`TermFinanceLiveBalanceFork.t.sol`).

---

## Glossary

| Term | Meaning |
|------|---------|
| **Servicer** | `TermRepoServicer` proxy. Identifies one Term Repo = one maturity + one purchase token + one collateral set. **This is the substrate key.** |
| **Collateral Manager** | `TermRepoCollateralManager` paired with a servicer; enforces margin, holds the accepted-collateral allowlist. |
| **Repo Token** | `TermRepoToken` ERC20 minted at clearing; the lender's claim; redeemable post-maturity. |
| **Purchase Token** | Loan currency (USDC / WETH / USR …) — what lenders supply and borrowers repay. |
| **Offer / Bid** | Sealed lender offer / sealed borrower bid. Committed as a price *hash*, later *revealed* with `(price, nonce)`. |
| **Locker** | `TermAuctionOfferLocker` / `TermAuctionBidLocker` — hold sealed orders during the auction. |
| **Repo Locker** | `TermRepoLocker` — the contract token approvals target (NOT the offer/bid locker). |
| **Redemption Value** | PV factor of one repo-token unit at maturity (`TermRepoToken.redemptionValue()`). |
| **Discount Rate** | Pre-maturity yield used to discount face → PV; sourced from Adapter-B. |
| **Haircut** | `repoRedemptionHaircut` (lender shortfall, post-maturity) / `shortfallHaircutMantissa`. Borrower debt PV takes **no** haircut (Convention B). |
| **Face value** | Notional principal fixed at clearing; PV discounts it back to today. |

---

## Substrate model (`TermFinanceSubstrateLib`)

A substrate is a `bytes32`. The **most significant byte (bits 255..248)** is a TYPE flag;
the remaining 248 bits are data.

| TYPE | Value | Encoding | Built by |
|------|-------|----------|----------|
| `SERVICER` | `0x00` | servicer address in low 160 bits, bits 247..160 = 0 | `PlasmaVaultConfigLib.addressToBytes32(servicer)` (legacy-compatible) |
| `COLLATERAL_TOKEN` | `0x01` | `keccak256(abi.encode(servicer, token))` truncated to 248 bits | `TermFinanceSubstrateLib.collateralPairKey(servicer, token)` |

Why `SERVICER = 0x00`: legacy lender-side substrates were raw `addressToBytes32(servicer)`
(upper byte already `0x00`), so they decode as `SERVICER` **without migration**. The
`0x01` TYPE byte makes collateral-token substrates provably disjoint from any address
encoding — no collision.

Helpers: `isServicerSubstrate(raw)`, `isCollateralTokenSubstrate(raw)`,
`decodeAddress(raw)`, `decodeSubstrateType(raw)` (defaults to `SERVICER` on out-of-range).

**Granting (governance) — to use a servicer you must grant:**
1. the **servicer substrate** (TYPE `0x00`) for that `TermRepoServicer`, and
2. one **collateral-token substrate** (TYPE `0x01`) per accepted collateral token you intend
   to lock (borrower side only).

> ⚠️ **Dependency graph:** because purchase tokens (USDC/WETH/…) flow back into the vault on
> `RedeemFuse.enter`, `OfferFuse.exit`, `BidFuse.exit`, `CollateralFuse.exit`, and on bid
> clearing (loan disbursement), `TERM_FINANCE` (52) must be wired in the vault's market
> dependency graph alongside `ERC20_VAULT_BALANCE` so the vault's ERC20 balance is
> re-evaluated atomically with every position-exiting action. (See `IporFusionMarkets.sol`.)

---

## Lifecycle flows

### Lender side: offer → reveal → (clear) → redeem → cleanup

```
                ┌────────────────────────── auction (off-chain matched at clear) ─────────────────────────┐
 submit window           reveal window                clearing            maturity (redemptionTimestamp)
     │                       │                            │                         │
[OfferFuse.enter]      [RevealFuse.enter]          (Term mints              [RedeemFuse.enter]
 lockOffers(hash)       revealOffers(price,nonce)    TermRepoToken           redeemTermRepoTokens
     │                                               to the vault)                  │
     │ (changed your mind, pre-reveal)                                              ▼
[OfferFuse.exit]                                                            purchase token → vault
 unlockOffers                                                                      │
                                                                          [CleanupFuse.enter] (prune stale)
```

| Step | Fuse · function | Key external calls | Storage |
|------|-----------------|--------------------|---------|
| Offer | `TermFinanceOfferFuse.enter` | `servicer.termRepoLocker()`, `servicer.purchaseToken()`, `offerLocker.lockOffers(...)` | `PendingOffersStorageLib.addPendingOffer` |
| Cancel (pre-reveal) | `TermFinanceOfferFuse.exit` | `offerLocker.unlockOffers(ids)` | `removePendingOfferIfExists` |
| Reveal | `TermFinanceOfferRevealFuse.enter` | `offerLocker.revealOffers(ids, prices, nonces)` | — (stateless) |
| Redeem (post-maturity) | `TermFinanceRedeemFuse.enter` | `servicer.redemptionTimestamp()`, `servicer.purchaseToken()`, `servicer.redeemTermRepoTokens(vault, amount)` | — |
| Cleanup | `TermFinanceCleanupFuse.enter` | `offerLocker.lockedOffer(id)` | prune offers with on-chain `amount == 0` |

**Offer `enter` data** — `TermFinanceOfferFuseEnterData`:
`servicer`, `offerLocker`, `amount`, `offerPriceHash` (bytes32), `existingOfferId` (bytes32, edit-in-place).
**Offer `exit` data**: `servicer`, `offerLocker`, `offerIds[]`.
**Reveal `enter` data**: `servicer`, `offerLocker`, `offerIds[]`, `prices[]`, `nonces[]`.
**Redeem `enter` data**: `servicer`, `amountToRedeem`.

> Token approvals target the **`TermRepoLocker`**, not the offer locker.

### Borrower side: collateral → bid → bid-reveal → (clear) → repurchase → cleanup

```
 pre-bid              submit window         reveal window       clearing        end-of-repurchase window
   │                      │                     │                 │                       │
[CollateralFuse.enter] [BidFuse.enter]    [BidRevealFuse.enter] (Term locks         [RepurchaseFuse.enter]
 lock collateral        lockBids(hash,     revealBids(price,     collateral,         submitRepurchasePayment
   │                    +collateral)        nonce)               disburses loan)      (partial or full)
   │                      │                                          │                       │
[CollateralFuse.exit]  [BidFuse.exit]                               ▼               [CleanupFuse.enter]
 unlock excess          unlockBids (pre-reveal)               debt obligation        (prune stale bids)
 (margin-permitting)                                          created on vault
```

| Step | Fuse · function | Key external calls | Storage |
|------|-----------------|--------------------|---------|
| Lock collateral | `TermFinanceCollateralFuse.enter` | `servicer.termRepoLocker()`, `cm.externalLockCollateral(token, amount)` | — |
| Unlock collateral | `TermFinanceCollateralFuse.exit` | `cm.externalUnlockCollateral(token, amount)` | — |
| Bid | `TermFinanceBidFuse.enter` | `servicer.termRepoLocker()`, `servicer.purchaseToken()`, `bidLocker.lockBids(...)` | `PendingBidsStorageLib.addPendingBid` |
| Cancel (pre-reveal) | `TermFinanceBidFuse.exit` | `bidLocker.unlockBids(ids)` | `removePendingBidIfExists` (CEI: cleared before call) |
| Bid-reveal | `TermFinanceBidRevealFuse.enter` | `bidLocker.termRepoServicer()`, `bidLocker.revealTime()`, `bidLocker.revealBids(...)` | — (stateless) |
| Repurchase | `TermFinanceRepurchaseFuse.enter` | `servicer.termRepoLocker()/purchaseToken()/endOfRepurchaseWindow()`, `servicer.submitRepurchasePayment(amount)`, `servicer.getBorrowerRepurchaseObligation(vault)` | — |
| Cleanup | `TermFinanceCleanupFuse.enter` | `bidLocker.lockedBid(id)` | prune bids where `bidder == 0 \|\| amount == 0` |

**Collateral `enter`/`exit` data** — `TermFinanceCollateralFuse{Enter,Exit}Data`:
`servicer`, `collateralManager`, `collateralToken`, `amount`.
**Bid `enter` data** — `TermFinanceBidFuseEnterData`:
`servicer`, `bidLocker`, `collateralManager`, `amount`, `bidPriceHash` (bytes32),
`existingBidId` (bytes32), `collateralTokens[]`, `collateralAmounts[]`.
**Bid `exit` data**: `servicer`, `bidLocker`, `bidIds[]`.
**Bid-reveal `enter` data**: `bidLocker`, `bidIds[]`, `bidPrices[]`, `bidNonces[]`.
**Repurchase `enter` data**: `servicer`, `amount`.

> Token approvals target the **`TermRepoLocker`**. Collateral `enter` and repurchase `enter`
> use a strict `forceApprove(amount) → call → forceApprove(0)` cleanup; collateral `exit`
> needs no approval (tokens flow out of the locker back to the vault).

> ⚠️ **WithdrawManager required:** every state-changing borrower fuse reverts with
> `*WithdrawManagerRequired` if `PlasmaVault.withdrawManager == address(0)` — borrower debt is
> irrevocable and needs a maturity-aware withdraw constraint.

### Cleanup (`TermFinanceCleanupFuse.enter`)

`TermFinanceCleanupFuseEnterData`: `servicer`, `offerIds[]`, `bidIds[]`, `pruneOnLockerRevert`.
Walks both pending stores, queries the bound locker per id, and removes entries that are stale
on-chain (offer `amount == 0`; bid `bidder == 0 || amount == 0`).

**Locker-revert handling:** if a locker read *reverts* (e.g. a transient pause on
an upgradeable proxy), the entry is NOT provably stale. With `pruneOnLockerRevert == false`
(the safe default) the entry is KEPT and a `...SkippedOnRevert` / `...SkippedBidOnRevert` event
is emitted — a transient pause must never silently erase a still-live offer/bid from NAV. Set
`pruneOnLockerRevert == true` only to force-prune entries an operator has confirmed are dead
(a permanently-broken locker), which prunes and emits `...PrunedOnRevert` / `...PrunedBidOnRevert`.
Entries with a zero bound locker are unrecoverable (no locker to un-pause) and are pruned
regardless of the flag. Keeps the pending stores bounded across auction cycles (see
anti-griefing caps below).

---

## Balance fuse — `TermFinanceBalanceFuse`

`balanceOf()` returns the vault's net Term Finance value in **WAD-USD**. It iterates the
market's `SERVICER` substrates (TYPE `0x00`; collateral-token substrates are skipped — they
are pure allowlist entries) and sums one **signed `int256`** per servicer:

```
leg = +heldRepoTokenPV          (≥0, lender)
      +pendingOffersValue       (≥0, lender — flat lockedAmount, no synthetic accrual)
      +pendingBidsCollateral    (≥0, borrower)
      +lockedCollateralValue    (≥0, borrower)
      −outstandingDebtPV        (≤0, borrower — returned already negated)
```

The debt leg is **added** (`collateral + debt`) because debt is returned as a negative
`int256`. The signed sum is `SafeCast.toUint256()` at the end → **reverts on net-negative**
(insolvency signal; matches `AaveV3BalanceFuse` / `MorphoBalanceFuse`, prevents the ERC4626
share-mint window).

**Per-leg saturation:** each `leg` is clamped to `±MAX_VALUE_PER_LEG = 1e36` WAD-USD
(= `1e18` USD) before summing, so `int256` arithmetic cannot overflow under adversarial
oracle returns. `1e36` is unreachable by any real position; the clamp is a pure overflow
guard. (`MAX_VALUE_PER_LEG_UINT` is the unsigned mirror used inside the debt leg before
negation; keep both in sync.)

### Why per-call `try/catch` instead of one outer catch

Under PlasmaVault **delegatecall**, `address(this)` is the *vault*, not the fuse — so
`try this.fn(...)` would hit the vault fallback and degrade every leg to 0. There is
therefore **no outer self-call**; each foreign Term Finance read is wrapped in its own
`_tryRead*` / `_tryGet*` helper. One broken servicer proxy degrades **only its own leg**,
never the whole `balanceOf` (which is called on every ERC4626 deposit/withdraw).

### Tracked-vs-untracked gate (the important part)

`try/catch` here does **not** silently swallow errors — it normalises both oracle failure
modes (production `UnsupportedAsset`/`UnexpectedPriceResult` revert **and** mock-style zero
return) into a uniform `ok == false`, then a gate decides:

- **Untracked** servicer + failed read → silently degrade that leg to `0`. A misconfigured
  oracle on an unused servicer cannot brick NAV.
- **Tracked** servicer (held repo balance, pending offers/bids in storage, locked collateral
  `> 0`, or positive debt obligation) + failed read → **revert intentionally**, freezing
  share math until the proxy/oracle is fixed. Silently zeroing a tracked leg would under-/
  over-report NAV and open a share-mint attack.

Reverts that intentionally propagate out of `balanceOf`:

| Error | Raised when |
|-------|-------------|
| `TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked(servicer)` | any leg's oracle read fails/returns 0 on a tracked servicer; also an out-of-range `redemptionValue` read on a held position |
| `TermFinanceBalanceFuseDebtReadFailedForTrackedServicer(servicer)` | `getBorrowerRepurchaseObligation` fails on a tracked borrower |
| `TermFinanceBalanceFuseDebtRateFailedForTrackedServicer(servicer)` | purchase/repo token, end-of-repurchase-window, or Adapter-B discount-rate read fails while `obligationFace > 0` |
| `TermFinanceBalanceFuseCollateralManagerReadFailedForTrackedServicer(servicer)` | the collateral-manager probe (`termRepoCollateralManager` / `numOfAcceptedCollateralTokens` / accepted-count sanity) fails for a servicer with detectable exposure — held balance, pending storage, or positive debt. Untracked servicers degrade to 0 |
| `TermFinanceBalanceFuseNonZeroRepoRedemptionHaircut(servicer)` | Adapter-B reports a non-zero `repoRedemptionHaircut` on a held pre-maturity position — the rate-amplification convention over-reports NAV, so share math freezes until the convention is revisited. Zero on mainnet today |
| `Errors.WrongAddress` | the vault's price oracle middleware address is unset |

Constructor immutables: `MARKET_ID`, `TERM_CONTROLLER`, `DISCOUNT_RATE_ADAPTER` (all
non-zero; `marketId > 0`).

---

## Present-value math — `TermFinancePresentValueLib`

Pure library (derived from Yearn V3 `RepoTokenUtils`). `RATE_PRECISION = 1e18`, 360-day count.

| Function | Formula (informal) |
|----------|--------------------|
| `faceValue(repoBalance, redemptionValue, repoTokenPrec, purchasePrec)` | `redemptionValue · repoBalance · purchasePrec / (repoTokenPrec · 1e18)`; returns 0 if `redemptionValue > 1e22` (overflow guard) |
| `presentValuePreMaturity(face, purchasePrec, secondsToMaturity, discountRate, adapterHaircut)` | `pv = face · purchasePrec / (purchasePrec + effRate · dayFrac / 1e18)`, capped at `face`. `effRate = discountRate · (1 + adapterHaircut)/1e18` (haircut amplifies the *rate*, not the face). Inputs clamped: `secondsToMaturity ≤ 100·360·86400`, `adapterHaircut ≤ 1e18`, `discountRate, effRate ≤ MAX_DISCOUNT_RATE = 1e20`. |
| `presentValuePostMaturity(face, shortfallHaircut)` | `pv = face · (1e18 − shortfallHaircut)/1e18`; `shortfallHaircut` clamped to `1e18` |

Borrower debt PV uses `presentValuePreMaturity` with `adapterHaircut = 0` (**Convention B** —
the redemption haircut is lender-only). Post-window debt collapses to `pv = face` via an
explicit zero-floor on `secondsToMaturity` (avoids 0.8.x underflow).

---

## Pending-state storage (ERC-7201)

NAV must keep counting offers/bids that are locked on-chain but not yet cleared/cancelled, so
each `enter` records them in vault-owned storage and `exit`/`cleanup` removes them. Each entry
binds its **own locker** address so cross-cycle orders read against the
correct locker.

| Lib | Namespace | Slot | Per-entry fields | Cap / servicer |
|-----|-----------|------|------------------|----------------|
| `TermFinancePendingOffersStorageLib` | `io.ipor.termFinance.PendingOffers` | `0xb8f435ea…172b4e00` | `offerId`, `offerLocker`, `amount` | `500` (`MAX_PENDING_OFFERS_PER_SERVICER`) |
| `TermFinancePendingBidsStorageLib` | `io.ipor.termFinance.PendingBids` | `0x5990b0b4…66b79e00` | `bidId`, `bidLocker`, `amount`, `collateralTokens[]`, `collateralAmounts[]` | `150` (`MAX_PENDING_BIDS_PER_SERVICER`) |

Common API (both): `add* / removeXIfExists / getPendingXForServicer (parallel arrays) /
getAllPendingServicers / length / isXPending / getXLocker`. Caps are anti-griefing; a breach
blocks new offers/bids on that servicer until `CleanupFuse` prunes stale entries. (Offers cap
is higher than bids because offers can accumulate across uncleaned cycles; bids mirror the
locker's own `MAX_BID_COUNT`.)

---

## Live mainnet addresses (Ethereum)

Evergreen Term Finance proxies (verified in `test/integrationTest/termFinanceEthereum/`):

| Component | Address |
|-----------|---------|
| `TermController` (`TERM_CONTROLLER`) | `0x21FC7B250CCAeECDb2abb38e04617D1f24D98772` |
| `TermDiscountRateAdapter` (Adapter-B, `DISCOUNT_RATE_ADAPTER`) | `0x3C6b0398eEd7dAfcb3C13d482400329a6e25Acd2` |

Per-auction proxies (servicer, collateral manager, lockers, repo token) are **not** evergreen
— resolve them from the servicer at runtime and from auction metadata. Purchase tokens seen in
tests: USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`, WETH, USR.

---

## Section anchors used in code comments

| Anchor | Meaning |
|--------|---------|
| **Aggregation** | Balance-fuse signed-int aggregation + debt-leg failure semantics (share-mint window rationale) |
| **Oracle gate** | Tracked-vs-untracked oracle gate: untracked price-zero degrades to 0, tracked re-raises |
| **Debt read** | Debt-read-failed-on-tracked-servicer must propagate (freeze share math) |
| **Proxy state** | Paused/upgraded servicer or adapter proxy must not silently zero a tracked leg |
| **Locker binding** | Each pending entry binds its own locker (cross-cycle correctness) |
| **Convention B** | Borrower debt PV takes no `repoRedemptionHaircut` |

Research notes in `research/term-finance-*.md`.
