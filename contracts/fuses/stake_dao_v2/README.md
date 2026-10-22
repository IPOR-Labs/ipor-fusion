# StakeDAO V2 Integration

## Overview

StakeDAO V2 integration enables IPOR Fusion to interact with StakeDAO V2 reward vaults (ERC4626-compliant). This integration allows users to deposit assets and earn yields from various DeFi protocols through a unified interface, while also claiming rewards from multiple sources.

**What Stake DAO v2 does:**
StakeDAO V2 provides yield farming opportunities by aggregating liquidity across multiple DeFi protocols. Users can deposit assets into reward vaults that automatically allocate funds to various strategies (like lending protocols, DEX liquidity pools, etc.) and earn both yield from the underlying protocols and additional rewards from StakeDAO's reward distribution system.

## Market Structure

The integration uses a single market for all operations:

-   **Market ID 34** (`STAKE_DAO_V2`) - Supply/withdrawal/claim operations

## Architecture

### Vault Hierarchy

StakeDAO V2 follows a nested vault structure:

```
StakeDAO V2 Reward Vault (ERC4626)
├── LP Token Vault (ERC4626)
    └── Underlying Asset (e.g., WBTC, WETH, etc.)
```

### Key Components

-   **`StakeDaoV2BalanceFuse`**: Tracks total USD value across all configured reward vaults
-   **`StakeDaoV2SupplyFuse`**: Handles deposits and withdrawals from reward vaults
-   **`StakeDaoV2ClaimFuse`**: Manages reward claiming for both main rewards and extra rewards

## Balance Calculation

The balance calculation follows a multi-step process for each configured reward vault:

1. **Get vault balance**: Retrieve Plasma Vault's balance in each reward vault (1:1 shares in StakeDAO)
2. **Add loose LP-vault shares**: Retrieve the Plasma Vault's own (unstaked) balance of the reward vault's LP token and add it to the reward-vault balance, deduplicated per LP token address (see "Loose LP-vault shares" below)
3. **Convert to LP tokens**: Convert the combined (staked + loose) balance to LP token assets using `convertToAssets()`
4. **Convert to underlying**: Convert LP token assets to underlying asset amount
5. **Get price**: Retrieve underlying asset price from price oracle
6. **Calculate USD value**: Convert to USD using WAD decimals and add to total balance

### Important Notes

-   StakeDAO V2 deposited assets are 1:1 shares of the reward vault
-   No additional conversion is needed for reward vault shares to assets
-   **Main Rewards**: Primary protocol tokens (e.g., CRV, BAL, AURA) that are always available
-   **Extra Rewards**: Additional incentive tokens (e.g., CVX, LDO, WETH) that are distributed when available and when main rewards are being claimed

### Loose LP-vault shares

`StakeDaoV2SupplyFuse`'s instant withdraw (`_exit` with exception catching enabled) first redeems
reward-vault shares for LP-vault shares (Stake DAO is 1:1, so when this succeeds the full LP amount comes back) and then redeems
the LP-vault shares for the underlying asset. A lending LP vault (e.g. LlamaLend) only pays out up to
its available liquidity, so the inner redeem is **capped** by `lpVault.maxRedeem(plasmaVault)`, read
after the outer redeem (before it the PlasmaVault holds no LP-vault shares and `maxRedeem` would be
0). If `maxRedeem` is 0 or reverts, the full amount is attempted as before (same fallback as
`Erc4626SupplyFuse`, IL-8505, for LP vaults that report `maxRedeem == 0`). The part that could not be
redeemed (cap, or a failed inner redeem that is swallowed for availability) is **re-staked** into the
reward vault (`StakeDaoV2SupplyFuseRestaked`), so it keeps earning Stake DAO rewards and no loose
LP-vault shares are created. The ALPHA `exit` path is unchanged: it reverts as a whole when the inner
redeem fails.

