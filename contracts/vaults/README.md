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
    address plasmaVaultBase;         // Required
    address plasmaVaultERC4626;      // Optional (address(0) to disable)
    address plasmaVaultVotesPlugin;  // Optional (address(0) to disable)
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

## ERC-4626 views: known limitations

### What the views price

`maxWithdraw`, `previewRedeem`, `previewWithdraw`, `maxDeposit` and `maxMint` are priced after the pending management fee. `withdraw`, `redeem`, `deposit` and `mint` realize that fee first, so the views convert against the supply that includes the fee shares (IL-8319, IL-8343, IL-8490).

**Gas cost (IL-8491).** Each of `maxWithdraw`, `previewRedeem` and `previewWithdraw` computes gross total assets up to three times per call: in `_totalSupplyAfterManagementFee()`, again in the `_convertToShares` of the pending fee, and a third time in the final conversion. Every pass reads the asset `balanceOf` and, when a RewardsClaimManager is set, makes an external `RewardsClaimManager.balanceOf()` call; the in-call `maxWithdraw` inside `withdraw` pays the same cost. Measured at optimizer runs = 200 with a RewardsClaimManager, from before IL-8319 to now: `maxWithdraw` 8,864 to 18,709 gas, `previewRedeem` 6,430 to 16,275, `withdraw` 158,750 to 168,204, of which about 7.2k of the roughly +9.8k per view is the repeated computation. This is accepted: passing gross assets once costs +22 B (as a parameter) to +170 B (naive) of PlasmaVault bytecode, and the 487 B (446 B with the IPFS metadata hash) of EIP-170 headroom at 200 runs is kept for security fixes. Revisit it if the views ever simulate the performance fee (IL-8489 option (a)), because one shared helper can then take gross assets once.

### What the views do not price

These two effects are accepted limitations (IL-8489):

- A pending performance fee that `withdraw` and `redeem` crystallize before the limit check. This happens when the share rate is above the high-water mark, for example after vesting rewards, a donation, or the withdraw fee burn of an earlier exit.
- A refresh of stale market balances during `withdraw` or `redeem`.

On vaults created with the IL-8744 FeeManager the high-water mark is the share price right after the last performance fee, so the price equals the HWM after every fee. Any later accretion (a burned withdraw fee, vesting rewards, a donation) therefore creates a pending performance fee immediately. This is correct HWM behaviour, but it makes the effects above occur more often, including exits from nested child vaults through the old `Erc4626SupplyFuse`, and the performance fee now also applies to withdraw fee income. Deposits and mints do not crystallize the performance fee (IL-8327, IL-8756), so a depositor who enters after such accretion pays a price that includes it and is diluted by the fee charged on it at the next `execute`, `updateMarketsBalances`, `withdraw` or `redeem`. With the post-fee high-water mark this applies from the first wei of accretion, not only after the post-fee gap is recovered. Vaults that run `UpdateBalancesPreHook` on deposit and mint crystallize the fee first. Live vaults are unaffected: each has its own non-upgradeable FeeManager and keeps its current behaviour.

As a result, `maxWithdraw` and `previewRedeem` can overestimate, and `previewWithdraw` can underestimate, by the caller's share of that fee or refresh delta. `withdraw(maxWithdraw(owner))` can then revert with `ERC4626ExceededMaxWithdraw`. To exit a whole position, use `redeem(balanceOf(owner))`.

These residuals are pinned by:

- `test/vaults/PlasmaVaultPreviewResidualsTest.t.sol`
- `test/vaults/PlasmaVaultPerformanceFeeFullExitTest.t.sol`
- `test/vaults/PlasmaVaultManagementFeeMaxPreviewTest.t.sol`

### Legacy clones (IL-8492)

Deployed PlasmaVaults are EIP-1167 clones created by FusionFactory and stay on the implementation they were created with. The view fixes above do not reach them, nor will any future fix. Implementations from before the IL-8319/IL-8343 fix do not price the pending management fee in these views either.

A parent vault that fully exits a nested PlasmaVault child through the old `Erc4626SupplyFuse` clamps the amount to the child's `maxWithdraw` and calls `withdraw`. If the child has a pending fee, that exit can revert in `execute`. In `instantWithdraw` the fuse catches the error, skips the exit and emits `Erc4626SupplyFuseExitFailed`.

The `Erc4626SupplyFuse` from IL-8489 handles this: an exit amount greater than or equal to the child's `maxWithdraw` redeems `min(balanceOf, maxRedeem)` shares. That also works against legacy children, but only for parents that use the new fuse deployment.

### Runbook: full exit from a nested PlasmaVault child

Until the parent uses the IL-8489 `Erc4626SupplyFuse` deployment, exit fully in one of these ways:

1. Call `redeem(balanceOf)` on the child directly, where the integration allows it.
2. Put a small `withdraw` earlier in the same `execute`. It realizes the child's pending management and performance fees, so the later `maxWithdraw` no longer includes them. This is not exact when the child charges a withdraw fee (burning the fee shares lifts the rate above the high-water mark again) or when the exit refreshes a stale market balance.
3. Request slightly less than `maxWithdraw`.

After the new fuse is deployed and wired on the parent (`addFuses` and the instant withdrawal configuration), an exit amount greater than or equal to `maxWithdraw` redeems the whole redeemable balance, also for legacy children.

Before a child PlasmaVault enables a management or performance fee, re-run the nested-vault scan and check that full exits of its parents still succeed. The scan script is attached to Jira IL-8492 and needs the keeper DB and an RPC.

## Management fee changes (IL-8742)

The checkpoint moves the fee accrued at the old rate into the pending management fee; it is minted to the management fee account at the next realization (deposit, mint, withdraw, redeem) and split by the recipient fees in force when `harvestManagementFee` runs. A recipient change therefore sends the old period to the new split, and with a new total of 0 (possible only when `IPOR_DAO_MANAGEMENT_FEE == 0`) `harvestManagementFee` returns early and the shares wait in the management fee account until a non-zero fee is configured, then go to the recipients in force at that time.

To pay the old period to the old recipients, realize the fee first: in the same transaction batch, before `FeeManager.updateManagementFee`, make any deposit, mint, withdraw or redeem (e.g. 1 unit by the atomist Safe; it needs deposit access on a private vault).

Shares already waiting can be released in one batch: `updateManagementFee([recipient, 1])`, `harvestManagementFee()`, `updateManagementFee([])` (same block, no new accrual).

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
