# UpdateBalancesIgnoreDustPreHook — operations runbook

Operational notes for vaults that wire `UpdateBalancesIgnoreDustPreHook` on user entry points
(`deposit`, `mint`, `withdraw`, `redeem`, ...). The contract NatSpec describes the mechanics; this
file describes what operators must do because of them (IL-8326).

## What the hook refreshes

Before the hooked call, the hook reads each active market's **cached** balance
(`PlasmaVaultLib.getTotalAssetsInMarket`, the value stored by the previous balance update) and calls
`updateMarketsBalances` only for markets whose cached balance is `>= threshold`. Markets in the
balance dependency graph of those markets are refreshed too.

It never reads the live balance of a market it leaves out. Such a "dust" market, and therefore
`totalAssets()`, stays stale until one of these runs:

- `execute` on that market, or on a market whose dependency graph includes it;
- `UpdateMarketsBalancesFuse` (via `execute`);
- an instant withdrawal that pulls from that market (`withdraw` / `redeem` / `redeemFromRequest`);
- an explicit `updateMarketsBalances` call by a holder of `UPDATE_MARKETS_BALANCES_ROLE`.

Compared with `UpdateBalancesPreHook`, which refreshes every active market on every hooked call:

| Situation | UpdateBalancesPreHook | UpdateBalancesIgnoreDustPreHook |
|---|---|---|
| Dust-cached market grows (yield, donation, airdrop, net-equity swing on a leveraged position) | picked up on the next hooked call | NAV understated until one of the refreshes above |
| A large market's balance fuse reads 0 once (paused venue, oracle failure, try/catch-to-0 branch) | back to the real value on the next hooked call | cached 0 is treated as dust and never re-read by the hook: NAV understated until one of the refreshes above |
| Threshold set far above every market (wrong decimals) | n/a | hook refreshes nothing, silently: gains **and losses** are not reflected before entries and exits |

## Nesting

This hook cannot be nested in `ExchangeRateValidatorPreHook`: it needs its own threshold substrate, and a
nested hook never receives one (substrates are stored per registered implementation and selector; only hooks
without their own substrates, such as `UpdateBalancesPreHook`, can be nested). Register it directly on the
selector with `setPreHookImplementations`; a nested instance reverts with `InvalidSubstratesLength` while any
balance-fuse market is active.

## Required operations

1. **Periodic full refresh.** Every vault using this hook needs a periodic `updateMarketsBalances`
   over **all** active markets (not only the non-dust ones), in addition to the hook.
   - The IPOR keeper only serves vaults managed by IPOR alpha (`managed_by_ipor_alpha`,
     `supportUpdateBalances = true`); it picks markets by their live balance, so it covers dust
     growth on those vaults.
   - Curator vaults are **not** covered by the IPOR keeper. Their curator must schedule the full
     refresh (or an `execute` with `UpdateMarketsBalancesFuse` over all markets).
   - After any known incident on a venue or its oracle (pause, failed feed), run a full refresh once
     the venue is healthy again, to clear a transient 0 cached by the hook.

2. **Threshold unit.** The substrate is the threshold in the **underlying asset's decimals**
   (not WAD, not 18 decimals): `1e6` is 1 USDC on a USDC vault, `1e18` is 1 WETH on a WETH vault.
   `1e18` on a 6-decimal asset is 10^12 units and disables the hook.

3. **Readiness check.** When configuring or auditing a vault, convert the threshold to USD
   (`threshold / 10^decimals * assetPriceUsd`) and flag anything above a few dollars. Also flag a
   threshold that is above the vault's largest market balance: the hook then refreshes nothing.

4. **Vaults with a live EulerSwap pool (IL-9331).** Do not let this hook, or any hook, refresh the
   `EULER_V2` market (11) from a user operation on such a vault. The hook refreshes every market whose
   cached balance is `>=` the threshold, plus the dependency graphs of those markets (expanded
   recursively), so market 11 is reachable when its own cache reaches the threshold or when it is in
   the closure of another refreshed market. A cache below the threshold today is no permanent
   protection: the cache grows. This hook cannot be nested in `ExchangeRateValidatorPreHook`: it needs
   its own threshold substrate, and a nested hook never receives one (substrates are stored per
   registered implementation and selector; only hooks without their own substrates, such as
   `UpdateBalancesPreHook`, can be nested). On such a vault market 11 should be refreshed only by the
   keeper or the alpha.
   See the Euler fuses README, section "Live EulerSwap pools and user-triggered refreshes".

5. **Vaults that hold a child Plasma Vault (IL-9743).** On such a vault the hook turns a hooked user
   operation into a read of the child's share price, which can be temporarily wrong while the child runs
   its `execute` batch or an instant withdrawal. The dust filter is no lasting protection: the child's
   market is refreshed once its cache is `>=` the threshold, or when it is in the dependency graph of a
   refreshed market. Known limitation, no code guard (owner decision); see
   [Transient share-price views during `execute` and instant withdrawal (IL-9631, IL-9743)](../../../vaults/README.md#transient-share-price-views-during-execute-and-instant-withdrawal-il-9631-il-9743).

6. **Changing the threshold** is done with `setPreHookImplementations` (same hook address, new
   substrate). Before enabling effective refreshes on a vault created from a PlasmaVault
   implementation that predates IL-8310, note that relayed user calls through ContextManager on
   hooked selectors start to revert once the hook actually calls `updateMarketsBalances` (see the
   ContextManager section of the contract NatSpec).
