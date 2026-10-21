# ERC4626 Supply and Balance Fuses

## Overview

Generic fuse pair that lets a Plasma Vault supply to and withdraw from any EIP-4626 vault, and value those
positions in the vault NAV.

| Contract | Purpose |
|---|---|
| `Erc4626SupplyFuse` | `enter` = deposit, `exit` = withdraw; `enterTransient` / `exitTransient`; `instantWithdraw` (`IFuseInstantWithdraw`) |
| `Erc4626BalanceFuse` | `balanceOf()` = USD value (WAD) of the vault shares held in all granted ERC4626 vaults |

The fuses are stateless (immutables `VERSION`, `MARKET_ID`) and run via `delegatecall` from `PlasmaVault.execute`,
so they act for the Plasma Vault itself.

## Market and Substrates

- **One fuse instance per market ID.** The generic markets are `IporFusionMarkets.ERC4626_00NN`, i.e.
  `ERC4626_0001 = 100_001` through `ERC4626_0020 = 100_020` in `contracts/libraries/IporFusionMarkets.sol`. The same
  code is also deployed for venue-specific ERC4626 markets: `GEARBOX_POOL_V3` (3), `FLUID_INSTADAPP_POOL` (5),
  `EULER_V2` (11) and `META_MORPHO_000N`. Everything in this README applies to those instances too.
- **Substrates are vault addresses**, encoded as `bytes32` (`PlasmaVaultConfigLib.addressToBytes32`). A vault is usable
  for a market only if it is granted to that market: `PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, vault)`.
- The balance fuse iterates the same substrates (`getMarketSubstrates(MARKET_ID)`).
- An ungranted vault makes `enter` and `exit` revert with `Erc4626SupplyFuseUnsupportedVault(action, vault)`.

## enter

1. `vaultAssetAmount == 0` returns 0 immediately (before the substrate check).
2. Reverts `Erc4626SupplyFuseUnsupportedVault("enter", vault)` if the vault is not granted.
3. Amount = `min(vaultAssetAmount, balance of IERC4626(vault).asset() held by the Plasma Vault)`.
   If that balance is 0, returns 0 with no deposit and no event (a skip, not a revert).
4. `forceApprove(vault, amount)`, then `deposit(amount, plasmaVault)`. `maxDeposit` is **not** read; a vault that
   refuses the deposit makes the deposit revert, and that revert propagates.
5. Reverts `Erc4626SupplyFuseInsufficientShares(received, minSharesOut)` if `shares < minSharesOut`.
6. Emits `Erc4626SupplyFuseEnter(version, asset, vault, amount)` and returns the deposited amount.

## exit

The exit is sized against a cap. The cap is:

1. `maxWithdraw(plasmaVault)` when it is greater than 0. This is the standard EIP-4626 cap and keeps fee-bearing
   vaults working (IL-6961).
