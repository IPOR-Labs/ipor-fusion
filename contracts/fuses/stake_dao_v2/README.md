# StakeDAO V2 Integration

## Overview

StakeDAO V2 integration enables IPOR Fusion to interact with StakeDAO V2 reward vaults (ERC4626-compliant). This integration allows users to deposit assets and earn yields from various DeFi protocols through a unified interface, while also claiming rewards from multiple sources.

## Market Structure

The integration uses two distinct markets for different operations:

-   **Market ID 31** (`STAKE_DAO_V2`) - Supply/withdrawal operations
-   **Market ID 32** (`STAKE_DAO_V2_REWARDS`) - Reward claiming operations

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
2. **Convert to LP tokens**: Convert reward vault shares to LP token assets using `convertToAssets()`
3. **Convert to underlying**: Convert LP token assets to underlying asset amount
4. **Get price**: Retrieve underlying asset price from price oracle
5. **Calculate USD value**: Convert to USD using WAD decimals and add to total balance

### Important Notes

-   StakeDAO V2 deposited assets are 1:1 shares of the reward vault
-   No additional conversion is needed for reward vault shares to assets
-   The LP token vault handles decimal conversions internally

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

### 1. STAKE_DAO_V2 Market (Market ID: 31) - Supply/Withdrawal Operations

For supply and withdrawal operations, substrates are configured as **simple reward vault addresses**.

#### Vault examples:

| Vault Name     | Reward Vault Address                         | LP Token Address                             | Underlying Asset |
| -------------- | -------------------------------------------- | -------------------------------------------- | ---------------- |
| LlamaLend WBTC | `0x1544E663DD326a6d853a0cc4ceEf0860eb82B287` | `0xe07f1151887b8FDC6800f737252f6b91b46b5865` | WBTC             |
| LlamaLend WETH | `0x2abaD3D0c104fE1C9A412431D070e73108B4eFF8` | `0xd3cA9BEc3e681b0f578FD87f20eBCf2B7e0bb739` | WETH             |
| LlamaLend EYWA | `0x555928DC8973F10f5bbA677d0EBB7cbac968e36A` | `0x747A547E48ee52491794b8eA01cd81fc5D59Ad84` | EYWA             |
| LlamaLend ARB  | `0x17E876675258DeE5A7b2e2e14FCFaB44F867896c` | `0xa6C2E6A83D594e862cDB349396856f7FFE9a979B` | ARB              |

### 2. STAKE_DAO_V2_REWARDS Market (Market ID: 32) - Reward Claiming Operations

For reward claiming operations, substrates use a **typed structure** that includes both the substrate type and address.

#### Substrate Types

```solidity
enum StakeDaoV2SubstrateType {
    UNDEFINED,
    RewardVault, // For main rewards from reward vaults
    ExtraRewardToken // For extra reward tokens
}
```

#### Configuration Structure

```solidity
struct StakeDaoV2Substrate {
    StakeDaoV2SubstrateType substrateType;
    address substrateAddress;
}
```

## Price Oracle Setup

### Required Price Feeds

The integration requires price feeds for all LP token underlying asset. Price feed configuration via `Price Oracle Middleware Manager` or `Price Oracle Middleware`

-   **crvUSD/USD**
