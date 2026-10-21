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
| `REPO_TOKEN_HOLDING` | `0x02` | servicer address in low 160 bits, bits 247..160 = 0 | `TermFinanceSubstrateLib.repoTokenHoldingKey(servicer)` |

Why `SERVICER = 0x00`: legacy lender-side substrates were raw `addressToBytes32(servicer)`
(upper byte already `0x00`), so they decode as `SERVICER` **without migration**. The
`0x01` TYPE byte makes collateral-token substrates provably disjoint from any address
encoding — no collision. `REPO_TOKEN_HOLDING` has the shape of `SERVICER` with another TYPE byte, so
the balance fuse loop (which accepts SERVICER substrates by the strict predicate) never reads it as a
servicer, and old fuses compare exact `addressToBytes32(servicer)` values and ignore it.

Helpers: `isServicerSubstrate(raw)`, `isCollateralTokenSubstrate(raw)`,
`isRepoTokenHoldingSubstrate(raw)` (all strict; dirty bits give false), `repoTokenHoldingKey(servicer)`,
`decodeAddress(raw)`, `decodeSubstrateType(raw)` (defaults to `SERVICER` for TYPE `>= 0x03`; use the
strict predicates, not the decoder, to classify a substrate).

**Granting (governance) — to use a servicer you must grant:**
1. the **servicer substrate** (TYPE `0x00`) for that `TermRepoServicer`, and
2. one **collateral-token substrate** (TYPE `0x01`) per accepted collateral token you intend
   to lock (borrower side only), and
3. the **repo-token holding substrate** (TYPE `0x02`, `repoTokenHoldingKey(servicer)`) if the vault
   holds, or is about to receive, TermRepoTokens of that servicer (lender side only).

`REPO_TOKEN_HOLDING` is the vault's declaration that repo tokens of that servicer are part of its
tracked position. Only with it does the balance fuse count the held repo-token leg and treat a
repo-token balance as exposure; without it, repo tokens sitting in the vault (for example a
donation, which Term cannot prevent) lie outside the tracked set and do not change NAV (ALPHA
rule D-006). A servicer whose `termRepoToken()` cannot be read counts as exposure only inside
`_servicerHasExposure` (the collateral-manager-probe and price-zero gates), with or without HOLDING:
so a blanket proxy pause still freezes NAV. On its own (collateral manager and prices healthy) an
unreadable `termRepoToken()` no longer freezes a servicer without HOLDING: its held leg degrades to 0.
`TermFinanceOfferFuse.enter` (including an edit) requires it, because a won offer mints repo tokens.
`OfferFuse.exit`, `OfferRevealFuse`, `RedeemFuse`, `CleanupFuse` and the whole borrower side do not.

- **Lender:** grant SERVICER + `REPO_TOKEN_HOLDING` before the first offer; revoke HOLDING after the
  last Redeem (while HOLDING is granted a donated token with a non-zero Adapter-B haircut still
  freezes NAV).
- **Borrower:** grant SERVICER (+ collateral pairs) only. A donated repo token then cannot freeze
  NAV or change it.
- Revoking HOLDING while the vault still holds repo tokens drops their value from NAV at once.
  Open offers are not dropped at revoke time (they keep counting through the pending-offer leg);
  their value moves when the auction settles, because the repo tokens then minted to the vault are
  no longer counted. This is documented only: the fuses do not police grant/revoke consequences.
- `grantMarketSubstrates` replaces the whole list: always pass the complete set (servicers,
  collateral pairs, holdings). A vault holding repo tokens or open offers must receive HOLDING before
  the balance fuse is swapped, or in the same batch, otherwise NAV drops by their PV (for offers,
  at settlement).
