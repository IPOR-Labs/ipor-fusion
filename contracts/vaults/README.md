# PlasmaVault Architecture

## Overview

PlasmaVault uses a **modular delegatecall-based architecture** to achieve:

- **Contract size optimization** - staying under the 24KB limit
- **Separation of concerns** - each component has a single responsibility
- **Extensibility** - optional plugins can be added without modifying core contracts
- **Gas efficiency** - vaults only pay for features they use

## Component Diagram

```
                                    ┌─────────────────────────┐
                                    │      PlasmaVault        │
                                    │    (Main Entry Point)   │
                                    │                         │
                                    │  - ERC4626 core logic   │
                                    │  - Deposit/Withdraw     │
                                    │  - Fuse execution       │
                                    │  - Fallback router      │
                                    └───────────┬─────────────┘
                                                │
                          ┌─────────────────────┼─────────────────────┐
                          │                     │                     │
                          ▼                     ▼                     ▼
               ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
               │ PlasmaVaultBase  │  │PlasmaVaultErc4626│  │    Plugins       │
               │                  │  │      View        │  │                  │
               │ - ERC20 logic    │  │                  │  │ - VotesPlugin    │
               │ - ERC20Permit    │  │ - previewDeposit │  │ - Future plugins │
               │ - Supply cap     │  │ - previewMint    │  │                  │
               │ - Voting units   │  │ - previewRedeem  │  │                  │
               │   propagation    │  │ - maxDeposit     │  │                  │
               │                  │  │ - maxMint, etc.  │  │                  │
               └──────────────────┘  └──────────────────┘  └──────────────────┘
```

## Components

### PlasmaVault (Main Contract)

**Location:** `PlasmaVault.sol`

The main entry point and orchestrator. Contains:

- ERC4626 vault implementation (deposit, mint, withdraw, redeem)
- Fuse action execution system
- Fee management integration
- Fallback router that delegates calls to appropriate components

**Key mechanism - Fallback Router:**

```solidity
// PlasmaVault
fallback(bytes calldata) external returns (bytes memory) {
    if (PlasmaVaultLib.isExecutionStarted()) {
        CallbackHandlerLib.handleCallback(); // callbacks during execute()
        return "";
    }
    // Default: route to PlasmaVaultBase
    return PLASMA_VAULT_BASE().functionDelegateCall(msg.data);
}

// PlasmaVaultBase (reached by the delegatecall above)
fallback(bytes calldata) external returns (bytes memory) {
    // Route the 10 Votes selectors (IVotes, IERC6372, numCheckpoints, checkpoints) to the plugin
    if (msg.sig is one of the 10 Votes selectors) {
        address votesPlugin = PlasmaVaultStorageLib.getPlasmaVaultVotesPlugin();
        if (votesPlugin == address(0)) revert VotesPluginNotEnabled();
        return votesPlugin.functionDelegateCall(msg.data);
    }
    revert(); // unknown selector
}
```

The Votes routing lives in PlasmaVaultBase to keep PlasmaVault under the EIP-170 limit at the deploy setting
(optimizer runs 200). PlasmaVault and PlasmaVaultBase must be deployed and updated together.

### PlasmaVaultBase

**Location:** `PlasmaVaultBase.sol`

Core ERC20 functionality that was extracted to reduce PlasmaVault size:

- ERC20 token operations (transfer, approve, etc.)
- ERC20Permit (gasless approvals)
- Total supply cap enforcement
- Voting units propagation to VotesPlugin during transfers

**Storage:** Uses PlasmaVault's storage via delegatecall context.

### Plugins (Optional Components)

**Location:** `plugins/`

Plugins provide optional functionality that not all vaults need. They:

- Are called via delegatecall from PlasmaVault
- Share storage with PlasmaVault (ERC-7201 namespaced storage)
- Can be enabled/disabled per vault instance

#### PlasmaVaultVotesPlugin

**Location:** `plugins/PlasmaVaultVotesPlugin.sol`

Provides ERC20Votes (governance) functionality:

- Vote delegation (`delegate`, `delegateBySig`)
- Voting power queries (`getVotes`, `getPastVotes`)
- Checkpointing for historical voting power
- IERC5805 / IERC6372 compliance

**Gas optimization:** Vaults without this plugin save ~2,800-9,800 gas per transfer (no checkpoint updates).

## Storage Architecture

All components share storage through **ERC-7201 namespaced storage pattern**:

```
PlasmaVault Storage Layout (shared via delegatecall)
├── ERC20Storage (balances, allowances)
├── ERC4626Storage (underlying asset)
├── VotesStorage (delegatees, checkpoints) - used by VotesPlugin
├── NoncesStorage (permit nonces) - shared by Permit and VotesPlugin
├── EIP712Storage (domain separator)
├── PlasmaVault-specific storage slots
│   ├── PlasmaVaultBase address
│   ├── PlasmaVaultERC4626 address
│   ├── PlasmaVaultVotesPlugin address
│   └── ... other configuration
```

## Initialization

During vault creation, addresses of all components are provided:

```solidity
struct PlasmaVaultInitData {
    // ... other fields
    address plasmaVaultBase; // Required
    address plasmaVaultERC4626; // Optional (address(0) to disable)
    address plasmaVaultVotesPlugin; // Optional (address(0) to disable)
}
```

## Call Flow Examples

### Deposit (PlasmaVault directly)

```
User → PlasmaVault.deposit() → [internal logic] → shares minted
```

### Transfer (routed to PlasmaVaultBase)

```
User → PlasmaVault.transfer()
     → fallback()
     → PlasmaVaultBase.functionDelegateCall()
     → [if VotesPlugin enabled] VotesPlugin.transferVotingUnits()
```

### Preview Deposit (direct in PlasmaVault)

```
User → PlasmaVault.previewDeposit()
     → (handled directly, no fallback routing)
```

### Delegate Votes (routed to VotesPlugin)

```
User → PlasmaVault.delegate()
     → fallback()
     → PlasmaVaultBase.functionDelegateCall()
     → PlasmaVaultBase fallback(): Votes selector = true
     → PlasmaVaultVotesPlugin.functionDelegateCall()
```

## Management fee in the share price (IL-8870)

### Which price you read

