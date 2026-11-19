# RealizeManagementFeeFuse

Lets ALPHA collect the accrued management fee of a PlasmaVault on demand, through `execute`, without a deposit, mint, withdraw or redeem (IL-8870). One deployment per chain serves every PlasmaVault version.

The fuse realizes the fee: it mints the fee shares to the management fee account, moves the fee clock and clears the pending fee. It does not change what the fee is. Read the share price with `convertToAssets(10 ** decimals())`; `totalAssets() / totalSupply()` is gross on most versions. See [the vaults README](../../vaults/README.md#management-fee-in-the-share-price-il-8870) for the versions and how the fee enters the price.

## How it works

`MARKET_ID` is `IporFusionMarkets.ZERO_BALANCE_MARKET`, so the balance refresh that `execute` runs after the fuse values nothing. The fuse is stateless and takes no constructor parameters. `enter()` takes no arguments and returns the fee shares minted; `enterTransient()` writes them as output 0. `exit()` and `exitTransient()` always revert with `RealizeManagementFeeFuseExitNotSupported`.

The fuse runs by delegatecall from `PlasmaVault.execute`. Called directly, or by a vault outside `execute`, it reverts.

### Version detection

The fuse makes one low-level self-call of `realizeManagementFeeInternal()` on the vault:

1. Success: the vault was built with IL-8870 (family A). The vault itself realizes the fee with the same code as a deposit and as the ALPHA method `realizeManagementFee()`. The vault accepts the call only from itself while `execute` runs; any other caller gets `Errors.WrongCaller`.
2. Revert data exactly `CallbackHandlerLib.HandlerNotFound()` (4 bytes): an older version (F0, F1, F2). Its fallback treats the unknown selector as a callback and finds no handler. The fuse then runs the legacy path below.
3. Any other revert data, including empty data, is re-thrown unchanged. An error inside the new entry therefore never switches the fuse to the legacy computation.

### Legacy path (F0, F1, F2)

The fuse follows the order of a deposit-time realization:

1. It reads the management fee account, `totalSupply()` and `getUnrealizedManagementFee()`. If one of them is zero it returns 0 and writes nothing. An empty supply is a deliberate no-op.
2. It moves the fee clock to the current block, then reads `totalAssets()` and `convertToShares(fee)`. If either is zero it restores the clock and writes nothing; the fee stays accrued for a later collection.
3. It mints the fee shares to the fee account through `PLASMA_VAULT_BASE().updateInternal` (the pipeline of the vault's own `_mint`: ERC20 state, votes checkpoints), with the supply cap check disabled for the mint, then clears the pending fee slot when it is non-zero (F2 only).
4. It emits the vault event `ManagementFeeRealized(fee, shares)` from the vault context.

### Result per family

| Family                                | Share price before the fuse                                                      | What the fuse does                                                                                                                | Share price after                                                         |
| ------------------------------------- | -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| A (built with IL-8870)                | Net of the accrued fee (virtual fee shares).                                     | The vault mints exactly the virtual shares.                                                                                       | The same.                                                                 |
| F2 (Release 2026-10)                  | Gross for `convertToAssets`, `convertToShares`, `previewDeposit`, `previewMint`. | Prices the fee on gross assets, as a deposit does.                                                                                | Lower by the fee. Alone in its `execute`, no performance fee (see order). |
| F1 (after #475 and IL-6959)           | Gross.                                                                           | As F2.                                                                                                                            | Lower by the fee. Alone in its `execute`, no performance fee (see order). |
| F0 (built before #475, February 2026) | Net: `totalAssets()` subtracts the accrued fee.                                  | Follows the deposit-time order exactly: the clock moves first, so the conversion is priced on gross assets (Pete, IL-8870 D-007). | The same result as a deposit.                                             |

On F1, F2 and F0 the fee account receives shares worth about `F * G / (G + F)` (`F` the fee, `G` the gross assets), a little less than `F`. More frequent collection approaches the nominal fee. On A the realization is sized by the exact formula and gives the full `F`.

On F0, like any F0 deposit, the realization lifts the unit price by about `(F / G)^2`. At the high-water mark that can charge a dust performance fee in the same `execute`, which an empty `execute` would not. The fuse on F0 gives the same result as a deposit followed by an empty `execute`. The fuse is not promoted for F0, where the price is already net.

## Using the fuse

1. The vault's FUSE_MANAGER adds the fuse with `addFuses` (on some vaults behind a timelock). The fuse works only after this, vault by vault.
2. ALPHA runs `execute([enter()])`, or ALPHA calls `realizeManagementFee()` on a vault built with IL-8870 (the method is not on older versions).
3. Run the fuse as the only action of its own top-level `execute`: nothing before it, nothing after it, never inside a callback batch (IL-8870 D-025, D-026). `execute` reads gross total assets from the stored market balances, which it refreshes only after the last action. With a pending fee, an action before the fuse over-mints fee shares, or drops the fee at zero gross assets. An action after it reprices the pending fee and changes the performance fee. On F1 and F2 a later loss in the batch lets the old net loss guard charge a performance fee. Collecting at a rebalance therefore takes two transactions on F0, F1 and F2; on A, ALPHA may call `realizeManagementFee()` outside `execute` instead. Exception: a vault with a balance fuse dependency graph under `ZERO_BALANCE_MARKET` refreshes those markets even then, so check it before adding the fuse.
4. Collect before the monthly report and from a keeper schedule.

## Requirements

- A balance fuse registered on `ZERO_BALANCE_MARKET`. `FusionFactory` vaults have `ZeroBalanceFuse` there. Without one, `execute` reverts with `MarketWithoutBalanceFuse`.
- A readable price of the vault's underlying asset in the price oracle. After the actions, `execute` refreshes the touched market and reads that price; a missing or zero price reverts the whole `execute`.
- A dependency graph attached to `ZERO_BALANCE_MARKET` makes `execute` refresh the dependent markets too. Check it before adding the fuse.
- The fuse works only inside `execute`. The ALPHA role is needed to run `execute` (or `realizeManagementFee()`).

## Behaviour to know

- On a vault built with IL-8870, a callback handler's `executeInternal` can reach `realizeManagementFeeInternal`: the entry accepts any call from the vault itself while `execute` runs, and `executeInternal` calls come from the vault. Collecting the fee is the only thing the entry does.
- `ExchangeRateValidatorPreHook` reads `convertToAssets` of a full share unit. On A that net rate drifts down continuously between realizations; the realization itself does not move it.
- The ALPHA method `realizeManagementFee()` runs outside `execute`, so the order rule does not apply to it. It prices the fee on the stored, possibly stale, market balances; with a large pending fee, refresh the markets first for an exact collection.
- The fuse does not call the ALPHA method `realizeManagementFee()`: `execute` already holds the reentrancy guard, and a vault self-call is authorized as the vault, which has no ALPHA role.

## Risk for the atomist

The fuse relies on `HandlerNotFound()` to detect an older vault. The atomist must not register a callback handler for the pair (vault, `realizeManagementFeeInternal` selector). On an older vault the fallback would then run that handler instead of answering `HandlerNotFound()`. The legacy fallback runs the registered handler during the execute and then returns empty data whatever the handler did, so the self-call succeeds with empty data and `abi.decode` reverts the whole `execute`. This fails closed: the fuse is unusable on that vault, and nothing is charged. The fuse does not check for this; it is a configuration rule, like the other handler registrations.

## Events

- `RealizeManagementFeeFuseEnter(address version, uint256 feeShares)`: emitted by the fuse only when fee shares were minted. No parameter is `indexed`.
- `ManagementFeeRealized(uint256 unrealizedFeeInUnderlying, uint256 unrealizedFeeInShares)`: emitted by the vault on A, and by the fuse in the vault context (same signature) on the legacy path.

## Errors

- `RealizeManagementFeeFuseExitNotSupported()`: `exit` and `exitTransient`.
- `RealizeManagementFeeFusePlasmaVaultBaseNotSet()`: the legacy path found no `PLASMA_VAULT_BASE()`.
- `MarketWithoutBalanceFuse(marketId)` (from `PlasmaVaultMarketsLib`, surfaced by `execute`): no balance fuse on `ZERO_BALANCE_MARKET`.