2. Otherwise, when shares are held: `previewRedeem(shares)`, falling back to `convertToAssets(shares)` if
   `previewRedeem` reverts. This is the IL-8505 addition for vaults that under-report `max*`: Morpho Vaults V2 returns
   a constant 0 from `maxDeposit/maxMint/maxWithdraw/maxRedeem` while `withdraw/redeem` work (ipor-fusion GitHub
   issue #554).
3. Otherwise 0.

The function returns 0 without calling `withdraw` when the requested amount is 0, when no shares are held, or when
the cap rounds to 0 (dust shares whose `previewRedeem` is 0).

- A partial exit (requested amount below the cap) is `withdraw(requested, plasmaVault, plasmaVault)`. A full exit
  (requested amount >= the cap) is `redeem(min(balanceOf, maxRedeem), plasmaVault, plasmaVault)`, using `balanceOf`
  when `maxRedeem` is 0 (Morpho Vaults V2), so a pending performance fee in a nested PlasmaVault cannot make
  `withdraw(maxWithdraw)` revert (IL-8489). `maxSharesBurned` applies to both paths.
- A full exit sized by `previewRedeem(shares)` and withdrawn (not redeemed) may leave share dust worth at most 1 wei of the underlying asset
  (about 1e12 share-wei for 18-decimal shares over a 6-decimal asset). The balance fuse values it at 0 and the fuse
  never exits it: a later exit of the dust is a no-op (see the gas note below).
- `maxSharesBurned` (0 = no limit): if the shares burned exceed it, reverts
  `Erc4626SupplyFuseExcessiveSharesBurned(sharesBurned, maxSharesBurned)`.
- Emits `Erc4626SupplyFuseExit(version, asset, vault, assets, shares)` and returns the shares burned.

### Transient variants

- `enterTransient`: inputs `[vault, amount, minSharesOut]`; output `[suppliedAmount]`.
- `exitTransient`: inputs `[vault, amount, maxSharesBurned]`; output `[sharesBurned]`.

Inputs and outputs go through `TransientStorageLib`, keyed by the fuse `VERSION`.

## Failure Behaviour: Revert vs Skip

| Entry point | Vault cannot pay (paused, illiquid, ERC-7540 async) | Result |
|---|---|---|
| `exit()` (ALPHA `execute`) | `withdraw` reverts | The whole batch reverts |
| `instantWithdraw()` (user withdrawal path) | `withdraw` reverts and is caught | Emits `Erc4626SupplyFuseExitFailed(version, asset, vault, assets)`; the PlasmaVault continues with the next market |

- The ALPHA must not request exits from vaults that cannot pay at that moment; one such exit reverts the batch.
- The try/catch in `instantWithdraw` covers **only** the vault's `withdraw()` call. The substrate check and the
  view reads (`maxWithdraw`, `balanceOf`, the `convertToAssets` fallback, `asset()`) are not caught, so an ungranted
  vault or a reverting view still reverts `instantWithdraw` (a reverting `previewRedeem` is caught and falls back to
  `convertToAssets`). The market refresh after a withdrawal calls the same views, so this adds no new failure mode.
- `instantWithdraw` params: `[amount, vault]`; the Plasma Vault fills `params[0]` with the amount it still needs, so
  the configured entry is `[bytes32(0), bytes32(uint256(uint160(vault)))]`. It passes `maxSharesBurned = 0` (no limit).
- Async / request-based vaults (ERC-7540, Agua) must not be wired through this fuse: `previewRedeem` reverts or the
  `withdraw` reverts, and on the user path the swallowed revert under-delivers silently — see
  `contracts/fuses/agua/README.md` and use a dedicated fuse family.

## Balance Fuse

`balanceOf()` is a view. For each granted vault it computes
`convertToAssets(balanceOf(plasmaVault))`, multiplies by the price from the Price Oracle Middleware for
`vault.asset()`, and converts to WAD using the asset decimals and price decimals. No granted vaults gives 0.

- A price feed for every underlying asset must be configured in the Price Oracle Middleware.
- `convertToAssets` is not capped by `maxWithdraw` and, per EIP-4626, excludes exit fees. For a fee-bearing or
  illiquid vault, NAV can therefore be higher than what an exit would pay.

## Known Limitations and Operational Notes

- **Three builds of this fuse exist on-chain; only this one exits Morpho Vaults V2.**

  | Build | Exit cap | `enter`/`exit` ABI | Bytecode fingerprint |
  |---|---|---|---|
  | pre-clamp (4,013 B; the large majority of live installs) | `convertToAssets(balanceOf)`; never reads `maxWithdraw` | 2-field structs (`exit` selector `0x92876ac8`) | neither `ce96cb77` nor `4cdad506` |
  | clamp (6,048 B; published in ipor-abi since 2026-09-16; a handful of installs) | `maxWithdraw`, silent no-op at 0 — **cannot exit Morpho Vaults V2** | 3-field structs (`exit` selector `0x8467bd30`) | `ce96cb77` (`maxWithdraw`) only |
  | IL-8505 (this code) | `maxWithdraw`, fallback `previewRedeem(balanceOf)` at 0 | 3-field structs | `ce96cb77` and `4cdad506` (`previewRedeem`) |

  Until the IL-8505 build replaces the published entries, do not wire a new Morpho Vaults V2 market through a fuse
  taken from ipor-abi: `enter` works, `exit` is a silent no-op and user redemptions through that market revert.
- **Rollout from the pre-clamp build is a migration, not an address swap.** The ABI of `enter`/`exit` changes
  (2-field → 3-field structs; off-chain callers that pin fuse addresses must switch the call format), and exits that
  the pre-clamp build sized at `convertToAssets` are now capped at `maxWithdraw` (partial exits succeed silently
  where `0 < maxWithdraw < requested`; read the amount from the `Erc4626SupplyFuseExit` event). Per vault:
  `addFuses(new)` → `configureInstantWithdrawalFuses` (the full list in the same order, with params) →
  `removeFuses(old)` → off-chain config. `removeFuses` does not touch the instant-withdrawal list, which is called
  without an `isFuseSupported` check, so skipping the reconfiguration leaves user redemptions on the old fuse.
  Verify with `getInstantWithdrawalFuses` and the fingerprint above. Ship this build together with any redeem-based
  full-exit change (IL-8489) as one deployment, not two migrations.
- **No grant-time guard, on purpose.** Granting a vault does not check its `max*` values, exit liquidity or oracle
  price. These risks are documented here, not policed by the fuse.
- **Over-reported `maxWithdraw` and partial exits.** A nested PlasmaVault with a pending performance fee (IL-8489)
  reports a `maxWithdraw` it cannot deliver; full exits use `redeem` and are safe, but a partial exit close to the cap
  still uses `withdraw` and can revert.
- **Vaults without `withdraw`.** A vault that supports only `redeem` can be fully exited but not partially.
- **Cannot-pay vaults.** Paused, illiquid or ERC-7540 async vaults revert on `withdraw`. Keep them out of ALPHA
  exit batches; with `instantWithdraw` they are skipped with an event.
- **Zero-`max*` vaults cannot be sized to liquidity (Morpho Vaults V2).** With `maxWithdraw == 0` the cap is the
  whole position, never the vault's free liquidity, so an exit is all-or-nothing: if the vault cannot deliver the
  requested amount, `withdraw` reverts. The amount the Plasma Vault asks the markets for is larger than the user's
  share: `redeem()` targets the redeemed assets `+2%` and retries up to `REDEEM_ATTEMPTS` (10) times, `withdraw()`
  adds `+10 wei` (or `+0.01%` when shares are being released) in a single attempt, and both add the pending
  withdraw-manager requests (`assetsToRelease`). A redemption near the liquidity edge of such a market therefore
  fails even when the liquidity would cover the user's own amount. Morpho Vaults V2 draws its liquidity from a
  single adapter market, so monitor that market's free liquidity against the position. Put zero-`max*` markets
  after the liquid markets in the instant-withdrawal order; a V2 vault whose gates get enabled later becomes
  non-exitable while NAV still counts the full position (`forceDeallocate` is not supported here).
- **Euler (EVK) vaults as ERC4626 substrates** (including the `EULER_V2` instances of this fuse). EVK vaults report
  `maxWithdraw/maxRedeem == 0` while the owner has a controller (borrow) enabled, when withdrawals are disabled by a
  hook, or when the vault has no cash (verified in the EVK vault module source), although `withdraw` works as long as
  the account stays healthy; `previewRedeem == convertToAssets`. Before IL-8505 the clamp build made such a position
  a silent no-op on exit; now `exit` and `instantWithdraw` withdraw from it, so a user redemption can pull collateral
  from Euler sub-account `0x00` (the Plasma Vault itself) down to the borrow limit. Do not list an EVK vault that
  serves as Euler collateral in an ERC4626 market's instant-withdrawal configuration; use the Euler fuse family,
  which marks collateral as not instant-withdrawable.
- **Redeem-based full exits.** The `redeem(min(balanceOf, maxRedeem))` full-exit path (IL-8489) has the same
  fallback — `maxRedeem == 0` with shares held must use `balanceOf` — or Morpho Vaults V2 full exits become a silent
  no-op again. The invariants to keep in tests are the assets received and the shares left, not which vault
  function was called.
- **Gas and event noise at the fallback.** The fallback runs on every exit visit where `maxWithdraw == 0` while shares
  are held — including the share dust left after a standard full exit (MetaMorpho reports `maxWithdraw == 0` for it)
  and liquidity-capped vaults that are out of cash. Each such visit now costs `balanceOf` + `previewRedeem` on top of
  `maxWithdraw` (measured +135k–204k gas on MetaMorpho vaults with 8–12 markets), an illiquid vault additionally pays a
  reverting `withdraw` and emits `Erc4626SupplyFuseExitFailed`, and `redeem()` repeats the visit up to 10 times.
  Remove fully exited vaults from the instant-withdrawal configuration (or order them last) and treat repeated
  `ExitFailed` events as an operational signal, not an error.
- **Monitoring.** `Erc4626SupplyFuseExitFailed` emitted by the vault; failed redeems following an `ExitFailed`;
  free liquidity of the adapter market behind each Morpho Vaults V2 position; a periodic scan for positions with
  `maxWithdraw == 0` and value > 0; the bytecode fingerprint of every installed instance of this fuse.

## Tests

- `test/fuses/erc4626/ERC4626SupplyFuseTest.t.sol`: `Erc4626SupplyFuseTest` (MetaMorpho vault on an Ethereum fork)
  and `Erc4626SupplyFuseWithFeeTest` (fee vault; `maxWithdraw` cap and partial exits).
- `test/fuses/erc4626/ERC4626SupplyFuseZeroMaxTest.t.sol`: zero-max mock (`maxWithdraw` = 0 while shares are held).
- `test/fuses/erc4626/ERC4626SupplyFuseMorphoVaultsV2BaseTest.t.sol`: Base fork with Morpho Vaults V2; negative
  control through the published fuse.
- `test/fuses/erc4626/ERC4626BalanceFuseTest.t.sol`: balance fuse.
