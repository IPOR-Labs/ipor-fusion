# Reserve Vault Fuses

## Overview

A reserve vault **C** lends its assets to **member vaults** (**A**, **B**, ...) and takes back exactly the amount it
lent, whatever the member vault's share price is, as long as the member vault holds the funds idle. A loss of a member
vault is absorbed by the member vault's other holders. A gain of a member vault stays with them too: the shares C holds
above its principal are redeemed and the assets go back to the member vault.

| Contract / library             | Runs in                | Purpose                                                                                                                            |
| ------------------------------ | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `ReserveVaultSupplyFuse`       | C, through `C.execute` | `enter` = deposit into a member vault and record the principal; `exit` = take back principal; `getPrincipal`                       |
| `ReserveVaultBalanceFuse`      | C                      | `balanceOf()` = the recorded principal of all member vaults, in USD (WAD), rounded up                                              |
| `ReserveVaultBoostBalanceFuse` | A and B                | `balanceOf()` = the transient boost that reserve vaults hold for this member vault, in USD (WAD), rounded up; `readBoost(address)` |
| `ReserveVaultStorageLib`       | C storage              | Principal ledger in an ERC-7201 namespace (`io.ipor.reserveVault.Principal`)                                                       |
| `ReserveVaultBoostLib`         | C transient storage    | Boost slot per member vault, formula for the boost, USD conversion rounded up                                                      |

The fuses are stateless (immutables `VERSION`, `MARKET_ID`, and `BOOST_MARKET_ID` in the supply fuse) and run by
`delegatecall`.

### Topology

```
  A (member vault)  --- standard ERC4626 fuses --->  C (reserve vault)
  B (member vault)  --- standard ERC4626 fuses --->  C
  C  --- ReserveVaultSupplyFuse (market 61) --->  A, B   (principal recorded in C)
  A, B  --- ReserveVaultBoostBalanceFuse (market 62) --->  reads the boost from C
```