The management fee accrues every second, but the vault mints the fee shares only when it realizes the fee. What the share price shows between two realizations depends on the template the vault was cloned from. `totalAssets()` is gross on F1, F2 and A (ERC-4626, ipor-fusion #475), so `totalAssets() / totalSupply()` is a gross price on every version except F0 and must not be used to report a share price. Read the price with `convertToAssets(10 ** decimals())`.

| Family | Templates                                              | `convertToAssets(10 ** decimals())` between realizations                                                                                                                                                             | Who collects the fee, and with what                                                                                                         |
| ------ | ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| F0     | Built before #475 (February 2026)                      | Net: `totalAssets()` subtracts the accrued fee.                                                                                                                                                                      | `RealizeManagementFeeFuse` through `execute`; the result is the same as a deposit-time realization. Not promoted: the price is already net. |
| F1     | After #475 and IL-6959 (March to September 2026)       | Gross: the accrued fee is not in the price.                                                                                                                                                                          | `RealizeManagementFeeFuse` through `execute`.                                                                                               |
| F2     | Release 2026-10 (PR #559, pending management fee slot) | Gross for `convertToAssets`, `convertToShares`, `previewDeposit` and `previewMint`. `maxWithdraw`, `previewRedeem`, `previewWithdraw`, `maxDeposit` and `maxMint` already price the fee (IL-8319, IL-8343, IL-8490). | `RealizeManagementFeeFuse` through `execute`.                                                                                               |
| A      | Templates built with IL-8870                           | Net at every moment, without a transaction: the conversions and all previews and limits count the accrued fee as virtual fee shares. `totalAssets()` stays gross.                                                    | ALPHA calls `realizeManagementFee()`, or ALPHA runs `execute([RealizeManagementFeeFuse])`.                                                  |

On F1 and F2 the price stays gross until the fee is realized. That is the defect IL-8870 addresses for existing vaults: a deposit, mint, withdraw or redeem realizes the fee, and nothing else does. The fuse lets ALPHA do it on demand without moving funds. Clones are immutable, so option A reaches only vaults created from a template built with IL-8870; existing vaults can only use the fuse.

### How the fee enters the price on A

The vault keeps `totalAssets()` gross and adds virtual fee shares `V` to the supply inside every conversion. With `F` the accrued fee (pending fee plus the accrual since the fee clock), `S` the minted supply, `G` the gross total assets and `scale` the share scale multiplier, `V = floor(min(F, G) * (S + scale) / (G - min(F, G) + 1))`. `V` is zero when there is no fee, no supply or no assets. The same function (`PlasmaVaultFeesLib.managementFeeShares`) computes the virtual shares in the views and the shares minted by the realization, so the price before and after a realization is the same and a preview is never better than its result. After a realization the fee account holds shares worth `F`, less the floored fraction of one share and the conversion rounding.

`execute()` and `updateMarketsBalances()` do not realize the fee. The fee stays in the price through the virtual shares until `realizeManagementFee()`, the fuse, or a deposit, mint, withdraw or redeem realizes it.

The performance fee on A is charged on the net price. The rate and the supply passed to the `FeeManager` include the virtual fee shares. Of the fee shares `p` it returns, the vault mints the part that falls on the minted supply, `p * (S + scale) / (S + V + scale)` rounded up, because the virtual shares are priced again after the mint and stay worth `F`. The high-water mark therefore equals the net price after the performance fee mint (the price, rounded down, is never above it and at most the value of two share units below it; see IL-9601 below for the unit), and the price after the call does not depend on whether the management fee was realized in that call. Only the split between the two fee accounts does: after a realization the fee shares are minted supply and take their part of the dilution, so the performance fee account receives all of `p`. The `FeeManager` sizes `p` on the price after its own mint (`p = (S + V) * f / (10000 * rate - f)` with `f = fee * (rate - HWM)`), so the shareholders pay the configured part of their gain above the high-water mark and the price after the mint is the rate less that part; a `FeeManager` deployed before this build prices the shares before their mint and charges `x / (1 + x)` of the vault value instead of `x`. There is no loss gate (IL-9403): `execute`, `updateMarketsBalances`, `withdraw` and `redeem` charge the fee owed at the current net price also in a call that lowered the assets; the high-water mark in the `FeeManager` already prevents a fee without a gain. On F1 and F2 the performance fee is computed from the price on the minted supply, which is gross until the fee is realized.

Every reader of the vault rate sees the net price on A: parent vaults that value the child through `Erc4626BalanceFuse` (`convertToAssets`), ERC4626 price feeds, and `ExchangeRateValidatorPreHook`. A rate that ERC-4626 readers took as stable between realizations now drifts down continuously, so a validator band must tolerate the accrual between two updates.

The conversions read two more storage slots than before (the management fee data and the pending fee), also on a vault without a management fee. The max and preview views compute gross total assets once instead of up to three times.

### Collecting the fee

Collect the fee before each monthly report and from a keeper schedule, so that reports and on-chain state agree:

- On A: ALPHA calls `realizeManagementFee()`, or runs `execute([fuse])`, with the fuse as the only action. Both mint the same shares, move the same clock and clear the same pending fee as a deposit-time realization.
- On F0, F1 and F2: the vault's FUSE_MANAGER adds the fuse with `addFuses` (on some vaults behind a timelock), then ALPHA runs `execute([fuse])`. The fuse must be the only action of its own top-level `execute` (D-025, D-026): market balances inside `execute` are refreshed only after the last action, so an action before the fuse over-mints fee shares or drops the fee, an action after it reprices the pending fee, and on F1 and F2 a later loss lets the old net loss guard charge a performance fee. Collecting at a rebalance takes two transactions on F0, F1 and F2. See [the fuse README](../fuses/management_fee/README.md) for the requirements.
- `realizeManagementFee()` runs outside `execute`, so the order rule does not apply; it prices the fee on the stored, possibly stale, market balances. With a large pending fee, refresh the markets first for an exact collection.

On F0, F1 and F2 the fee shares are sized on gross assets, `convertToShares(F)`, so each collection gives the fee account shares worth about `F * G / (G + F)`, a little less than `F`. The more often the fee is collected, the closer the total comes to the nominal fee. On A the realization is sized by the formula above and gives the full `F`.

## Performance fee rate and high-water mark unit (IL-9601)

Vaults created from a template built with IL-9601 pass the share rate to the `FeeManager` as assets per `10 ** decimals()` shares multiplied by `HIGH_WATER_MARK_SCALE = 1e12`, and the `FeeManager` stores the high-water mark in the same unit. The vault computes the rate with one `mulDiv` of the same terms as the net price, `convertToAssets(10 ** decimals() * 1e12)`, that is `(10 ** decimals() * 1e12) * (G + 1) / (S + V + scale)` with the IL-8870 virtual fee shares `V`, not by multiplying the rounded `convertToAssets(10 ** decimals())`. The price after the fee mint, the owner reset (`updateHighWaterMarkPerformanceFee`) and the lowering after the update interval use the same unit.

Why (Olympix 2026-11-06 M11): with an integer number of asset units per `10 ** decimals()` shares the post-fee mark was floored by up to one asset unit, and that fraction was charged again at the next crossing. On a 6-decimal asset one unit is 1 ppm of the price. With a crystallization every 0.1 ppm of gain (a small redeem after each) a depositor paid 99% of its gain as performance fee instead of 20%. With the scale the floor drops less than 1e-12 of an asset unit per share, and the same run charges 20% of the gain within 10 bps (`test/vaults/PlasmaVaultPerformanceFeeHwmPrecisionTest.t.sol`). On 18-decimal assets the old unit was already fine-grained enough; the scale changes nothing there except the bound below.

What changes for readers of the fee state:

- `FeeManager.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark` and the `HighWaterMarkPerformanceFeeUpdated(highWaterMark)` event are in the new unit. Divide by `HIGH_WATER_MARK_SCALE()` (1e12) for asset units per `10 ** decimals()` shares. A `FeeManager` without `HIGH_WATER_MARK_SCALE()` (the call reverts) is from before IL-9601 and reports asset units per `10 ** decimals()` shares. Off-chain readers (SDK `fee_manager.py`, front end, reports) must branch on that.
- The rate must fit `uint128`. Above that bound the vault skips the performance fee instead of reverting (IL-8307, unchanged), but with the scale the bound is a share price of about `3.4e26 / 10 ** assetDecimals` assets: 3.4e20 on 6 decimals, 3.4e8 on 18 decimals, 340 on 24 decimals. In that range the owner reset reverts with the SafeCast error. An asset with 27 or more decimals cannot be used: `FeeManager.initialize` reverts when the vault is created.
- Deploy the pair together: the PlasmaVault template and the `FeeManagerFactory` configured in the `FusionFactory` must both be built with IL-9601. A new vault with an old `FeeManager` compares a scaled rate with an unscaled mark and charges a fee on almost the whole share price at the first crystallization (with a 20% fee a fifth to a quarter of the supply, depending on the `FeeManager` build); an old vault with a new `FeeManager` starts with a mark 1e12 times above its rate and charges no performance fee until the mark is lowered. Existing vaults keep their pair and their unit.

The vault enforces the pairing once, when it creates its `FeeManager` in `proxyInitialize`: `PlasmaVaultFeesLib.requireFeeManagerScale` reads `HIGH_WATER_MARK_SCALE()` from the `FeeManager` the `FeeManagerFactory` returned and reverts with `FeeManagerScaleMismatch(feeManager)` unless it returns exactly `1e12`. A `FeeManager` without the function (a revert, no return data or an address without code) or with another value fails the same way, so a new vault cannot be created with an old `FeeManagerFactory`. Nothing runs on deposit, withdraw, redeem or transfer. The check also covers IL-9624: every `FeeManager` of this release has both `HIGH_WATER_MARK_SCALE()` and `pendingPerformanceFeeShares`.

## ERC-4626 views: known limitations

### What the views price

`maxWithdraw`, `previewRedeem`, `previewWithdraw`, `maxDeposit` and `maxMint` are priced after the pending management fee. `withdraw`, `redeem`, `deposit` and `mint` realize that fee first, so the views convert against the supply that includes the fee shares (IL-8319, IL-8343, IL-8490). On templates built with IL-8870 (family A, see above) every conversion, preview and limit does this, not only these five views. On templates built with IL-9624, `maxWithdraw`, `previewRedeem` and `previewWithdraw` are also priced after the pending performance fee (see "Performance fee in the exit views (IL-9624)" below). The four max views also return 0 while the vault is closed, and `maxWithdraw` and `maxRedeem` are capped by the released-request reserve (see "Closed vault and released-request reserve in the max views (IL-9624 follow-up)" below).

**Gas cost (IL-8491, rewritten by IL-8870).** On F2 and earlier, each of `maxWithdraw`, `previewRedeem` and `previewWithdraw` computes gross total assets up to three times per call: in `_totalSupplyAfterManagementFee()`, again in the `_convertToShares` of the pending fee, and a third time in the final conversion. Every pass reads the asset `balanceOf` and, when a RewardsClaimManager is set, makes an external `RewardsClaimManager.balanceOf()` call. Measured at optimizer runs = 200 with a RewardsClaimManager, before IL-8319 to the Release 2026-10 code: `maxWithdraw` 8,864 to 18,709 gas, `previewRedeem` 6,430 to 16,275, `withdraw` 158,750 to 168,204. On templates built with IL-8870 `_totalSupplyAfterManagementFee()` is removed: one private helper computes gross total assets once and returns the supply with the virtual fee shares, and every conversion, preview and limit goes through it. The repeated computation is gone. The cost moves elsewhere: the conversions read the management fee data and the pending fee slot, also on vaults without a management fee, and the dispatcher has two more selectors (`realizeManagementFee` and `realizeManagementFeeInternal`), so `withdraw`, `redeem` and transfers change accordingly: after the optimization, `withdraw` is 18,229 gas cheaper, `redeem` 1,677 cheaper and a transfer 22 more expensive (the constants of `RedemptionDelayGasBaselineTest` are re-recorded). PlasmaVault at optimizer runs = 200 with the IPFS metadata hash is 24,157 B, 419 B under EIP-170 (438 B before IL-8870). Keep that headroom for security fixes.

### What the views do not price

These two effects are accepted limitations (IL-8489); the first one is closed on templates built with IL-9624:

- A pending performance fee that `withdraw` and `redeem` crystallize before the limit check. This happens when the share rate is above the high-water mark, for example after vesting rewards, a donation, or the withdraw fee burn of an earlier exit. Priced by the exit views from IL-9624 on.
- A refresh of stale market balances during `withdraw` or `redeem`. Not priced on any template.

On vaults created with the IL-8744 FeeManager the high-water mark is the share price right after the last performance fee, so the price equals the HWM after every fee. Any later accretion (a burned withdraw fee, vesting rewards, a donation) therefore creates a pending performance fee immediately. This is correct HWM behaviour, but it makes the effects above occur more often, including exits from nested child vaults through the old `Erc4626SupplyFuse`, and the performance fee now also applies to withdraw fee income. Deposits and mints do not crystallize the performance fee (IL-8327, IL-8756), so a depositor who enters after such accretion pays a price that includes it and is diluted by the fee charged on it at the next `execute`, `updateMarketsBalances`, `withdraw` or `redeem`. With the post-fee high-water mark this applies from the first wei of accretion, not only after the post-fee gap is recovered. Vaults that run `UpdateBalancesPreHook` on deposit and mint crystallize the fee first, with one exception on vaults that still have the old net-assets check: there `_addPerformanceFee` returns early when the net total assets after the refresh are lower than before it, so a refresh that lowers the assets (a market loss, or an exit cost larger than the gain the refresh reveals) skips the fee although the rate is above the high-water mark. The same skip applies to `withdraw`, `redeem`, `execute` and `updateMarketsBalances` on those vaults. Vaults with the IL-9403 PlasmaVault have no such check: the performance fee is crystallized whenever the share rate is above the high-water mark, also in a call that lowered the net assets, because the high-water mark in FeeManager already prevents a fee without a gain. Live vaults are unaffected: each has its own non-upgradeable FeeManager and keeps its current behaviour.

As a result, `maxWithdraw` and `previewRedeem` can overestimate, and `previewWithdraw` can underestimate, by the caller's share of the refresh delta and, on templates built before IL-9624, of the pending performance fee. `withdraw(maxWithdraw(owner))` can then revert with `ERC4626ExceededMaxWithdraw`. To exit a whole position, use `redeem(balanceOf(owner))`, unless a released-request reserve binds the owner: that `redeem` then reverts with `WithdrawManagerInvalidSharesToRelease` (see "Closed vault and released-request reserve in the max views (IL-9624 follow-up)" below).

These residuals are pinned by:

- `test/vaults/PlasmaVaultPreviewResidualsTest.t.sol` (the refresh residual; the performance fee residual is asserted closed)
- `test/vaults/PlasmaVaultPerformanceFeeFullExitTest.t.sol`
- `test/vaults/PlasmaVaultManagementFeeMaxPreviewTest.t.sol`

### Performance fee in the exit views (IL-9624)

On vaults created from a template built with IL-9624 (the new `PlasmaVault` and `FeeManager` pair), `previewRedeem`, `previewWithdraw` and `maxWithdraw` price the performance fee that `withdraw` and `redeem` crystallize before they pay (Olympix 2026-11-06 M34; option (a) of IL-8489, not taken then). The views model the order of the exit on fresh market balances:

1. The management fee realization mints the virtual fee shares `V` (IL-8870) and leaves the gross assets `G` unchanged.
2. `_addPerformanceFee` converts `10 ** decimals() * 1e12` shares on `S + V` and `G` (the IL-9601 rate) and, with `S + V` minted, mints all `p` shares the `FeeManager` sizes.
3. The exit is priced on `S + V + p` and `G`.

`FeeManager.pendingPerformanceFeeShares(rate, supply, performanceFee)` returns `p` without writing anything: 0 while the high-water mark is not set and when the rate is at or below the mark (also after the update interval, where the crystallization lowers the mark without a fee), otherwise the IL-8870 formula of `calculateAndUpdatePerformanceFee` (repeated in the view, so the crystallization path keeps its gas; a test asserts that both size the same shares). The vault skips the call when the performance fee rate is zero or the share rate is above the `uint128` bound, where `_addPerformanceFee` mints nothing either.

With fresh market balances `previewRedeem` equals `redeem`, `previewWithdraw` equals the shares `withdraw` burns (with a withdraw fee, from the rounding of the fee burn, `redeem` can pay one asset unit more than `previewRedeem` and `withdraw` can burn one share unit less than `previewWithdraw`, both in the holder's favour), and, unless a released-request reserve binds the owner (see "Closed vault and released-request reserve in the max views (IL-9624 follow-up)" below), `withdraw(maxWithdraw(owner))` succeeds and pays `maxWithdraw`, which equals what `redeem(balanceOf(owner))` pays. When the reserve binds, `maxWithdraw` prices the capped shares and equals `previewRedeem(maxRedeem(owner))`; what `redeem(maxRedeem(owner))` pays carries the same one-unit rounding caveat as above. Pinned by `test/vaults/PlasmaVaultPreviewPerformanceFeeTest.t.sol` (6- and 18-decimal assets, fuzzed gain and dormancy) and the residual suites above.

What does not change:

- The stale market refresh residual above stays: the views price the cached balances.
- `previewDeposit`, `previewMint`, `maxDeposit` and `maxMint`: deposits and mints do not crystallize the performance fee (IL-8327, IL-8756), so they stay priced after the management fee only.
- `convertToAssets` and `convertToShares` keep the price between crystallizations (gross of the pending performance fee). A parent that values a child PlasmaVault through `Erc4626BalanceFuse` (`convertToAssets(balanceOf)`) still counts the child's pending performance fee until the child crystallizes it.
- The limit check inside `withdraw` runs after the crystallization of the same call, where nothing is pending, so it does not run the simulation.

Cost and integration:

- Each of the three views (and `maxRedeem` while request shares are released) makes two more external calls when the performance fee rate is not zero (`FeeAccount.FEE_MANAGER()` and `FeeManager.pendingPerformanceFeeShares`) and reads the high-water-mark slot. A parent's `Erc4626SupplyFuse` exit and instant withdrawal call `maxWithdraw` and the previews of the child, so they pay it too; a full exit also reads `maxRedeem`, which runs the valuation with the pending fees only while R > 0 (see "Closed vault and released-request reserve in the max views (IL-9624 follow-up)"), and with R = 0 returns the balance without it.
- The selector of `pendingPerformanceFeeShares` sorts after `calculateAndUpdatePerformanceFee`, so with the linear selector dispatch of the repository profile (optimizer runs 2) the crystallization call of `execute`, `updateMarketsBalances`, `withdraw` and `redeem` does not get more expensive.
- Pairing: a `PlasmaVault` built with IL-9624 calls `pendingPerformanceFeeShares` in the three views, and in `maxRedeem` while request shares are released, which revert on a `FeeManager` built before it. Deploy the pair together, as for IL-9601 and IL-9632. Existing vaults keep their pair and the IL-8489 behaviour.
- Off-chain estimates of exits (SDK, front end, keepers) that read `previewRedeem`, `previewWithdraw` or `maxWithdraw` get net values on new vaults; estimates computed from `convertToAssets` still have to subtract the pending performance fee.

### Redemption lock in the exit views (IL-9679)

On vaults created from a template built with IL-9679, `maxWithdraw(owner)` and `maxRedeem(owner)` return 0 while the owner's redemption lock is active, because `withdraw` and `redeem` revert then (Olympix 2026-11-06 L48; ERC-4626 requires 0 when the exit is disabled for the owner). Before IL-9679 they returned the position and the call reverted with `AccountIsLocked` (owner decision IL-8639, reports IL-8798 and IL-9449). `maxRedeem` is now overridden in `PlasmaVault`; before it was the inherited `balanceOf(owner)`.

The views read the lock the way `RedemptionDelayLib.lockChecks` enforces it on the exits:

- Locked while `getAccountLockTime(owner) > block.timestamp` on the vault's access manager: the time of the owner's last deposit or mint (also one made by a third party to the owner) plus the current redemption delay. A change of the delay moves the views at once, in both directions, as it moves the exits. From the unlock second on the views are open.
- An owner exempt from the redemption delay (`isRedemptionDelayExempt`, IL-7935; on factory vaults the fee manager and both fee accounts, IL-9634) is never zeroed.
- With a delay of 1 second, the setting of most live vaults, the views read 0 only in the block of the owner's deposit; with a delay of 0, never.

Outside the lock `maxRedeem` is the balance, 0 while the vault is closed and capped by the released-request reserve, and `maxWithdraw` keeps the IL-9624 pricing with the same closed-vault zero and reserve cap (see "Closed vault and released-request reserve in the max views (IL-9624 follow-up)" below).

What does not change:

- `withdraw` and `redeem` during the lock still revert with `AccountIsLocked(unlockTime)` from `_checkCanCall`, before their limit check. The limits inside the calls do not read the lock again (`redeem` caps by the balance, `withdraw` by the IL-9624 in-call limit), so the exits pay no extra access-manager read.
- `redeemFromRequest` stays lock-free (IL-8736, IL-9531). Its cap is `balanceOf(owner)`, not `maxRedeem`: a holder that a third party relocks with a dust deposit reads 0 in both views and still leaves through a released request, and so do dispatchers and parent vaults that exit with owner = `address(this)`.
- The views know the owner only, and so does the exit: `_checkCanCall` reads the redemption lock of the account whose shares leave (the `owner` of `withdraw` and `redeem`, the `from` of `transferFrom`), and the caller passes only the role check, as in `deposit` (IL-9705, owner decision). A third party can no longer lock an operator out of moving another account's shares by depositing dust to the operator, and an exempt operator still cannot move the shares of a locked owner. Before IL-9705 the lock of the caller was checked too; vaults on that implementation keep the two-party check, and there the operator can be exempted with `setRedemptionDelayExemption` where the access manager has it. `transfer` is unchanged. The views match the exit check exactly. Roles and pre-hooks are not reflected; a closed vault is (IL-9680 and the next section below).
- The lock still starts on the receiver of a deposit or mint (IL-8736). The fee account (`from`) that receives dust is still locked by design; `harvestManagementFee` no longer fails on a vault without the IL-9634 exemption after dust is deposited to the FeeManager address.

Integration notes:

- 0 does not mean "no position". Anyone can make both views of a non-exempt holder read 0 for up to the redemption delay by depositing to it (IL-8736). Read `balanceOf` for the position and `getAccountLockTime` / `isRedemptionDelayExempt` on the access manager for the unlock time.
- **Exempt dispatchers and parent vaults from the redemption delay (IL-9695).** The lock sits on the receiver of the shares and every deposit or mint restarts it (IL-8736, by design; the alternative of locking the depositor would let one address mint to a fresh address and exit in the same block). A crosschain dispatcher or a parent vault holding a position in this vault is such a receiver: each top-up locks its whole position for the delay, and anyone can restart the lock by depositing to it. The owner of a vault that is used as a remote or child vault should exempt the dispatcher or the parent vault (`PlasmaVaultGovernance.setRedemptionDelayExemption`, OWNER_ROLE, IL-7935), otherwise the holder exits through `requestShares` and `redeemFromRequest`, which a later deposit cannot lock again (a request filed during the lock starts when that lock ends, IL-9531). The exemption also removes the same-block deposit-and-exit guard for that address, so exempt only a trusted contract.
- A parent vault's `Erc4626SupplyFuse` sizes a full exit from `previewRedeem(balanceOf)` when the child's `maxWithdraw` is 0 (IL-8505), so during the parent's own lock on the child the `redeem` reverts with `AccountIsLocked`, as the `withdraw` did before: `exit` reverts and `instantWithdraw` emits `Erc4626SupplyFuseExitFailed`.
- The crosschain vault-removal sweep redeems `min(balanceOf, maxRedeem)`. During the dispatcher's lock on the removed vault it makes no `redeem` call and reports the shares as a residual: reason 3 without a sweep floor (the vault is untracked), reason 6 with a floor (the vault stays tracked), where a vault built before IL-9679 reported a reverted `redeem` (reason 2, untracked).
- `WrappedPlasmaVault` (deprecated) prices its total assets from `maxWithdraw(wrapper)` on the PlasmaVault. On a PlasmaVault built with IL-9679 that is 0 during the wrapper's own lock, which every wrapper deposit restarts, so a second deposit within the redemption delay would be priced on zero assets. Do not wrap such a vault unless the wrapper is exempt from its redemption delay or the delay is 0.

Pinned by `test/vaults/PlasmaVaultMaxViewsRedemptionLockTest.t.sol` (one-day and one-second delay, the unlock second, delay changes, fuzzed delay and elapsed time against `redeem`, exempt owners and fee accounts, a third party relock, `redeemFromRequest` while the views read 0, the spender's lock not read in the views) and by `test/vaults/PlasmaVaultCallerRedemptionLockTest.t.sol` (the caller's lock is not read by `withdraw`, `redeem` and `transferFrom`; the owner's lock is).

### Access gates in the max views (IL-9680)

The max views do not reflect role gates and pre-hooks (Olympix 2026-11-06 L49; owner decision IL-8639, kept by D-054). A closed vault is reflected since the IL-9624 follow-up (next section). `maxDeposit` and `maxMint` price the total supply cap and, since that follow-up, the closed flag (0 while the vault is closed), and return the same value for every receiver; `maxWithdraw` and `maxRedeem` price the owner's position, from IL-9679 on the owner's redemption lock, and from the follow-up the closed flag and, while released request shares R > 0, the reserve cap `min(balanceOf(owner), max(C - R, 0))` (next section). They stay positive while the call itself reverts:

- for a receiver or an owner without the role of a private vault (`WHITELIST_ROLE` on `deposit`, `mint` and `depositWithPermit`, or any role an ATOMIST maps to the exits): `AccessManagedUnauthorized(caller)`;
- while a pre-hook blocks the selector (a pause, the crosschain NAV gate, an exchange-rate validator): the pre-hook's error.

Why not gate them: access is checked for the caller in `_checkCanCall`, while `maxDeposit(receiver)` and `maxMint(receiver)` get the receiver and `maxWithdraw(owner)` and `maxRedeem(owner)` the owner. A whitelisted caller may deposit for a receiver without a role, and a caller with the exit role may redeem for an owner without it (with an allowance), so a view gated on the receiver or the owner would report false zeros, and a pre-hook decides only when it runs, so a view cannot read it. The supply cap and a closed vault are the only entry limits that do not depend on the caller: at the cap and while the vault is closed both deposit views return 0.

For integrators: probe access with `IporFusionAccessManager.canCall(caller, vault, selector)` (returns false on a closed vault too) and `isTargetClosed(vault)`, the crosschain NAV gate with `CrosschainNavValidationPreHook.isNavHealthy(vault)` (it covers the vault's OWN CROSSCHAIN executors only: a vault that holds shares of a CROSSCHAIN vault and watches it through the hook's pre-hook substrates, IL-9720, can answer true while its own `run` reverts, so probe the watched vaults as well), and the redemption lock with `getAccountLockTime` / `isRedemptionDelayExempt`.

Pinned by `test/vaults/PlasmaVaultMaxViewsIgnoreAccessGatesTest.t.sol` (private vault: a receiver without the role, a whitelisted caller depositing for it, an owner without the exit role and a caller with it redeeming for that owner, a closed vault (0 since the IL-9624 follow-up), a blocking pre-hook, the supply cap).

### Closed vault and released-request reserve in the max views (IL-9624 follow-up)

Scope: this applies only to vaults created from a template built with this change. Existing clones stay on the code they were created with, and rolling the template back does not change clones already created.

- **Closed vault.** `maxDeposit`, `maxMint`, `maxWithdraw` and `maxRedeem` return 0 while `isTargetClosed(vault)` is true on the vault's access manager (`updateTargetClosed`, GUARDIAN). The access manager checks the closed flag before the role, so it rejects every `restricted` call of the vault (among them `deposit`, `mint`, `depositWithPermit`, `withdraw`, `redeem` and `redeemFromRequest`) for every caller; getters and views keep working. Unlike the role gates above, a closed vault does not depend on the caller, so the zero is never a false zero. Reopening restores the views at once. Roles and pre-hooks are still not reflected (IL-9680, IL-8639).
- **Released-request reserve.** R is `WithdrawManager.getSharesToRelease()`, the global pool of shares that ALPHA released for payout from requests; it is neither the owner's request nor the sum of pending requests. With R > 0, `withdraw` and `redeem` revert with `WithdrawManagerInvalidSharesToRelease` when the idle assets of the vault, in shares, are below R plus the gross shares of the exit (`WithdrawManager.canWithdrawFromUnallocated`). With R > 0, `maxRedeem` returns `min(balanceOf(owner), max(C - R, 0))`, and `maxWithdraw` prices the same capped gross shares less the withdraw fee. C is all gross assets of the vault converted to shares on the supply after both pending fees, `floor(G * (S* + 100) / (G + 1))` (100 is `10 ** _decimalsOffset()`, the fixed virtual-share offset of the vault): G is `totalAssets()` and S* is `totalSupply()` plus the shares of the pending management fee and of the pending performance fee that the exit mints before it pays. This is the supply the check sees after the fee crystallization in the exit. It is neither `totalSupply() - R` nor the public `convertToShares(totalAssets())`, which leaves out the pending performance fee. With R = 0 the views are unchanged and `maxRedeem` is the balance with no valuation.
- **Upper bound, not a guarantee.** The cap counts all gross assets as available. It does not reflect the liquidity of the markets, the balance of the RewardsClaimManager (it is in `totalAssets()`, but the exit does not pull it and the check reads only the token balance on the vault) or a refresh of stale market balances in the exit (IL-8489). A positive result can still be rejected by the exit.
- **Who is bound.** The cap binds only an owner whose balance exceeds `max(C - R, 0)`: typically a requester exiting at once next to its own released request, or a holder after ALPHA released more shares than the other holders own. Such an owner leaves through `redeemFromRequest` (the released part) and `redeem(maxRedeem(owner))`; `redeem(balanceOf(owner))` reverts with `WithdrawManagerInvalidSharesToRelease`. A holder below the cap sees the balance.
- **Exit order: request first.** A holder bound by the reserve calls `redeemFromRequest` BEFORE `redeem`. The request cap is the balance since the request (`PlasmaVaultBase` `_update`, `getRequestCap`), an ordinary `redeem` burns shares and lowers that cap to the remaining balance, and only `redeemFromRequest` lowers R (`WithdrawManager.canWithdrawFromRequest`). After an instant-first exit the holder can redeem only `balance` of the request, so the rest of the request and an equal part of R stay with no shares behind them: R is reserved for nobody and keeps binding the other holders until ALPHA releases again with a lower R. The exact residual depends on offsets and fees, so do not read it as R = the shares burned instantly. The parent's `Erc4626SupplyFuse` full exit and the crosschain sweep redeem `min(balanceOf, maxRedeem)` through the ordinary `redeem`, so they take the instant path automatically: an owner of such a position that also holds a released request should redeem the request first, then call them. Pinned by `testShouldLeaveReserveUnclaimable_whenInstantRedeemRunsBeforeRedeemFromRequest` and `testShouldExitWholePosition_whenRedeemFromRequestRunsBeforeRedeemMaxRedeem`.
- **Identity of the views.** `maxWithdraw(owner) == previewRedeem(maxRedeem(owner))`, also while the cap binds. What `redeem(maxRedeem(owner))` pays is not equal to it in every case: `previewRedeem` computes `floor(shares * (1 - fee))`, while `redeem` burns `floor(shares * fee)` as the fee, so with a withdraw fee the payout can be one asset unit higher, in the holder's favour (the caveat in "Performance fee in the exit views (IL-9624)"). The cap does not have to fall on a share count divisible by the fee.
- **Zero is not "no position".** Read the position from `balanceOf`, the closure from `isTargetClosed` and the reserve from `getSharesToRelease`.

What does not change: `withdraw`, `redeem` and `redeemFromRequest` get no new check and no new external call. The reserve is enforced by the `WithdrawManager` as before; the limit inside `withdraw` gives the same result as before, and `redeem` and `redeemFromRequest` still cap the shares by the balance. `convertToAssets`, `convertToShares` and the previews are not changed.

Cost and dependencies:

- `deposit`, `depositWithPermit` and `mint` read `maxDeposit` / `maxMint` inside the call through the OpenZeppelin ERC-4626 implementation, so each pays one more access manager read for the closed flag. The exit views read in this order: the closed flag (always), the owner's redemption lock (only when the vault is open), then `getSharesToRelease` (only on a path that passed both, but then also when R = 0). `maxWithdraw` then makes one valuation with the pending fees, as before the change; `maxRedeem` makes one only when R > 0. A closed vault or a locked owner returns 0 with no reserve read and no valuation. The measured gas figures are in the release note.
- With R > 0, `maxRedeem` depends on the asset valuation and on the `FeeManager` of the same release (`pendingPerformanceFeeShares`), the same pairing that "Performance fee in the exit views (IL-9624)" requires, and like `maxWithdraw` it can read a transient value inside `execute` and an instant withdrawal (IL-9743). A reader with a gas limit has to allow for this: the crosschain vault-removal sweep reads `maxRedeem` with 200,000 gas and treats a read that fails or runs out of gas as no limit.

Consumers that read the views:

- `Erc4626SupplyFuse` of a parent vault: against a child capped by the reserve, a full exit redeems `min(balanceOf, maxRedeem)`, that is the part, instead of reverting. In `instantWithdraw` that is an improvement; in an ALPHA batch it is a silent partial exit, so ALPHA sets `minAssetsOut`. Against a closed child or a cap of 0 the fuse falls back to the balance (the IL-8505 rule) and the `redeem` reverts: `exit` reverts and `instantWithdraw` emits `Erc4626SupplyFuseExitFailed`.
- The crosschain vault-removal sweep redeems `min(balanceOf, maxRedeem)`. A closed vault: `redeem` is not called; reason 3 without a sweep floor (the vault is untracked; earlier reason 2 or 5), reason 6 with a floor (the vault stays tracked, but no `redeem` is made). A position capped by the reserve: a part is redeemed; without a floor, or with a floor not higher than the payout, reason 3 and the vault is untracked with the rest of the shares left on the dispatcher; with a floor higher than the payout the redemption is reverted and the reason is 6. For a PlasmaVault this is new: before, the `redeem` of the balance reverted. It requires the `maxRedeem` read to succeed within 200,000 gas. Two cases differ: when the outer gas cannot fund that read at all, the sweep reverts with `InsufficientGasForVaultRead` (no fallback); when the capped read itself fails or runs out of its gas (a `FeeManager` from another release, a valuation that costs more), the sweep takes the whole balance and a position capped by the reserve gets the old result: `redeem` reverts, reason 2 or 5 without a floor, reason 6 with a floor. The sweep code is unchanged.
- `WrappedPlasmaVault` (deprecated) prices its total assets from `maxWithdraw(wrapper)`: with a closed source its NAV reads 0, and a public `realizeFees` call during the closure zeroes the wrapper's accrued management fee; with a binding reserve its NAV is understated; the wrapper's performance fee benchmark is not reset. Do not create new wrappers on the new template; existing wrappers point to old clones and nothing changes for them.

Pinned by `test/vaults/PlasmaVaultMaxViewsIgnoreAccessGatesTest.t.sol` (closed vault returns 0, roles and pre-hooks unchanged), `test/factory/FusionFactoryMaxViewsClosedVaultTest.t.sol` (closure and reopening on a factory clone with pending fees), `test/vaults/PlasmaVaultMaxViewsReleasedReserveTest.t.sol` (the reserve, edge cases, fuzz), `test/vaults/PlasmaVaultMaxViewsReleasedReserveFeesTest.t.sol` (the reserve with pending management and performance fees, 6- and 18-decimal assets, withdraw fee 0 and 1 %, rounding boundaries on both sides), `test/fuses/erc4626/Erc4626SupplyFusePlasmaVaultChildMaxViewsTest.t.sol` (a parent's fuse against a real child), `test/crosschain/VaultRemovalSweepPlasmaVaultMaxViewsTest.t.sol` (the sweep with and without a floor, including a failed `maxRedeem` read) and `test/vaults/PlasmaVaultMaxViewsCostTest.t.sol` (call counts of the valuation and of the closed-flag read).

### Legacy clones (IL-8492)

Deployed PlasmaVaults are EIP-1167 clones created by FusionFactory and stay on the implementation they were created with. The view fixes above do not reach them, nor will any future fix. Implementations from before the IL-8319/IL-8343 fix do not price the pending management fee in these views either.

A parent vault that fully exits a nested PlasmaVault child through the old `Erc4626SupplyFuse` clamps the amount to the child's `maxWithdraw` and calls `withdraw`. If the child has a pending fee, that exit can revert in `execute`. In `instantWithdraw` the fuse catches the error, skips the exit and emits `Erc4626SupplyFuseExitFailed`. A child built with IL-9624 prices its pending performance fee in `maxWithdraw`, so that fee no longer makes the exit revert; a stale market balance that the child's exit refreshes still can.

The `Erc4626SupplyFuse` from IL-8489 handles this: an exit amount greater than or equal to the child's `maxWithdraw` redeems `min(balanceOf, maxRedeem)` shares. That also works against legacy children, but only for parents that use the new fuse deployment.

### Runbook: full exit from a nested PlasmaVault child

Until the parent uses the IL-8489 `Erc4626SupplyFuse` deployment, exit fully in one of these ways:

1. Call `redeem(balanceOf)` on the child directly, where the integration allows it.
2. Put a small `withdraw` earlier in the same `execute`. It realizes the child's pending management and performance fees, so the later `maxWithdraw` no longer includes them. This is not exact when the child charges a withdraw fee (burning the fee shares lifts the rate above the high-water mark again) or when the exit refreshes a stale market balance.
3. Request slightly less than `maxWithdraw`.

After the new fuse is deployed and wired on the parent (`addFuses` and the instant withdrawal configuration), an exit amount greater than or equal to `maxWithdraw` redeems the whole redeemable balance, also for legacy children.

Before a child PlasmaVault enables a management or performance fee, re-run the nested-vault scan and check that full exits of its parents still succeed. The scan script is attached to Jira IL-8492 and needs the keeper DB and an RPC.

### Transient share-price views during `execute` and instant withdrawal (IL-9631, IL-9743)

A PlasmaVault's share-price views can be wrong in two windows. In `execute` the window starts at the first fuse that moves underlying between the idle balance and a market (or into tokens in flight) and ends at the final refresh of the market balances; a callback (`executeInternal`) or `UpdateMarketsBalancesFuse` can refresh some markets earlier. In `withdraw`, `redeem` and `redeemFromRequest` it runs from the first instant withdrawal fuse that pays into the idle balance until the touched markets are refreshed after the loop. The views (`totalAssets()`, `convertToAssets()`, `convertToShares()`, the `preview*` functions, `maxDeposit`, `maxMint`, `maxWithdraw`, and `maxRedeem` while request shares are released) read the live idle balance plus the cached market totals. They have no reentrancy check, no execution check and no execution-state indicator, so a reader of the views alone cannot tell that a window is open.

**Direction.** The wording is that of gross assets and assets per share; conversions that return shares move the other way (fixed nonzero supply, no fees). In `execute` they read too low while underlying has left the idle balance unbooked (supply, a swap away, a repayment, tokens at a swap executor) and too high while it has entered unbooked (a market exit, a borrow, a swap in, a flash loan). In an instant withdrawal they read only too high: idle grows after each fuse while the cache still holds the position. A redemption delay on a parent only defers the gain from a deposit at a too low rate.

**What the vault's accounting relies on.** `deposit`, `depositWithPermit`, `mint`, `withdraw`, `redeem`, `redeemFromRequest` and `execute` (also `claimRewards` and the fee realizations) share one `nonReentrant` lock and price after the refresh. `updateMarketsBalances`, `transfer` and `transferFrom` are outside it, and the lock does not stop another contract from reading the views. `transfer` and `transferFrom` run their configured pre-hook, so a balance-refreshing hook on them lets a refresh, with its fee crystallisation, happen inside the vault's own batch on a transient value; when condition C below holds for the vault, do not wire one there.

**Who can run code inside the window.** Foreign code must run inside the child's batch or exit. Granting a router to the universal token swapper family (tokens and targets are validated separately), Odos or Velora does not constrain or approve the pools, hooks and intermediate tokens of a route. Other mechanisms: a pool hook, a token with a transfer hook, a withdrawal target (also on the instant withdrawal list) that calls third-party code.

**How a parent reads the child.** `Erc4626BalanceFuse.balanceOf()` values the position as `convertToAssets(balanceOf(parent))` of every substrate of its market. The result is cached until that market is refreshed again. A later correct refresh restores the cache but does not undo what was booked on the transient value: a priced user operation, performance fee shares minted later, a moved high-water mark. In a call by a user of the parent the market of the child is refreshed by:

- a refreshing pre-hook on the selector: `UpdateBalancesPreHook` (also nested in `ExchangeRateValidatorPreHook`), `UpdateBalancesIgnoreDustPreHook` (markets whose cache is at least the threshold), `UpdateBalancesExcludeMarketsPreHook` and `HyperCoreCapitalFlowFullRefreshPreHook` (every active market not on their exclusion list; nested in the validator they exclude nothing), and `HyperCoreCapitalFlowPreHook` (market 55 and its dependencies);
- the dependency graph, which is expanded recursively: an edge to the child's market from any refreshed market refreshes it too;
- the oracle path: `Erc20BalanceFuse` values held child shares through the price oracle middleware, which reaches the live `convertToAssets` when `ERC4626PriceFeed` prices them;
- an instant withdrawal of the parent. A `withdraw`, `redeem` or `redeemFromRequest` that needs more than the parent's idle balance can refresh the market that values the child even when the child pays nothing: the loop runs a supported, correctly configured entry of that market (any substrate) and the entry returns normally. `Erc4626SupplyFuse` returns normally when the child's `withdraw` and `redeem` fail, as they do on the child's lock inside its own batch or exit while its views still answer. A skipped entry (unsupported fuse, a revert with error data) adds no market; the refreshed value persists only if the whole operation succeeds.

**Bound.** Let M be the underlying moved in the window and not yet booked, A the child's gross assets (`totalAssets()`) and P the value of the parent's position in the child. The child's `totalAssets()` is off by about M, and the parent reads its position off by about P × M ÷ A. This ignores virtual assets and shares, the fee-corrected supply and rounding. The other holders of the parent bear the difference.

**Rule for atomists.** The combination of two conditions is dangerous.

_Condition P (parent): the child's market can be refreshed by an operation that an account other than the keeper and the alpha can call._ How to check on the parent:

1. Find the market that values the child: `getActiveMarketsInBalanceFuses()` or `BalanceFusesReader.getBalanceFuseInfo(vault)`, then `getMarketSubstrates(marketId)`. The whole market counts.
2. Check the direct refresh, independently of any hook: read `getTargetFunctionRole(vault, selector)` for the `updateMarketsBalances` selector. It takes caller-selected markets and is outside the lock, so a parent without any hook can still expose a user-reachable refresh. Closing P requires trusted direct-refresh permissions: only trusted operators hold that role, and the vault's own self-call authorisation (used by hooks) stays.
3. Collect the refresh seeds of the hooks. For each selector in `getPreHookSelectors()` read `getTargetFunctionRole(vault, selector)`: a selector on `PUBLIC_ROLE` can be called by anyone. `canCall` answers for one account only. A non-public role has no on-chain member list: rebuild candidate holders from the access manager's `RoleGranted` and `RoleRevoked` events and confirm each with `hasRole`; if exclusivity of trusted operators cannot be established, treat P as holding (also for step 2). Read the hook with `getPreHookImplementation(selector)` and its substrates with `PreHooksInfoReader.getPreHooksInfo(vault)`; for `UpdateBalancesIgnoreDustPreHook` compare `totalAssetsInMarket(marketId)` with the threshold. The dust decision holds only for the balance read now; reassess after changes of roles, hooks, threshold, graph, instant withdrawal list or positions. Hooks nested in `ExchangeRateValidatorPreHook` are not substrates of the outer hook: read `MARKET_ID()` on the validator implementation, then `getMarketSubstrates(marketId)` on the vault (types `PREHOOKS` and `POSTHOOKS`). The seeds also include the market of every entry in `getInstantWithdrawalFuses()` (`MARKET_ID()` on the fuse). An entry matches by market, not by target: an entry aimed at another vault of the same market refreshes the child's market too.
4. Expand `getDependencyBalanceGraph(marketId)` recursively from every seed, and check the oracle path above. Condition P holds when the child's market is among the seeds or in their graphs. An unidentified hook implementation counts as holding P.

_Condition C (child): code that the child's trusted roles did not choose can run in its `execute` batch or instant withdrawal._ How to check on the child: `getFuses()`, `getMarketSubstrates(marketId)` and `getInstantWithdrawalFuses()`. C holds when (1) the child has a swap fuse whose target accepts any route (an aggregator or router) and routes are not pinned to reviewed pools and tokens; (2) a substrate is a pool with a hook, a token with a transfer hook, or a vault that calls third-party code on deposit or withdrawal; or (3) such a target is on the instant withdrawal list. What counts is whether a concrete route or target can run untrusted code; routes are not visible on-chain, so the atomist of the parent relies on the process of the child's alpha.

**What to do instead.**

1. Hold as children only vaults that do not satisfy condition C, and re-check after every change of the child's fuses, substrates and instant withdrawal list; the child can have another atomist.
2. When the child satisfies C, close condition P on the parent. A selector has one hook, and setting another replaces it and deletes the substrates of the old one, so go selector by selector: replace a plain refresher with `UpdateBalancesExcludeMarketsPreHook`, with the child's market on its exclusion list. Where `ExchangeRateValidatorPreHook` hosts refreshing nested hooks, remove the nested hooks and keep the validator with its validation configuration; do not nest an exclusion hook, it would exclude nothing. Keep non-refreshing controls (a pause hook, the crosschain NAV gate) and leave unhooked selectors unhooked. On a vault with a HyperCore market, use the exclusions of `HyperCoreCapitalFlowFullRefreshPreHook` consistently on the six share-priced selectors. Removing a nested refresher also stops its refreshes of the other markets. Leave no dependency edge to the child's market from a market that a user refreshes and no instant withdrawal entry of it, and close the direct refresh. The setter guard protects only the six share-priced selectors of a vault with a HyperCore balance fuse, not other selectors or legacy bases. The keeper or the alpha then refreshes the child's market in its own transaction, so the child is not in a window.
3. On the child: the alpha routes swaps only through reviewed pools and tokens without hooks and splits large moves into smaller batches (the error does not exceed the amount moved in a batch). This is operational discipline, not an on-chain control.

The cost of 2 is the trade-off of "Cached NAV: what deposits and idle exits are priced on (IL-9608)": the child's market is priced from the cache, so the stale-cache effect returns for it, and the parent does not pull the child's liquidity on a user exit. The atomist chooses between a child that does not satisfy C (the refreshing hook stays) and an excluded child market with the keeper cadence and a redemption delay above 0.

**Other readers.** `ERC4626PriceFeed` reads the live `convertToAssets`; the crosschain dispatchers (`TrackedVaultPricingLib`) call it directly; the retired `WrappedPlasmaVault` reads the child's `maxWithdraw` for its `totalAssets()`; external integrators can read the views in the same transaction. Do not price PlasmaVault shares in a call that can be triggered from inside an operation of that vault. Attesters take the value from `observation()` with their own call; an on-chain response is supporting evidence only.

Status: known limitation, no code guard (owner decision), for existing and new vaults; configuration is the only control.

## Pre-hooks and vaults with a live EulerSwap pool (IL-9331)

A pre-hook that refreshes balances on user entry points (any pre-hook that calls `updateMarketsBalances`: `UpdateBalancesPreHook`, `UpdateBalancesIgnoreDustPreHook`, `HyperCoreCapitalFlowPreHook`, ...) makes the user operation a trigger for `updateMarketsBalances`. For the `EULER_V2` market (11) in a vault with a live EulerSwap pool this must not be reachable from any user operation, that is, every pre-hooked selector that an account other than the keeper or the alpha can call (`PlasmaVault._checkCanCall` runs the pre-hook for every `restricted` selector; for example `deposit`, `depositWithPermit`, `mint`, `withdraw`, `redeem`, `redeemFromRequest`, `transfer`, `transferFrom`, not a closed list): the pool's value depends on a state that a trader can move, and whoever can force the refresh chooses which state is recorded in the share price. Reachability counts, not only direct wiring: the hook nested inside `ExchangeRateValidatorPreHook`; an instant withdraw from market 11; a refresh or an instant withdraw of any other market whose dependency graph (expanded recursively) contains market 11; and `UpdateBalancesIgnoreDustPreHook` once the cached balance of market 11 reaches its threshold (`>=`), so a cache below the threshold today is no permanent protection. Market 11 is then refreshed only by the keeper or the alpha; that refresh is a public transaction that can be sandwiched, so submit it privately. Details and the stale-cache trade-off: [Euler fuses README](../fuses/euler/README.md#live-eulerswap-pools-and-user-triggered-refreshes). A VaultValidator rule for this is being prepared separately; it must walk `getPreHookSelectors()` rather than a fixed selector list.

To keep refreshing the other markets on user entry points, use `UpdateBalancesExcludeMarketsPreHook` with market 11 as its excluded market instead of `UpdateBalancesPreHook` (IL-9609). It refreshes every active market that is not in its substrate list. It does not stop the refresh through the dependency graph: a market with an edge to market 11 still refreshes it, so the graph rules above stay. Register it directly on each selector; nested in `ExchangeRateValidatorPreHook` it would get no substrates and refresh everything. Details: [Euler fuses README](../fuses/euler/README.md#live-eulerswap-pools-and-user-triggered-refreshes). The scenario (swap, user redeem, swap back) is pinned in `test/pre_hooks/UpdateBalancesExcludeMarketsPreHookTest.t.sol`, with `UpdateBalancesPreHook` as the control that books the moved pool value.

Pools with a pool entry (IL-9706) and a balance fuse of this release are valued by their fair point, so a swap, a donation or a JIT borrow no longer moves the recorded value beyond the LP fee. A pool on sub-account `0x00` that trades the vault's own underlying is outside this valuation (its leg is idle, read live outside market 11): new deployments of it are rejected, and an existing one should be exited. This does not relax the rule above: what stays (a refresh around a real price move, the step at the expiry of a pool, the removal of the entry by `FUSE_MANAGER_ROLE`, an underwater pool sub-account, the socialization charge of another underwater sub-account) is moved by whoever can trigger the refresh. Pools without an entry and vaults with an earlier `EulerV2BalanceFuse` stay on the rule as written. A vault with a pool entry must use only the Euler fuses of that release: an earlier balance fuse reverts every refresh of market 11, and earlier action fuses read the entry as an eVault row. Details: [Euler fuses README](../fuses/euler/README.md#pool-entries-and-the-fair-point-il-9706).

## Market limits and callbacks (IL-9404)

Market limits are checked against the vault NAV. A callback (for example a flash-loan callback routed through `executeInternal`) refreshes the markets of its own fuse actions while the borrowed tokens still sit in the vault, but it does not check their limits (IL-9708): inside the callback the NAV is not the NAV after the repayment, so a limit measured there would be wrong in both directions. It is too loose for an allocation made with the loan, and it can be too tight for a legitimate one: a flash loan of a token valued by `ERC20_VAULT_BALANCE` (market 7) lifted market 7 to about 99% of the NAV and reverted a valid `execute` with `MarketLimitExceeded`.

`execute` therefore records the markets touched in callbacks (in transient storage) and, once all callbacks have returned and the loan is repaid, refreshes and limit-checks them together with the markets of its own fuse actions. The caches are refreshed inside the callback without a limit check, so the check after repayment is the only one and the one that counts: a market that exceeds its limit against the NAV after repayment reverts the whole `execute` with `MarketLimitExceeded`. This closes the path where ALPHA allocates above a limit inside a flash-loan callback (for example `MorphoFlashLoanFuse` with `CallbackHandlerMorpho`, or `EulerV2BatchFuse` with `CallbackHandlerEuler`).

Effect on leveraged loops: the collateral market of a loop is limit-checked against the real NAV after the loan is repaid, not against the NAV that includes the borrowed tokens. A loop whose collateral market ends above its limit as a share of that NAV no longer fits; the ATOMIST has to set the limit of the collateral market for the leveraged position (or ALPHA has to use a smaller loop).

The final check has no exemption for risk-reducing actions: a market that is already above its limit (for example after the NAV shrank through redemptions) reverts any `execute` that touches it, directly or in a callback, unless that `execute` brings it under its limit. A flash-loan deleverage through a callback that leaves the net balance of such a market unchanged therefore reverts with `MarketLimitExceeded`. Keep headroom in the limits for NAV changes. To unwind an over-limit market, move equity to idle in the same `execute`, or let the ATOMIST raise or deactivate the limit first.

Vaults on an older PlasmaVault implementation check the markets touched in a callback only inside the callback, against the NAV that includes the borrowed tokens. On such a vault, do not rely on market limits when it has a callback-capable fuse (flash-loan connector or Euler batch fuse with a borrowable substrate), or monitor the market shares after each `execute`. Vaults built with the IL-9404 record but before IL-9708 also check the markets of a callback inside it, against the NAV that includes the borrowed tokens, so a flash loan of a token valued by market 7 can revert there although the position fits after repayment.

## Market limits and the balance refresh (IL-9612)

Market limits bound what moves into a market, not what a market is worth. On vaults created from a template built with IL-9612, `updateMarketsBalances` stores the refreshed balance of every listed market and crystallizes the performance fee without checking the market limits, also when a market is above its limit (after a price move or accrued yield, or after exits shrank the NAV). Before IL-9612 the refresh ran the same check as `execute`: while a market stayed above its limit, every refresh that included it reverted with `MarketLimitExceeded`, the cache kept the lower value and deposits were priced on that stale NAV (Olympix 2026-11-06 M22; before, an accepted risk of IL-8628, with the stale-cache entry of IL-8819).

The limit is still enforced wherever assets move:

- `execute` refreshes the markets it touches and reverts with `MarketLimitExceeded` when one of them ends above its limit, as described above. The markets touched in a callback (`executeInternal`) are refreshed there without a check and limit-checked here once, after repayment (IL-9708). A stored over-limit balance does not open `execute`: ALPHA still has to bring the market under its limit in the same `execute`, or the ATOMIST raises or deactivates the limit first.
- `withdraw` and `redeem` that pull from the markets refresh the markets they pulled from and store the balances without checking the limits (IL-9700, IL-9694 D-003; before it they reverted with `MarketLimitExceeded` when a pulled market was still above its limit). The limit is an allocation rule enforced where assets move into a market (`execute`, after any callback returned); an exit must not be blocked because a market sits above its limit, and a pull from such a market lowers it. A payout from the idle balance pulls nothing and checks no limit. Note: a fuse exit that leaves a non-underlying token in the vault (for example an exit that returns a reward or collateral token) can raise another market (for example ERC20_VAULT_BALANCE, market 7) above its limit without a check; the next `execute` that touches that market is checked.

Effect on pre-hooks: `UpdateBalancesPreHook`, `UpdateBalancesIgnoreDustPreHook`, `UpdateBalancesExcludeMarketsPreHook` and the HyperCore capital flow hooks (`HyperCoreCapitalFlowPreHook`, `HyperCoreCapitalFlowFullRefreshPreHook`) refresh through `updateMarketsBalances`. On a vault built with IL-9612 a market above its limit therefore no longer reverts the deposits, mints, and withdrawals and redeems paid from idle that run such a hook; a withdrawal or redeem that pulls from an over-limit market no longer reverts in the pull either (IL-9700). `UpdateMarketsBalancesFuse` (ALPHA, inside `execute` or a callback) refreshes without the check. From the IL-9708 release it also records the markets it refreshed (`PlasmaVaultMarketsLib.recordCallbackMarkets`), so `execute` re-reads them and limit-checks them once at the end, against the NAV after all callbacks returned and any flash loan was repaid (3sigma audit v3 #22: a callback refreshed a market that values a borrowed non-underlying token, the cache kept the loan amount after repayment and `totalAssets` stayed inflated). Side effect: an over-limit market refreshed by this fuse inside `execute` now reverts the whole `execute` with `MarketLimitExceeded`. Keepers keep refreshing through `PlasmaVault.updateMarketsBalances`, which does not check limits, so they are unaffected. The change needs a new deployment of the fuse (a new `VERSION` address); existing vaults get it by swapping the fuse through governance, and until then they keep the old behaviour.

Monitoring: a market above its limit no longer shows as a reverting keeper refresh. Watch the market shares instead (`totalAssetsInMarket(marketId)` against `totalAssets()` and `getMarketLimit(marketId)`).

Vaults on an older PlasmaVault implementation keep the old behaviour: the refresh reverts while a market is above its limit, and the ATOMIST has to raise or deactivate the limit to let it through.

This behaviour is pinned by `test/vaults/PlasmaVaultRefreshAboveMarketLimitTest.t.sol` (the refresh stores the over-limit balance and a later deposit is priced on it; `execute` that touches the market still reverts; with `UpdateBalancesPreHook` a deposit and an idle withdrawal go through) and, for the pull (IL-9700), by `test/vaults/PlasmaVaultWithdrawAboveMarketLimitTest.t.sol`.

## Instant withdrawals (IL-9407)

When a `withdraw` or `redeem` exceeds the idle assets, the vault pulls the missing assets from the markets on the instant withdrawal list (`configureInstantWithdrawalFuses`, in list order). `redeem` pulls 2% more than the amount to be paid (the over-pull stays in the vault as cash). The touched markets are then refreshed and the payout is priced on the NAV after that refresh.

**Exit costs are shared by all holders.** Every cost of the exit (exit fee, slippage, rounding, and the cost paid on the 2% over-pull) lowers the NAV before the payout is priced, so the exiting holder bears only its pro-rata share of the cost and the remaining holders bear the rest. This is the usual pooled-vault model, not a defect of a single exit.

**List rule.** Put on the instant withdrawal list only markets that exit at their booked value (lending markets, vaults without an exit fee). A market with an exit fee or a slippage tolerance (for example Yield Basis, or LitePSM with a non-zero `tout`) belongs on the list only after a deliberate decision of the role that configures it (`CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE`), who accepts that the remaining holders pay for other holders' exits. Otherwise unwind such positions with ALPHA actions under explicit slippage limits before users exit. A target that runs third-party code during a withdrawal opens, on this vault, the window described in "Transient share-price views during `execute` and instant withdrawal (IL-9631, IL-9743)". On this code, an entry of the market that values a child PlasmaVault can make a user's `withdraw`, `redeem` or `redeemFromRequest` refresh that market even when the child pays nothing.

## Parked fee shares and burning them (IL-9598)

Deposit-fee shares (`deposit` and `mint` with a deposit fee) are minted to the WithdrawManager, and request-fee shares are moved to it when a withdrawal request is filed. They stay in `totalSupply()` until ALPHA either burns them with `BurnRequestFeeFuse.enter` or refunds them with `RequestFeeRefundFuse`; the parked balance is deliberately the same pool that funds the refunds.

A burn lowers `totalSupply()` and therefore credits every holder at the moment of the burn, including an account that deposited shortly before it. No value leaves the vault, only the split between holders changes. A large parked balance burned in one go, at a time that can be anticipated, gives a late entrant a share of it.

Operational rule: burn the parked fee shares often, in small portions, and do not announce the time of a burn in advance. Keep refund needs in mind when choosing the amount, because burned shares can no longer be refunded.

## Management fee changes (IL-8742)

The checkpoint moves the fee accrued at the old rate into the pending management fee; it is minted to the management fee account at the next realization (deposit, mint, withdraw, redeem) and split by the recipient fees in force when `harvestManagementFee` runs. On a FeeManager without the IL-9431 gate a recipient change therefore sends the old period to the new split (with the gate, a fee that would mint a share blocks the change until it is realized, so only a non-mintable remainder goes to the new split), and with a new total of 0 (possible only when `IPOR_DAO_MANAGEMENT_FEE == 0`) `harvestManagementFee` returns early and the shares wait in the management fee account until a non-zero fee is configured, then go to the recipients in force at that time.

To pay the old period to the old recipients, realize the fee first, in the same transaction batch and before `FeeManager.updateManagementFee`. Any of these works:

- ALPHA calls `realizeManagementFee()` (templates built with IL-8870).
- ALPHA runs `execute([RealizeManagementFeeFuse])` (any version, once the FUSE_MANAGER has added the fuse; see [the fuse README](../fuses/management_fee/README.md)). Run it alone in its own `execute`, with nothing before or after it (see the fuse README).
- Any deposit, mint, withdraw or redeem (e.g. 1 unit by the atomist Safe; it needs deposit access on a private vault). This needs no fuse and no ALPHA call.

A change of the management fee requires the pending fee to be realized first: the DAO fee is immutable and its share of the old period is `daoFee / total` of the total in force when the fee is harvested, so without realizing first a raise of the total pays the DAO less for the old period (a cut pays it more).

FeeManager deployments with the IL-9431 gate enforce this: `updateManagementFee` reverts with `FeeManagerUnrealizedManagementFee(unrealizedManagementFee)` while the vault has shares and assets and its unrealized management fee would still mint at least one fee share. The batch order is therefore realize (any of the ways above), then `updateManagementFee`. Earlier FeeManager deployments have no gate; there realizing first is an operational rule only. If none of these can run (no `realizeManagementFee()` on an older template and no `RealizeManagementFeeFuse` added, and deposit, mint, withdraw and redeem blocked: supply cap reached, reverting deposit pre-hook, users paused, atomist Safe without deposit access and without shares), every `updateManagementFee` reverts, also a cut to 0 or a recipient removal. Restore one of these paths first in the same batch (raise the supply cap, grant the deposit role or whitelist, unpause), then realize the fee, then change it.

Shares already waiting can be released in one batch: `updateManagementFee([recipient, 1])`, `harvestManagementFee()`, `updateManagementFee([])` (same block, no new accrual). On a FeeManager with the gate, realize the pending fee first in that batch as well, otherwise the first call reverts.

## Performance fee changes (IL-9632)

On vaults created from a template built with IL-9632 (the new `PlasmaVault` and `FeeManager` pair), a change of the performance fee does not reach back. `FeeManager.updatePerformanceFee` now runs three steps in one call:

1. `PlasmaVault.realizePerformanceFee()` crystallizes the performance fee at the old rate. It is the vault's regular crystallization, the same as in `execute`, `updateMarketsBalances`, `withdraw` and `redeem`: fee shares for the gain above the high-water mark are minted to the performance fee account and the mark moves to the price after the mint.
2. `harvestPerformanceFee()` pays the performance fee account out with the old split (DAO and old recipients).
3. The new recipients and the new total are written (`configurePerformanceFee` on the vault).

The gain earned under the old settings is therefore charged at the old rate and paid to the old recipients, also when only the recipients change. The new rate applies only to the gain above the high-water mark after the call: a cut does not forgive the fee owed on the earlier gain, and a raise (also from 0) does not charge it again at the new rate.

Why (Olympix 2026-11-06 L01; earlier reports IL-8342 and IL-9455/IL-9456, closed as a trusted-role change): `configurePerformanceFee` wrote the new rate without crystallizing, so the next crystallization charged the whole gain since the previous one at the new rate and the next harvest paid it to the new split. The management fee side already had its checkpoint (IL-8742, section above).

Operational notes:

- The crystallization prices the stored market balances. To charge a gain that is not booked yet at the old rate, refresh the markets in the same batch before `updatePerformanceFee` (`updateMarketsBalances` with the active markets). A gain booked only after the change is charged at the new rate.
- With a high-water mark update interval the change behaves like any other crystallization: when the price is below the mark and the interval has passed, the mark is lowered to the current price, and the recovery after the change is charged at the new rate. Before the interval has passed, the mark is kept.
- `realizePerformanceFee()` is restricted to `TECH_PERFORMANCE_FEE_MANAGER_ROLE`, which only the FeeManager holds; `IporFusionAccessManagerInitializerLibV1` maps the selector. An access manager configured by hand must map it too, otherwise every `updatePerformanceFee` reverts with `AccessManagedUnauthorized(feeManager)`.
- Pairing: a FeeManager built with IL-9632 calls `realizePerformanceFee()` and reverts on a vault built before it. Existing vaults keep their pair and the old behaviour: there, crystallize by hand in the same batch before `updatePerformanceFee` (`updateMarketsBalances` with the active markets, an `execute` by ALPHA, or any `withdraw` or `redeem`); the harvest at the start of `updatePerformanceFee` then pays the minted shares to the old split.

This behaviour is pinned by `test/vaults/PlasmaVaultPerformanceFeeRateChangeTest.t.sol` (raise, cut and recipient change with a gain before the change; no gain; below the mark with and without an elapsed update interval; access to `realizePerformanceFee` and its equivalence with `execute`).

## Performance fee and partially refreshed NAV (IL-9600)

`updateMarketsBalances(marketIds)` refreshes only the listed markets and the markets they depend on (the dependency graph, expanded recursively), and then crystallizes the performance fee on the share price. The price is built from fresh balances of the refreshed markets and cached balances of all the others. Two positions whose values offset each other (a leg of debt and its collateral, a hedge and the exposure it hedges, a market whose price depends on another market) therefore produce a phantom performance fee when only one of them is refreshed: a gain booked on one market while the matching loss on the other is still unbooked raises the share price above the high-water mark, the fee is minted on that price, and the high-water mark stays raised after the second market is booked. The fee is not refunded.

The size of the effect is bounded: the fee shares minted are at most the performance fee rate times the holders' share of the phantom delta (the booked gain that the unbooked loss offsets). It happened on the Tau vaults on Base (2026-10-09), where a lone Aave V4 exit refreshed only the debt leg.

**Configuration rule.** Markets whose values offset each other must have an edge in the dependency graph in both directions (`updateDependencyBalanceGraphs`, FUSE_MANAGER_ROLE): A depends on B and B depends on A. Then a refresh that starts from either of them refreshes both, and the fee is computed on the full delta. An edge in one direction is not enough: refreshing the market that has no outgoing edge leaves the other one stale. Example: Aave V4 debt leg 14 and collateral leg 49 (`14 <-> 49`). The same rule is in the crosschain README and in the NatSpec of `UpdateBalancesPreHook`.

The core does not know which markets offset each other and does not refresh every active market before a fee crystallization: that would cost gas on every `execute` and would refresh market 11 from user flows, which the rule in the EulerSwap section below forbids. Enforcing the graph rule belongs to the VaultValidator.

This behaviour is pinned by `test/vaults/PartialRefreshPerformanceFeeDependencyGraphTest.t.sol` (no edge: a phantom fee within the bound and a raised high-water mark; edge both ways: no fee and an unchanged high-water mark; edge one way: the phantom fee remains).

## Cached NAV: what deposits and idle exits are priced on (IL-9608)

`totalAssets()` is the idle balance of the underlying plus the cached balance of every market. The cache is rewritten only when a market is refreshed: by `execute` for the markets its fuses touched, by `updateMarketsBalances` (keeper), by a refresh inside `withdraw` or `redeem`, or by a pre-hook that calls `updateMarketsBalances`. This is a design choice (NAV from cache, not from live reads), so two user operations are priced on a possibly stale NAV:

- **Deposit and mint** do not refresh any market. After an unbooked gain the entry is priced below the real NAV, after an unbooked loss above it.
- **Withdraw and redeem** refresh the markets they pull from, and only when the payout reaches the idle balance. A payout that fits into the idle balance is priced on the cache of all markets. After an unbooked loss the exit is priced above the real NAV.

**Bound.** The value that changes hands is the participant's share of the unbooked delta: for a depositor `shares / totalSupply` after the deposit times the gain, for a leaver `shares / totalSupply` before the exit times the loss. It never exceeds the delta, and the other holders bear or receive the rest. With a redemption delay above 0 a deposit and a redeem cannot happen in one transaction, so the profit is not riskless arbitrage. With a redemption delay of 0 they can, also inside one flash loan, so the profit can be taken without holding a position; the profit is largest for a participant that is large relative to the vault and can anticipate an unbooked move. A vault with a redemption delay of 0 should wire `UpdateBalancesPreHook` (or `UpdateBalancesIgnoreDustPreHook`) on `deposit`, `mint`, `withdraw` and `redeem`; this is a recommended configuration, not enforced by the vault.

**Configuration.**

- Keep the keeper refreshing the markets on a cadence that fits the volatility of the positions (`updateMarketsBalances`).
- To remove the effect, wire `UpdateBalancesPreHook` (or `UpdateBalancesIgnoreDustPreHook`, which skips markets below a dust threshold) on the user selectors: `deposit`, `mint`, `withdraw`, `redeem`. Every such operation then runs on a refreshed NAV of the vault's own markets, at the gas cost of refreshing all active markets and with the performance fee crystallized before the entry. A child Plasma Vault held as an ERC-4626 substrate is read from its own cache and is not refreshed by it (see "Nested Plasma Vaults" below).
- Do not wire it when the vault has a live EulerSwap pool in market 11 and the hook would refresh that market: see "Pre-hooks and vaults with a live EulerSwap pool (IL-9331)" above. Use `UpdateBalancesExcludeMarketsPreHook` with market 11 excluded there (IL-9609); market 11 itself keeps the stale-cache trade-off and the keeper cadence is the only control for it.
- On a parent that holds a child PlasmaVault, the refreshing hook turns a user operation into a read of the child's share price. When the child can run code that its trusted roles did not choose in its `execute` batch or instant withdrawal, exclude the child's market from the user-triggered refresh, selector by selector: replace a plain refresher with `UpdateBalancesExcludeMarketsPreHook`, remove refreshing hooks nested in `ExchangeRateValidatorPreHook` while keeping the validator, keep non-refreshing controls, and on a vault with a HyperCore market use the exclusion list of `HyperCoreCapitalFlowFullRefreshPreHook` on the six share-priced selectors. Direct `updateMarketsBalances` access must also be limited to trusted operators. The excluded market keeps the stale-cache trade-off of this section, so it needs the keeper cadence and a redemption delay above 0. Rule and limits: "Transient share-price views during `execute` and instant withdrawal (IL-9631, IL-9743)" above.
- A refresh from a hook is subject to the partial refresh rule above: markets that offset each other need a dependency graph edge in both directions.

**Nested Plasma Vaults.** When a market substrate is itself a Plasma Vault (a child), `Erc4626BalanceFuse` values the position with the child's `convertToAssets()`, which is computed from the child's idle balance and the market balances the child stored last. A refresh of the parent (`updateMarketsBalances`, or `UpdateBalancesPreHook` on the parent's `deposit` and `redeem`) does not refresh the child: reading the child is a view and runs none of the child's hooks. A gain or loss in the child's markets that the child has not booked is therefore missing from the parent's NAV until someone refreshes the child (its own pre-hook, a keeper or any `updateMarketsBalances` caller). The parent cannot force this, because the child may have a different atomist. This is a known scenario and it is not guarded in code (IL-9703, owner decision). Atomists of a parent should hold only children that are refreshed at least as often as the parent relies on their value, and should treat the child's refresh cadence as part of the parent's risk. A parent's `UpdateBalancesPreHook` does not change this.

This behaviour is pinned by `test/vaults/CachedNavEntryExitBoundTest.t.sol` (entry after an unbooked gain, exit from idle after an unbooked loss: the transfer equals the share of the delta; with `UpdateBalancesPreHook` on `deposit` and `redeem` there is none). `test/vaults/CachedNavNestedChildPinTest.t.sol` pins the nested case: a 50% loss in the child's market that the child has not booked leaves the parent's position unchanged after a parent `deposit` and `redeem` with `UpdateBalancesPreHook`; after `updateMarketsBalances` on the child the next parent refresh shows about half of the position.

## Reward vesting and rewards claimed on the vault's behalf (IL-9744)

**Scope of vesting.** `totalAssets()` is the live balance of the underlying held by the vault, plus the stored balance of every market, plus `RewardsClaimManager.balanceOf()` when a manager is set. With a non-zero vesting time the manager reports only the vested part of the underlying it held when `updateBalance()` last started the schedule, so the vesting schedule covers only underlying that sits in the manager at that moment. Underlying that reaches the vault by any other route is counted in `totalAssets()` immediately. A vesting time of zero removes the schedule altogether: the manager then reports its live balance.

**Limitation.** Some reward distributors accept a claim for any account from any caller and pay the account itself. The reward fuses forward to the manager only what their own call returned or received, and they run on the keeper path (`RewardsClaimManager.claimRewards`, then `PlasmaVault.claimRewards`, then a delegatecall of each fuse). A claim made this way for the vault pays the vault directly: the vault is not called, so the manager is bypassed and no vault setting (the list of reward fuses, substrates, roles, the vesting time) can intercept it. No reward fuse moves a balance the vault already holds to the manager, and `RewardsClaimManager.transfer` moves only tokens that are in the manager and refuses the underlying. Which distributors behave this way, and on what basis, is listed in [Reward fuses](../rewards_fuses/README.md#claims-made-on-the-vaults-behalf).

**Effect, reward in the underlying.** The whole amount enters `totalAssets()` at once and the share price rises in one step, so vesting is bypassed for that amount.

**Effect, reward in another token.** The token stays in the vault, and what happens next depends on the market 7 (ERC20 balance) configuration. (a) No balance fuse of the vault counts the token (typically it is not a substrate of market 7, the conventional ERC20 balance market, or the vault has no such market): it stays outside the NAV until ALPHA swaps it with `execute`, and its value then enters in one step. (b) The token is a substrate of market 7 and has a price: the whole balance enters the NAV in one step at the next refresh of that market. (c) The token is a substrate of market 7 but the price oracle has no usable price for it: the ERC20 balance fuse asks the oracle for a price whenever the token balance is positive, so the refresh of market 7 reverts, and so does every operation that refreshes that market, until the token gets a price source or the substrate is removed. This applies to any positive balance of such a token, not only to rewards. Rule: a token granted as a substrate of market 7 must have a price source.

**Bound.** The value that changes owner is at most the rewards accrued at the distributor since the last claim (by the keeper or by anyone else), times the share of the supply held by the entering account after its deposit. Rewards left unclaimed before a period can be claimed within it, so over a period the total is bounded by the rewards unclaimed at its start plus those accrued during it. The capital of the vault is not at risk.

**Redemption delay.** With a redemption delay above 0, an account that is not exempt from the delay cannot enter and exit in one transaction, so only entry funded by a flash loan is ruled out for such accounts; capital held through the lock period is still enough. Accounts on the exemption list (`setRedemptionDelayExemption`) have no such lock. With a redemption delay of 0 see "Cached NAV: what deposits and idle exits are priced on (IL-9608)" above; the `UpdateBalancesPreHook` recommended there does not help here, because a reward in the underlying is read from the vault's live balance, not from a market.

**Operating rule.** The keeper claims the rewards at short intervals, so that the unclaimed amount stays small; for a distributor that publishes cumulative amounts the claimable amount grows at each publication, so the keeper claims soon after a new amount is published. A vault whose underlying is paid as a reward by such a distributor accepts this as a known limitation: vesting is not guaranteed for those rewards, and a shorter interval narrows the window but does not close it. The atomist weighs this before the vault takes a position that earns such rewards; leaving the claim fuse out does not avoid it.

**Status.** Known limitation, not guarded in code (IL-9744, owner decision).

## Creating New Plugins

To create a new plugin:

1. **Create the plugin contract** in `plugins/` directory
2. **Use ERC-7201 namespaced storage** that doesn't conflict with existing slots
3. **Create an interface** in `interfaces/`
4. **Add routing logic** in the PlasmaVaultBase fallback function (PlasmaVault forwards unknown selectors there)
5. **Add storage slot** for plugin address in PlasmaVaultStorageLib
6. **Update PlasmaVaultInitData** struct if plugin is configured at init time

Example plugin structure:

```solidity
// plugins/PlasmaVaultMyPlugin.sol
contract PlasmaVaultMyPlugin is IPlasmaVaultMyPlugin {
    // Use unique ERC-7201 storage slot
    bytes32 private constant MY_STORAGE_LOCATION =
        0x...; // keccak256("io.ipor.fusion.MyPlugin")

    struct MyStorage {
        // plugin-specific state
    }

    function _getMyStorage() private pure returns (MyStorage storage $) {
        assembly { $.slot := MY_STORAGE_LOCATION }
    }

    // Plugin functions...
}
```

## Benefits of This Architecture

1. **Contract Size Management**
    - PlasmaVault stays under 24KB limit
    - New features added as plugins without bloating main contract

2. **Gas Efficiency**
    - Vaults only pay for features they use
    - No voting overhead for non-governance vaults

3. **Upgradability**
    - Plugins can be upgraded independently
    - New plugins can be added to existing vault deployments

4. **Security**
    - Clear separation of concerns
    - Each component can be audited independently
    - Storage isolation via ERC-7201 namespacing