Loose LP-vault shares therefore only remain when the re-stake itself fails (for example the reward
vault is in shutdown; `StakeDaoV2SupplyFuseRestakeFailed` is emitted); the failure is swallowed so that the user withdrawal is not blocked.
`StakeDaoV2BalanceFuse` values these loose LP-vault shares too (deduplicated per LP token,
so a granted reward vault never has its LP token's loose balance counted twice), so the position is
never invisible to `totalAssets()`.

**Reading the events (instant withdraw).** `StakeDaoV2SupplyFuseExit` reports what left the reward vault (`finalRewardVaultShares`, `lpTokenAmount`) and what the LP vault paid out (`lpTokenUnderlyingAmount`). On the cap/restake path part of it goes back in the same transaction: the net reward-vault shares unstaked are `Exit.finalRewardVaultShares − Restaked.rewardVaultShares` (Stake DAO is 1:1, so this equals `Exit.lpTokenAmount − Restaked.lpTokenAmount`). After `StakeDaoV2SupplyFuseRestakeFailed`, its `lpTokenAmount` stays as loose LP-vault shares. `StakeDaoV2SupplyFuseExitFailed` is always followed by `Exit` in the same call: with `lpTokenAmount == 0` the reward-vault redeem failed and nothing left the reward vault; with `lpTokenAmount > 0` the LP-vault redeem failed and that amount was restaked (or left loose).

Because loose LP-vault shares are valued in the STAKE_DAO_V2 market (market 34), **the LP token
must not additionally be granted to another balance-carrying market** (e.g. an ERC20 balance market
or an ERC4626 balance market) — doing so would double-count the same shares across markets. This is
not enforced in code (fuses do not police grant/revoke consequences); it is a governance
constraint. To recover stranded LP-vault shares, either grant the LP vault to an ERC4626 market with
a zero balance fuse and unwind via `Erc4626SupplyFuse.exit`, or re-stake them into the reward vault.

If the PlasmaVault's own underlying `asset()` happens to be a granted reward vault's LP-vault share
token, `StakeDaoV2BalanceFuse` skips the loose-share addition for that LP token entirely: such a
balance is already counted as idle by `PlasmaVault._getGrossTotalAssets()`
(`IERC20(asset()).balanceOf(address(this))`), so counting it again in this market would double it.
This is derived from the vault's own immutable identity, not from a substrate grant, so it does not
conflict with the "fuses must not police grant/revoke consequences" rule.

**Decommissioning order matters.** Revoking a reward-vault substrate while the PlasmaVault still
holds that LP token's loose (unstaked) shares makes those shares invisible to this market again —
once no granted substrate maps to the LP token, `StakeDaoV2BalanceFuse` has no way to find it.
This is a grant-revocation consequence, correctly outside the fuse's remit to police, but it means
any decommissioning of a reward-vault substrate must unwind (re-stake or move to another market via
`Erc4626SupplyFuse`) any loose LP-vault shares for its LP token **before** the substrate is revoked,
not after.

## Rewards System

### Reward Types

-   **Main Rewards**: Protocol-specific tokens (e.g., CRV, BAL, AURA)
-   **Extra Rewards**: Additional incentive tokens (e.g., CVX, LDO, WETH)

### Reward Claiming

Rewards are claimed through the `StakeDaoV2ClaimFuse` which:

-   Supports claiming multiple reward tokens in a single transaction
-   Handles both main rewards and extra rewards
-   Updates reward state and transfers claimed rewards to the receiver

## Substrate Configuration

### 1. STAKE_DAO_V2 Market (Market ID: 34) - Supply/Withdrawal/claim Operations

For supply and withdrawal operations, substrates are configured as **simple reward vault addresses**.

#### Vault examples on Arbitrum:

| Vault Name     | Reward Vault Address                         | LP Token Address                             | Collateral Asset |
| -------------- | -------------------------------------------- | -------------------------------------------- | ---------------- |
| LlamaLend WBTC | `0x1544E663DD326a6d853a0cc4ceEf0860eb82B287` | `0xe07f1151887b8FDC6800f737252f6b91b46b5865` | WBTC             |
| LlamaLend WETH | `0x2abaD3D0c104fE1C9A412431D070e73108B4eFF8` | `0xd3cA9BEc3e681b0f578FD87f20eBCf2B7e0bb739` | WETH             |
| LlamaLend EYWA | `0x555928DC8973F10f5bbA677d0EBB7cbac968e36A` | `0x747A547E48ee52491794b8eA01cd81fc5D59Ad84` | EYWA             |
| LlamaLend ARB  | `0x17E876675258DeE5A7b2e2e14FCFaB44F867896c` | `0xa6C2E6A83D594e862cDB349396856f7FFE9a979B` | ARB              |

## Price Oracle Setup

### Required Price Feeds

The integration requires price feeds for all LP token underlying asset. Price feed configuration via `Price Oracle Middleware Manager` or `Price Oracle Middleware`

Example:

-   price feed for pair: **crvUSD/USD**