- A and B deposit into C with the standard ERC4626 supply fuse, so they hold C shares. C's share price is the price of
  its own assets: its balance in the underlying asset plus the recorded principal (see
  [ReserveVaultBalanceFuse](#reservevaultbalancefuse)). It does not move with the share price of A or B.
- C deposits into A and B with `ReserveVaultSupplyFuse.enter` and records the deposited amount as principal.
- `exit` takes back at most the principal. When C's shares in A are worth less than the principal, C temporarily
  adds a boost to A's total assets so that A pays the full principal (see [exit](#exit)). The boost lives in C's
  transient storage for the length of one fuse call. It is the normal exit path, not a loss-only path: a boost of at
  least 1 wei is needed on almost every exit without a real gain (see [exit](#exit)).
- The same asset (for example USDC) can count in the TVL of two vaults: A deposits into C, C deposits into A.

## Markets and Substrates

| Market                | `IporFusionMarkets` | Lives in | Substrates                                 | Fuses                                               |
| --------------------- | ------------------- | -------- | ------------------------------------------ | --------------------------------------------------- |
| `RESERVE_VAULT`       | 61                  | C        | member vault addresses (A, B) as `bytes32` | `ReserveVaultSupplyFuse`, `ReserveVaultBalanceFuse` |
| `RESERVE_VAULT_BOOST` | 62                  | A and B  | reserve vault addresses (C) as `bytes32`   | `ReserveVaultBoostBalanceFuse` only                 |

- Market 61 needs both fuses in C. `ReserveVaultSupplyFuse` is constructed with `(61, 62)`: `MARKET_ID` and
  `BOOST_MARKET_ID`. `ReserveVaultBalanceFuse` is constructed with `61`, `ReserveVaultBoostBalanceFuse` with `62`.
- Market 62 has a balance fuse and **no action fuse** (there is no position to enter or exit, only a transient
  valuation). It must have **no dependency graph edge**, in either direction: C books and clears the boost by
  refreshing exactly this market, and that refresh must not revalue other markets of A in the middle of C's exit.
- A vault is usable for market 61 only if it is granted as a substrate:
  `PlasmaVaultConfigLib.isSubstrateAsAssetGranted(61, vault)`.
- Every substrate of market 62 is fully trusted by the member vault, see [Further risks](#further-risks-and-limits).

## ReserveVaultBalanceFuse

`balanceOf()` iterates the substrates of market 61 and values the recorded principal, not C's shares and not the member
vault's share price. A gain or a loss in A therefore does not change the balance, and C's share price stays 1:1 with its
own assets through enter, loss, gain and exit.

- A member vault with zero principal is skipped before any external call.
- Only the principal of member vaults whose `asset()` equals C's underlying asset is summed, and the sum is converted to
  USD **once**, rounded up, at the price from C's oracle. A principal in any other asset is converted separately for
  each member vault, with the same function, also when two member vaults share that asset.
- A member vault with principal whose `asset()` reverts, an asset without a price source, or a zero price makes
  `balanceOf()` revert instead of valuing at zero.
- Called directly on the fuse it reads the fuse's own empty storage and returns 0.

## enter

`enter(ReserveVaultSupplyFuseEnterData{vault, amount})`:

1. `amount == 0` returns with no event (before the substrate check).
2. Reverts `ReserveVaultSupplyFuseUnsupportedVault("enter", vault)` if the vault is not a granted substrate of market 61.
3. Reads C's balance of the member vault's `asset()`, approves `amount`, and calls `IERC4626(vault).deposit(amount, C)`.
4. The principal grows by the **measured** decrease of C's balance, which the allowance caps at `amount`; it is not
   assumed equal to `amount`. Any allowance left is reset to zero.
5. Emits `ReserveVaultSupplyFuseEnter`.

The amount is not clamped to C's balance (the deposit reverts when the balance is too low) and there is no minimum of
shares: the shares do not limit the principal C can take back as long as they are non-zero. A Plasma Vault reverts a
deposit that mints zero shares.

## exit

Notation:

- `P` = principal recorded for the member vault (in its asset);
- `s` = C's shares in the member vault;
- `G` = the member vault's `totalAssets()`;
- `D` = the member vault's `convertToShares(G + 1)`, which is its share supply plus virtual shares.

`exit(ReserveVaultSupplyFuseExitData{vault, amount})`:

1. `amount == 0` returns with no event. The vault must be a granted substrate. `amount > P` reverts with
   `ReserveVaultSupplyFuseAmountExceedsPrincipal` (no clamp, no "max" value). `s == 0` reverts with
   `ReserveVaultSupplyFuseNoShares`.
2. **Liquidity precondition** for `withdraw`: the member vault's idle balance `idle0` must be greater than
   `amount + 10`, otherwise `ReserveVaultSupplyFuseInsufficientIdleLiquidity`. Nothing has changed up to here.
3. **Boost.** The fuse computes
   `X = max(0, ceil(P × D / s) − (G + 1))`.
   `X` is the smallest amount that, added to the member vault's total assets with its supply unchanged, makes **all** `s`
   shares worth the **whole** principal `P`. It is 0 when the whole position already covers the whole principal
   (`floor(s × (G + 1) / D) >= P`). The comparison is whole position against whole principal, also on a partial exit.
   When `X > 0`, the fuse stores `X` in C's transient storage under `ReserveVaultBoostLib.boostSlot(member vault)` and
   calls `updateMarketsBalances([62])` on the member vault. A's boost balance fuse reads `X` back through
   `UniversalReader(C).read` and adds it to A's assets.
4. `withdraw(amount, C, C)` on the member vault. With `X` booked, A's total assets and the share price are higher, so
   exactly `amount` leaves A and the shares burned correspond to the boosted price.
5. When boosted, the fuse clears `X` and refreshes market 62 again. Between steps 3 and 5 there is no `try/catch` and no
   early return: any failure reverts the whole exit, the transient value included.
6. The principal decreases by `amount`.
7. **Surplus.** When the principal is now zero and C still holds member vault shares, the fuse checks the liquidity
   precondition for `redeem`, redeems **all** remaining shares to C, and sends the measured increase of C's balance back
   to the member vault with `safeTransfer`. This runs on **every full exit that leaves shares**, whether the position
   was worth more than the principal, exactly the principal or less: after a boosted exit the rounding of `withdraw`
   typically leaves a few dust shares worth 0 wei, and the step then redeems them and transfers 0 assets. It happens
   only on the exit that brings the principal to zero, after the boost is cleared. The asset must accept a zero-value
   transfer (see [Asset assumptions](#asset-assumptions)).
8. **Post-conditions.**
    - Principal above zero with no shares left reverts with `ReserveVaultSupplyFuseNoShares` (such a position could not
      be recovered by a later boost).
    - The member vault's asset balance after the exit must equal `idle0 − amount`, otherwise
      `ReserveVaultSupplyFuseIdleBalanceMismatch`. The surplus that was redeemed and sent back nets out.
9. Emits `ReserveVaultSupplyFuseExit`.

A boost of at least 1 wei is needed whenever the whole position is worth even 1 wei less than the whole principal.
This is the usual case, not a rare one: C's `deposit` rounds shares down, so right after `enter` at a share price that
is not a round number the position is worth the principal minus 1 wei. A flat exit (no gain, no loss) therefore also
needs a boost of 1 wei, and only a real gain makes `X` zero.

`X` is computed by the fuse; it is not an input and has no cap. A partial exit with a boost burns shares at the boosted
rate; the next exit computes `X` again from the remaining principal and shares, so a partial exit does not leave a
permanent difference.

### Liquidity rule

During C's exit the member vault must **not** pull from its markets. A pull would call C's own market through the member
vault's instant withdraw while C is inside `execute`, and could move funds the exit does not account for.

- **Precondition for `withdraw`.** Idle balance `> amount + 10` wei. This mirrors `PlasmaVault`: without released
  request shares `withdraw(assets)` pulls from markets with `assets + 10` (`WITHDRAW_FROM_MARKETS_OFFSET`), and
  `_withdrawFromMarkets` pulls when that value is greater than or equal to the idle balance.
- **Buffer for the surplus `redeem`.** Idle balance `> value + value × 2 / 100`, with `value = convertToAssets(shares)` of
  the remaining shares. This mirrors `PlasmaVault._redeem`, which asks the markets for the value plus
  `DEFAULT_SLIPPAGE_IN_PERCENTAGE` (2%, floor division). The check runs after the `withdraw`, right before the
  `redeem`; its revert undoes the whole exit.
- **Final check.** The member vault's asset balance after the exit equals `idle0 − amount`. A pull that moved funds
  changes this balance, so it reverts the exit. A pull _attempt_ that brought no funds, for example one that
  reverted and was caught inside the member vault, is **not visible** to this check. The preconditions are read before
  the member vault's own pre-hooks run; a hook that moves the member vault's USDC is caught by the final check only.

The 10 wei and the 2% are copies of `PlasmaVault` constants of this code generation. If `withdraw` or `_redeem` change,
the preconditions stop mirroring them and only the final check remains.

## Configuration checklist

The fuses do not read fees, hooks, the withdraw manager, the dependency graph or the substrates of other markets, and
they do not verify that A booked the boost. The conditions below are assumptions, not checks. The fuses do not police
substrate grants or fees; a wrong configuration shows up as a revert or as a loss for holders, as described.

### Member vaults (A, B)

- **Zero fees:** performance and management, **including the DAO part**, plus withdraw and deposit fees. The DAO part is
  an immutable of `FeeManager`, so the member vault has to be created with a zero DAO fee package.
    - Performance fee: it is charged in `updateMarketsBalances` and in `withdraw` on the boosted price, and a second
      update does not undo it.
    - Management fee: accrued at the start of `withdraw` from a total that includes the boost.
    - Withdraw fee: burns extra shares and lowers the withdraw limit, so a full exit in a loss reverts with
      `ERC4626ExceededMaxWithdraw` and a partial exit burns more than proportionally.
    - Deposit fee: C receives fewer shares than it paid for.
    - Even with zero fees, a boost above the high-water mark moves the mark to the transient price. Reset it before any
      performance fee is switched on.
- **Instant withdraw only.** No withdraw-request flow, no released request shares. The liquidity rule above assumes the
  branch of `withdraw` without request shares.
- C holds the **whitelist role** and `UPDATE_MARKETS_BALANCES_ROLE`, with **no execution delay**. The boost is the normal
  exit path, so **every** member vault needs market 62 and C's update role, not only vaults that are expected to lose
  value. Without the role, every exit that needs a boost reverts with `AccessManagedUnauthorized`; only an exit with a
  real gain, where `X` is zero, still works.
- C is **exempt from the redemption delay** (`setRedemptionDelayExemption`). Without it every deposit of C locks the
  whole position again and an exit in the same block reverts with `AccountIsLocked`.
- Market 62 with the boost balance fuse and C as its only substrate, and **no dependency graph edge**. Without C as a
  substrate, a full exit in a loss reverts with `ERC4626ExceededMaxWithdraw`.
- **No `ExchangeRateValidatorPreHook`** on `withdraw`, `redeem` or `updateMarketsBalances`: it would see the boosted
  price. Pre-hooks run before the function body, so on the refresh of market 62 the hook still sees the boosted or the
  not yet cleared value.
- Refresh the member vault's markets before a reserve exit. `X` and the loss or profit decision are computed from the
  stored balances. If A has a pre-hook that refreshes on `withdraw` and an unbooked loss sits in its markets, the share
  price falls after `X` is computed: a full exit reverts with `ERC4626ExceededMaxWithdraw`, a partial exit burns more
  than proportionally (the next exit recomputes `X` from the remaining principal and shares).

### Reserve vault (C)

- Only member vaults are whitelisted, and they are **exempt from C's redemption delay**.
- Market 61 substrates = the member vaults.
- **A member vault in another asset needs wiring in C.** The balance fuse values the principal held in a non-underlying
  asset, but C's total assets count only its underlying idle balance plus the cached balances of its markets. Grant that
  asset as a substrate of C's ERC20 balance market (`ERC20_VAULT_BALANCE`, market 7) and add a dependency graph edge
  from market 61 to that market. Without them, C's NAV jumps on `enter` and drops on `exit`, or the principal is counted
  twice against a stale market.
- Member vaults are **not substrates of any other market of C** (ERC4626, ERC20, ...). That would count a position twice
  or let it leave through a path that does not touch the principal ledger.
- `ReserveVaultSupplyFuse` is **never on C's instant-withdraw list**. It does not implement `IFuseInstantWithdraw`; an
  entry there makes the instant-withdraw loop revert without data and breaks C's withdrawals. Market 61 is managed only
  by C's Alpha.
- **One reserve action per `execute`.** Two reserve actions in one batch are not supported. After the first reserve
  action C's idle balance has moved, but the stored balance of market 61 stays stale until the end of `execute`. The
  second action runs the next member vault's pre-hooks (for example `UpdateBalancesPreHook`), which price C's shares at
  that stale value, so that member vault caches a wrong value of its C shares. Put each reserve action in its own
  `execute`. See also the
  [refreshing hook limitation](#known-limitation-refreshing-hook-on-redeem), which this rule does not cover.
- **No removal of a substrate that still has principal.** The balance fuse stops valuing it: the market balance drops by
  its principal while the ledger keeps it. Granting the member vault again restores it.

### Chain

The family uses transient storage (`tstore` and `tload`, EIP-1153): a chain with Cancun or later.

### Version assumption

The member vault must run the same `PlasmaVault` code generation as the one the thresholds were taken from:

- the same pull thresholds in `withdraw` and `redeem` (10 wei, 2%);
- the redemption delay exemption (`setRedemptionDelayExemption`);
- Cancun transient storage.

A member vault from another generation can pull from its markets above the preconditions; only the final check protects
the exit then.

Older `PlasmaVault` generations also check market limits (`AssetDistributionProtectionLib.checkLimits`) on every
`updateMarketsBalances`. With limits active, market 62 has a default limit of 0%, so the first boost refresh reverts with
`MarketLimitExceeded` and every boosted exit fails. The current generation skips this check on a refresh. Do not use a
member vault from an older generation unless market 62 is exempt from limits.

### Asset assumptions

- A member vault must be a `PlasmaVault`. A plain ERC4626 vault is a grant error that the fuse does not police.
- The asset transfers exact amounts: no fee-on-transfer token (C's NAV would drop silently, because `exit` lowers the
  principal by `amount` without measuring what C received) and no rebasing or stETH-style token with 1 to 2 wei transfer
  rounding (the final equality check of the exit would revert every exit).
- The asset accepts zero-value transfers, because the surplus step can transfer 0 assets.

## Accepted behaviour

The member vault's other holders carry a shortfall of C and keep a gain of C. The boost is a pricing step inside one
transaction: A's total assets include `X` while C withdraws, then `X` is removed, so the share price of A falls back to
the level that reflects the withdrawal.

| Case                                                               | Before                                   | During the window                                                                                           | After                                                                                                    |
| ------------------------------------------------------------------ | ---------------------------------------- | ----------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Loss: A holds 1 000 USDC, principal 100, C's shares worth 90       | A price 0.900000; other holders 910      | `X` = 111.111111, price 1.000000; C withdraws 100 and burns all its shares                                  | A holds 900 USDC, price 0.890109 (−1.10%); other holders 900, so they covered the 10 USDC shortfall of C |
| Profit: A holds 1 222.22 USDC, principal 100, C's shares worth 110 | A price 1.099999; other holders 1 112.22 | no boost; C withdraws 100, redeems the surplus shares and returns about 10 USDC (9.999999 in the test) to A | A holds 1 122.22 USDC, price 1.109890 (+0.90%); other holders 1 122.22                                   |

- C receives exactly the principal in both cases, so C's share price does not change.
- The price steps are predictable. A holder of A can leave before a loss is realised, or join before a surplus returns.
  Whitelisting and the redemption delay limit this.
- A partial exit in a loss: the principal is paid in parts and the burn is proportional (for example 40 + 60), with
  no dust left after the last part. A partial exit in a profit returns nothing until the principal reaches zero.

## Rounding and the precision domain

The vault converts the USD value of a balance fuse back to the asset with floor divisions. A floor in the fuse would
book one wei less than the amount, so both balance fuses convert **rounded up** with
`ReserveVaultBoostLib.convertToUsdWadRoundUp`:
`ceil(amount × price × 10^18 / 10^(d + pd))`, where `d` = asset decimals and `pd` = price decimals.

- **Boost.** `ReserveVaultBoostBalanceFuse` sums the boosts of all substrates in A's underlying asset and converts the
  sum once, with A's oracle and A's asset decimals (`decimals()` minus `PlasmaVaultLib.DECIMALS_OFFSET`). A floor would
  book `X − 1` and C's withdrawal of the full principal would revert. When every substrate returns 0, the fuse returns 0
  without reading A's asset or price, so a refresh outside an exit window does not depend on the oracle.
- **Principal.** `ReserveVaultBalanceFuse` converts the summed principal held in C's underlying asset once. Regression case: a principal of
  `100 000 001` of a 6-decimal asset at a price of `0.999873211457913207` is booked as `100 000 001`; a floor would give
  `100 000 000` and C would lose 1 wei of NAV with no loss behind it. With a second member vault (`33 333 333`) the sum is
  `133 333 334`.
- **Exactness domain (assets with 18 decimals or fewer).** The conversion is exact, booked == amount, when 1 asset wei is
  worth at least 1 USD-WAD unit: `price × 10^(18 − d) >= 10^pd`. A 6-decimal asset such as USDC is inside the domain at
  any price above `1e-12` USD. The result is never below the amount.
- **Outside the domain** no exact representation exists. The booking can exceed the amount by less than the asset value
  of one USD-WAD unit. Counterexample: 18 decimals, `X = 1` wei at 0.1 USD books 10 wei. For the boost the excess is
  harmless: C withdraws exactly the requested amount. For the principal it raises C's market 61 balance by that excess.
- **More than 18 decimals.** The vault books only multiples of `10^(d − 18)` wei. The amount is first rounded up to that
  step, so the exactness is only to the 18-decimal step.
- **Sums.** Boosts, which are all in A's underlying asset, are added first and converted once. The same holds for the
  principal held in C's underlying asset. A sum of separately rounded-up values can exceed the summed amount near the
  edge of the domain. A principal in another asset is converted per member vault, valued at that asset's price, and the
  vault converts the USD value to the underlying at the underlying's price, so the booked amount is a market value, and
  rounding adds less than one USD-WAD unit per member vault.
- A zero amount returns 0 without checking the price. A non-zero amount with a zero price reverts with
  `ReserveVaultUsdConversionZeroPrice`.

Integration tests use a 6-decimal asset only. Other decimals, and the path above 18 decimals, are covered by unit tests of
the conversion.

## Known limitation: refreshing hook on `redeem`

This is separate from the batch rule above.

Inside **every full exit that leaves shares**, whether at a gain, flat or at a loss (a loss or flat exit leaves dust
shares worth 0 wei, see [exit](#exit)), after `withdraw` and before the surplus `redeem`, C already holds the withdrawn
principal while its stored balance of market 61 is stale until the end of `C.execute`. C's share price is transiently
inflated by `amount`. If the member vault holds C shares and has a pre-hook on `redeem` that refreshes its markets
(for example `UpdateBalancesPreHook`), that `redeem` runs the hook and stores an inflated value of the member vault's position in C. It
stays in A until the next refresh of that market. A separate `execute` for the reserve action does not avoid it, and a
dependency graph edge is not involved. The final balance check does not see it, because only a cache changes.

The fuses do not guard against this. **Operator rule:** refresh the member vault's market that holds C shares after the
reserve action, or use a refreshing hook on every selector of A that is priced at the share rate, not only on `withdraw`.

## Further risks and limits

- **C stays 1:1 even when a member vault cannot repay.** The family has no write-off path. The balance still shows the
  full principal, and depositors who leave C are paid at that price while the shortfall falls on those who stay. C's
  depositors carry the credit risk of the member vaults without seeing it in the share price.
- **A trusts C's fuse set for the size of the boost.** `X` is decided by the code C runs. The boost balance fuse returns
  whatever `C.read` returns, with no cap and no check against C's position in A. A substrate that is not a reserve vault
  running this supply fuse, or whose own configuration is compromised, can set A's balance in market 62, and so A's
  total assets, to any value on a refresh, or block every refresh that includes market 62 by reverting. Granting C on
  market 62 trusts C's atomist, fuse manager and Alpha together, not only A's own Alpha: any fuse that C's fuse manager
  adds and C's Alpha executes can write any value into the boost slot of A (the slot formula is public), refresh market
  62 in A with C's update role and withdraw against C's shares of A at that inflated price, which drains A including its
  instant-withdraw markets. Grant only reserve vaults whose governance is trusted as much as A's own atomist and fuse
  manager.
- **Predictable share-price step at C's exit** (see Accepted behaviour).
- **The same USDC can count in two vaults' TVL.** A deposits into C, C deposits into A. The valuation is not circular:
  A reads C's price, C reads only its own principal ledger. The limit of market 61 in C bounds the loop.
- **A substrate of market 62 whose `read` reverts** blocks every refresh of the member vault that includes market 62,
  so a loss-path exit reverts. A zero price for a non-zero boost reverts too.
- **Substrates with non-zero upper bits.** A substrate stored with non-zero upper bits that truncates to the same
  address could be counted twice by a balance fuse. Fuses do not police grants; grant substrates as clean addresses.
- **A zero-principal substrate is skipped** by `ReserveVaultBalanceFuse` before any external call, so a granted member
  vault that holds no principal cannot make the balance revert.
- **Transient valuation in the window.** In the window the member vault's total assets include `X`. Hooks, balance
  fuses and the oracle of A run there. A needs no third-party code in the window as long as it does not pull from its
  markets; refreshing pre-hooks on A are acceptable.
- **Not a user-triggered path.** C's exit from A is done by C's Alpha. An instant withdraw of C that triggers an exit from
  A is out of scope.

## Events and errors

### `ReserveVaultSupplyFuse`

| Event                                                                                                      | Meaning                                                                                                                                                                                                                          |
| ---------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ReserveVaultSupplyFuseEnter(version, vault, asset, amount, shares, principal)`                            | C deposited into a member vault. `amount` is the measured decrease of C's balance, `shares` the shares received, `principal` the principal after the deposit                                                                     |
| `ReserveVaultSupplyFuseExit(version, vault, asset, amount, sharesBurned, boost, surplusAssets, principal)` | C took back `amount`. `sharesBurned` counts the `withdraw` and the surplus `redeem`, `boost` is `X` (0 when none was needed), `surplusAssets` the assets sent back to the member vault, `principal` the principal after the exit |

| Error                                                                    | Thrown when                                                                                                                                                                    |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ReserveVaultSupplyFuseUnsupportedVault(action, vault)`                  | the vault is not a granted substrate of the market; `action` is `"enter"` or `"exit"`                                                                                          |
| `ReserveVaultSupplyFuseAmountExceedsPrincipal(vault, amount, principal)` | an exit asks for more than the recorded principal                                                                                                                              |
| `ReserveVaultSupplyFuseNoShares(vault, principal)`                       | C holds no member vault shares at the start of an exit, or an exit would leave principal without shares                                                                        |
| `ReserveVaultSupplyFuseInsufficientIdleLiquidity(vault, idle, required)` | the member vault's idle assets are not above the threshold at which it would pull from its markets (`amount + 10` before `withdraw`; `value + 2%` before the surplus `redeem`) |
| `ReserveVaultSupplyFuseIdleBalanceMismatch(vault, expected, actual)`     | the member vault's asset balance after the exit is not its balance before minus `amount`                                                                                       |

### Libraries

| Error                                                                                 | Thrown when                                                                                                                                                  |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ReserveVaultPrincipalUnderflow(vault, amount, principal)` (`ReserveVaultStorageLib`) | a decrease would take the principal below zero; the ledger never clamps. The supply fuse checks the amount earlier, so this is a guard against other callers |
| `ReserveVaultBoostZeroShares()` (`ReserveVaultBoostLib`)                              | the boost is computed for zero shares                                                                                                                        |
| `ReserveVaultUsdConversionZeroPrice()` (`ReserveVaultBoostLib`)                       | a non-zero amount is converted with a zero price                                                                                                             |

Reverts of the member vault or of the oracle propagate unchanged.

## Tests

All tests are in `test/fuses/reserve_vault/`. The integration tests use real clones of `PlasmaVault` for A, B and C with
the real access manager, withdraw manager and fee manager, and a 6-decimal `MockERC20` as the asset. Loss and gain of A are
a real change of A's asset balance. The fuses are called only through `C.execute`, and the boost through the real
`A.updateMarketsBalances`.

| File                                    | What it proves                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ReserveVaultTestBase.sol`              | Shared setup: three vault clones, roles, markets 61 and 62, helpers                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `ReserveVaultLibsTest.t.sol`            | Slot constants equal the ERC-7201 formulas; boost slots differ per member vault; principal ledger never goes below zero; `X` is tight in a loss (with `X − 1` the shares are worth less than the principal) and zero without a loss (fuzz); USD conversion lower bound, upper bound and exactness in the precision domain (6, 8 and 18 decimals, and above 18); the counterexamples (18 decimals books 10, off-grid price books the full amount where a floor loses 1 wei)                                                                                                                                                                                                                                                                |
| `ReserveVaultLossFullExitTest.t.sol`    | Whole chain in a loss: C receives exactly the principal, prices of A as in the table, boost and market 62 are 0 after `execute`, the other member vault is untouched, the member vault sees the boost inside the window                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `ReserveVaultLossPartialExitTest.t.sol` | Partial exits in a loss (40 + 60) sum to the principal with no dust; a partial exit in a profit followed by a loss boosts the remainder; an off-grid oracle price of A still books at least `X`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `ReserveVaultNoSharesGuardTest.t.sol`   | `ReserveVaultSupplyFuseNoShares` at both sites: at the start of an exit when C holds no shares, and as the post-condition of a partial exit that would burn the last share and leave principal; the market ids are pinned                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `ReserveVaultOffGridEntryTest.t.sol`    | Enter at an off-grid share price leaves the position worth the principal minus 1 wei; a flat full exit needs a boost of 1 wei and reverts when C has lost the update role; a boosted full exit at a loss redeems dust shares worth 0 wei and transfers 0 assets; the refreshing `redeem` hook runs on a loss full exit with dust                                                                                                                                                                                                                                                                                                                                                                                                          |
| `ReserveVaultProfitExitTest.t.sol`      | Full exit in a profit: surplus shares redeemed and the assets sent back, A's price rises; the surplus returns only on the exit that brings the principal to zero; exits above the principal revert                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `ReserveVaultEnterAndBalanceTest.t.sol` | Principal adds up over two enters; ledgers are separate per member vault; C's price stays 1:1 through enter, loss, gain and exit; the 100 000 001 regression, with one and with two member vaults; ungranted vault, amount above the principal, vault without principal and zero amount; a granted vault without principal is skipped; a member vault with another asset; A's deposit into C does not touch the ledger                                                                                                                                                                                                                                                                                                                    |
| `ReserveVaultLiquidityGuardTest.t.sol`  | Boundary `amount + 10` reverts and `amount + 11` passes, with and without boost; the 2% buffer of the surplus `redeem`, and its atomic revert; the final check fires when a hook moves A's USDC during `withdraw`, or when A pulls for released request shares; characterisation of the reentrancy lock of C: A is exempt from C's redemption delay, a pull by A inside C's `execute` is kept in C, and a control test shows the same pull succeeds outside `execute`; a pull attempt that brings no funds is not detected                                                                                                                                                                                                                |
| `ReserveVaultBoostWindowTest.t.sol`     | The window: principal and boost are visible inside `withdraw` and gone afterwards; an account without `UPDATE_MARKETS_BALANCES_ROLE` cannot refresh; a C without the role reverts the loss path and still exits with a real gain; a full exit in a loss reverts when market 62 has no substrate C; characterisation of the refreshing `redeem` hook: after a full exit in a profit A stores a stale, inflated value of its C position until the next refresh. The same file has two more contracts: a C that is not exempt from the redemption delay reverts with `AccountIsLocked` in the block of the enter, and a negative control for fees, where a performance fee on A mints fee shares at the boosted rate and a full exit reverts |
| `ReserveVaultInvariantFuzzTest.t.sol`   | Random sequences of deposits, enters, exits, losses and gains on A and B. After every step: withdrawn never exceeds deposited, principal equals deposited minus withdrawn, boost and market 62 are 0, C's total assets equal its balance plus the principal, principal above zero implies shares above zero. Exits refused by the liquidity rule are asserted by selector and counted; the sequences also reach a boosted full exit                                                                                                                                                                                                                                                                                                       |

## Out of scope

- A write-off path for principal that a member vault cannot repay.
- An instant withdraw of C that triggers an exit from a member vault.
- Non-zero fees on member vaults.
- Changes to `PlasmaVault` and its libraries.
- Configuration of live vaults, deployment scripts and registry entries.
- Guards in the fuses for configuration (fees, hooks, graph edges, grants): they are documented here instead.
- Integration tests for assets other than a 6-decimal asset.