- Repo tokens bought with another fuse (for example a swapper) count only with HOLDING as well.
- This partly reverses the IL-7974 policy "a granted servicer with a broken proxy blocks NAV":
  the held repo-token leg (its `!rtOk` fail-closed and the repo-token balance signal) now applies only
  to servicers with HOLDING; the `!rtOk` signal inside `_servicerHasExposure` is unchanged.

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
| Offer | `TermFinanceOfferFuse.enter` (requires `REPO_TOKEN_HOLDING`) | `servicer.termRepoLocker()`, `servicer.purchaseToken()`, `offerLocker.lockOffers(...)` | `PendingOffersStorageLib.addPendingOffer` |
| Cancel (pre-reveal) | `TermFinanceOfferFuse.exit` | `offerLocker.unlockOffers(ids)` | `removePendingOfferIfExists` |
| Reveal | `TermFinanceOfferRevealFuse.enter` | `offerLocker.revealOffers(ids, prices, nonces)` | — (stateless) |
| Redeem (post-maturity) | `TermFinanceRedeemFuse.enter` | `servicer.redemptionTimestamp()`, `servicer.purchaseToken()`, `servicer.redeemTermRepoTokens(vault, amount)` | — |
| Cleanup | `TermFinanceCleanupFuse.enter` | `offerLocker.lockedOffer(id)` | prune offers with on-chain `amount == 0` |

