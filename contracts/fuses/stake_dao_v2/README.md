# StakeDAO V2 Integration

## Overview

StakeDAO V2 integration enables IPOR Fusion to interact with StakeDAO V2 reward vaults (ERC4626-compliant). Users can deposit assets and earn yields from various DeFi protocols through a unified interface.

## Market Structure

-   **Market ID:** `31` (STAKE_DAO_V2)
-   **Rewards Market ID:** `32` (STAKE_DAO_V2_REWARDS)

## Architecture

### Vault Hierarchy

```
StakeDAO V2 Reward Vault (ERC4626)
├── LP Token Vault (ERC4626)
    └── Underlying Asset (WBTC, WETH, etc.)
```

### Key Components

-   `StakeDaoV2BalanceFuse`: Tracks total USD value across vaults
-   `Erc4626SupplyFuse`: Handles deposits/withdrawals
-   `StakeDaoV2ClaimFuse`: Manages reward claiming

## Balance Calculation

The balance is calculated by iterating through all configured Reward Vaults (substrates):

-   **Get vault balance**: Retrieve Plasma Vault's balance in each reward vault (1:1 shares in StakeDAO)
-   **Convert to LP tokens**: Convert reward vault shares to LP token assets using `convertToAssets()`
-   **Convert to underlying**: Convert LP token assets to underlying asset amount
-   **Get price**: Retrieve underlying asset price from price oracle
-   **Calculate USD value**: Convert to USD using WAD decimals and add to total balance

## Market Operations

### Entry Process

1. User deposits USDC to Plasma Vault
2. Alpha role executes rebalancing
3. Funds distributed equally across vaults (for example: 25% each)
4. Each vault receives proportional share via ERC4626SupplyFuse

## Rewards

### Reward Types

-   **Main Rewards:** CRV, BAL, protocol-specific tokens
-   **Extra Rewards:** CVX, LDO, additional incentive tokens

### Claiming Process

```solidity
function claim(address[] vaults) external {
    claimMainRewards(vaults);
    claimExtraRewards(vaults);
}
```

## Substrates

Substrates are StakeDAO V2 reward vault addresses on Arbitrum:

### Supported Vaults

| Vault          | Reward Vault Address                         | LP Token Address                             | Underlying |
| -------------- | -------------------------------------------- | -------------------------------------------- | ---------- |
| LlamaLend WBTC | `0x1544E663DD326a6d853a0cc4ceEf0860eb82B287` | `0xe07f1151887b8FDC6800f737252f6b91b46b5865` | WBTC       |
| LlamaLend WETH | `0x2abaD3D0c104fE1C9A412431D070e73108B4eFF8` | `0xd3cA9BEc3e681b0f578FD87f20eBCf2B7e0bb739` | WETH       |
| LlamaLend EYWA | `0x555928DC8973F10f5bbA677d0EBB7cbac968e36A` | `0x747A547E48ee52491794b8eA01cd81fc5D59Ad84` | EYWA       |
| LlamaLend ARB  | `0x17E876675258DeE5A7b2e2e14FCFaB44F867896c` | `0xa6C2E6A83D594e862cDB349396856f7FFE9a979B` | ARB        |

### Configuration

```solidity
substrates = new bytes32[](4);
substrates[0] = bytes32(uint256(uint160(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WBTC)));
substrates[1] = bytes32(uint256(uint160(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_WETH)));
substrates[2] = bytes32(uint256(uint160(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_EYWA)));
substrates[3] = bytes32(uint256(uint160(STAKEDAO_V2_REWARD_VAULT_LLAMALEND_ARB)));
```

## Required Roles

-   `ATOMIST_ROLE`: Configure vaults and substrates
-   `ALPHA_ROLE`: Execute rebalancing operations
-   `FUSE_MANAGER_ROLE`: Add and configure fuses
-   `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE`: Configure price feeds

## Price Oracle Setup

Required price feeds for underlying assets:

```solidity
address constant CHAINLINK_PRICE_FEED_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
address constant CHAINLINK_PRICE_FEED_CRV_USD = 0x0a32255dd4BB6177C994bAAc73E0606fDD568f66;
```