**Offer `enter` data** — `TermFinanceOfferFuseEnterData`:
`servicer`, `offerLocker`, `amount`, `offerPriceHash` (bytes32), `existingOfferId` (bytes32, edit-in-place: for a tracked id, edit only on the locker that holds the offer and the locker must return the same id, otherwise `enter` reverts; an untracked id creates a new offer unless it is a live vault offer on that locker, which Term edits in place (see *Known limitation (untracked live bid)*)).
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
`existingBidId` (bytes32, edit-in-place: for a tracked id, edit only on the locker that holds the bid and the locker must return the same id, otherwise `enter` reverts; an edit must keep the same collateral token list (same tokens, same order; amounts may change) because Term compares collateral by index only, otherwise `enter` reverts (the check copies the servicer's pending bids, at most 150, acceptable gas on the edit path); an untracked id creates a new bid unless it is a live vault bid on that locker, which Term edits in place (see *Known limitation (untracked live bid)*); e.g. a second bid on the same locker needs a nonce id), `collateralTokens[]`, `collateralAmounts[]`.
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
regardless of the flag. While the entry is kept and its locker keeps reverting, `balanceOf`
reverts with `TermFinanceBalanceFuseLockerReadFailedForTrackedEntry` (see the error table):
ALPHA unblocks NAV by running this fuse with `pruneOnLockerRevert == true` once the locker is
confirmed dead. Keeps the pending stores bounded across auction cycles (see
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
- **Tracked** servicer (held or unreadable repo balance - only with `REPO_TOKEN_HOLDING` for the servicer - pending offers/bids in storage, locked
  collateral `> 0`, or positive debt obligation) + failed read → **revert intentionally**,
  freezing share math until the proxy/oracle is fixed. Silently zeroing a tracked leg would
  under-/over-report NAV and open a share-mint attack.

The tracked signal is `_servicerHasExposure` (storage entries, held or unreadable repo token
balance (only with `REPO_TOKEN_HOLDING`; an unreadable `termRepoToken()` counts regardless), positive
`getBorrowerRepurchaseObligation`) **or** locked collateral `> 0`. It also
covers a collateral-manager read (`collateralTokens(i)` / `getCollateralBalance`) that fails
mid-enumeration: the collateral leg then reads as unpriced, and a positive debt alone is enough
to freeze NAV instead of subtracting the full debt against a zeroed collateral leg. An unused
servicer (nothing held, nothing in storage, no debt) with the same broken CM still values to `0`.

**Locker-revert handling (NAV side):** a reverting `lockedOffer` / `lockedBid` for an entry
carried in vault storage is NOT read as "no position"; it freezes NAV (row below). Only a
successful read of a cleared entry (offer `amount == 0`; bid `bidder == 0 || amount == 0`)
contributes 0. Unblock via `TermFinanceCleanupFuse` with `pruneOnLockerRevert == true`.

**Recovery with a pre-hook on `execute`:** `PlasmaVault.execute` reads only cached totals
before the actions and refreshes the touched markets after them (Cleanup is market 52), so
without a hook on `execute` ALPHA can run Cleanup directly. If `UpdateBalancesPreHook` (or
`UpdateBalancesIgnoreDustPreHook`, direct or nested in `ExchangeRateValidatorPreHook`) is
wired on `execute`, the `restricted` modifier runs it BEFORE the actions, it refreshes every
active market including 52, `balanceOf` reverts and Cleanup never runs. `removeBalanceFuse`
does not help (it calls `balanceOf` too), and revoking the substrate makes Cleanup revert.
Path: ATOMIST unwires the `execute` pre-hook (`setPreHookImplementations`) -> ALPHA runs
Cleanup with `pruneOnLockerRevert == true` -> ATOMIST re-wires the hook.

**Known limitation (double failure):** if both a collateral-manager per-token read
(`collateralTokens(i)` / `getCollateralBalance`) and `getBorrowerRepurchaseObligation` revert
while `termRepoToken` / `balanceOf` still answer, the servicer leg reports 0 (the unreadable
obligation is read as no debt, IL-7974 policy). The understatement is bounded by the
borrower's equity (collateral minus debt).

**Known limitation (untracked live bid):** a bid that is still live on Term but no longer tracked
(possible only after Cleanup with `pruneOnLockerRevert = true` dropped its entry) is edited in place by
Term when `enter` passes its id. Term applies the new collateral amounts by index to the bid's old token
list (a dropped token stays in the TermRepoLocker without a record, a reordered list is mis-recorded, a
longer list reverts), and the fuse skips the locker, id and token-list checks because the id is not
tracked; it then tracks the bid again with the submitted data. Do not edit such a bid: unlock it with
`TermFinanceBidFuse.exit` before `revealTime` and lock a fresh one. An untracked live offer is likewise
edited in place and tracked again with the new amount.

**Known limitation / follow-up (IL-8830):** a frozen NAV can also block a borrower's repurchase; see
*Known threat* below (IL-8830: documented, no code change). VaultValidator follow-up (other repo):
`TermFinanceMarketValidator` must accept tag 2 (`REPO_TOKEN_HOLDING`), warn when it has no SERVICER
pair, and bump `MODULE_VERSION` 1 to 2.

Reverts that intentionally propagate out of `balanceOf`:

| Error | Raised when |
|-------|-------------|
| `TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked(servicer)` | any leg's oracle read fails/returns 0 on a tracked servicer, or a collateral-manager per-token read (`collateralTokens(i)` / `getCollateralBalance`) fails while the servicer is tracked (held balance, storage, or positive debt); also an out-of-range `redemptionValue` read on a held position |
| `TermFinanceBalanceFuseDebtReadFailedForTrackedServicer(servicer)` | `getBorrowerRepurchaseObligation` fails on a tracked borrower |
| `TermFinanceBalanceFuseDebtRateFailedForTrackedServicer(servicer)` | purchase/repo token, end-of-repurchase-window, or Adapter-B discount-rate read fails while `obligationFace > 0` |
| `TermFinanceBalanceFuseCollateralManagerReadFailedForTrackedServicer(servicer)` | the collateral-manager probe (`termRepoCollateralManager` / `numOfAcceptedCollateralTokens` / accepted-count sanity) fails for a servicer with detectable exposure — held balance, pending storage, or positive debt. Untracked servicers degrade to 0 |
| `TermFinanceBalanceFuseLockerReadFailedForTrackedEntry(locker, entryId)` | `lockedOffer` / `lockedBid` reverts for an offer/bid id carried in vault storage. A zero bound locker is still skipped. Recovery: `TermFinanceCleanupFuse` with `pruneOnLockerRevert == true` after the locker is confirmed dead |
| `TermFinanceBalanceFuseNonZeroRepoRedemptionHaircut(servicer)` | Adapter-B reports a non-zero `repoRedemptionHaircut` on a held pre-maturity position — the rate-amplification convention over-reports NAV, so share math freezes until the convention is revisited. Zero on mainnet today |
| `Errors.WrongAddress` | the vault's price oracle middleware address is unset |

`TermFinanceOfferFuse.enter` additionally reverts with `TermFinanceOfferFuseRepoTokenHoldingNotGranted(servicer)`
when `REPO_TOKEN_HOLDING` is not granted for the servicer.

Constructor immutables: `MARKET_ID`, `TERM_CONTROLLER`, `DISCOUNT_RATE_ADAPTER` (all
non-zero; `marketId > 0`).

---

## Known threat: a frozen market-52 valuation can block a borrower's repurchase

**Mechanism.** `TermFinanceRepurchaseFuse` runs inside `PlasmaVault.execute`, which refreshes
the Term market (52) after the actions. A pre-hook that refreshes balances (e.g.
`UpdateBalancesPreHook`) refreshes it before the actions too. A fail-closed revert of
`TermFinanceBalanceFuse.balanceOf` for a tracked position (see the error table) therefore reverts
the whole `execute`, including the repayment itself.

**What self-heals today.** Fully repaying the servicer being repaid sets its debt to 0, Term
returns its collateral, and the servicer stops counting as tracked, so its own rate, price and
collateral-manager failures degrade to 0. Conditions: no balance-refreshing pre-hook on `execute`;
stale bid/offer entries of that servicer cleaned in the same batch (`TermFinanceCleanupFuse`);
every other tracked servicer healthy; an oracle price for the returned collateral (market 7).

**What still blocks a repayment.**
- a failure on another tracked servicer (held leg with a non-zero redemption haircut, broken adapter, collateral-manager read, debt read);
- a partial repayment of a servicer that cannot be valued;
- a balance-refreshing pre-hook on `execute`;
- a missing oracle price for the returned collateral;
- a donated balance of a market-7 token without a price;
- a negative total for market 52;
- the same servicer also held as a lender with `REPO_TOKEN_HOLDING` while its redemption haircut is non-zero.

A third party cannot freeze market 52 of a pure borrower: a donated repo token without a `REPO_TOKEN_HOLDING`
grant is ignored, and only `msg.sender` can add collateral. It can still block the same `execute` through
market 7 (`ERC20_VAULT_BALANCE`, refreshed together with 52 through the dependency graph): 1 wei of a token
granted in market 7 without an oracle price makes `Erc20BalanceFuse.balanceOf` revert (IL-8834 residual).
Keep a price for every token granted in market 7, or remove the substrate. The remaining triggers are Term-side
failures (upgrade, proxy pause, adapter), vault configuration (oracle, pre-hook) and the negative total.

**Consequence.** Term accepts repayment until the end of the repurchase window; on a live
servicer the window after maturity is only 23 h. After it, anyone can run `batchDefault`:
the liquidator repays the debt and takes collateral worth debt + liquidated damages (8% on the live
servicer, of which 2 points go to Term; about 81k USD on a position of about 1.01M USD). The
rest of the collateral stays credited to the vault in the collateral manager; Term closes collateral
withdrawals between the end of the repurchase window and `redemptionTimestamp` (1 h later on the live
servicer), so it can be withdrawn from `redemptionTimestamp` with `TermFinanceCollateralFuse.exit`, which is
also a market-52 action and waits while the freeze lasts. A freeze before maturity also blocks topping up
collateral on a margin call.

**Mitigation (operational).**
- Repay at least 48 h before maturity. Early repayment earns no rebate; the cost is the forgone carry (roughly 270 USD per 1M USD at a 5% rate) against an 8% default penalty.
- Run a keeper alert on `updateMarketsBalances([52])` reverting while a Term obligation is open, and escalate when maturity is near.
- Do not wire balance-refreshing pre-hooks on `execute` for Term borrower vaults.
- Unblock runbook: the ATOMIST unwires any pre-hook on `execute`; ALPHA prunes stale bid/offer entries with `TermFinanceCleanupFuse` (`pruneOnLockerRevert == true` only for confirmed-dead lockers); the oracle owner restores a missing price; ALPHA then repays each servicer in full with `TermFinanceRepurchaseFuse` (full repayment lets the servicer drop out of the valuation); the ATOMIST re-wires the hook afterwards if needed.

**Not addressed in code.** Decision of 2026-10-19: no emergency repurchase path and no change to
the valuation or to `PlasmaVault`; the residual risk is documented here and tracked in IL-8830.

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
