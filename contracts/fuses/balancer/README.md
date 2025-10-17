# Balancer Integration

## Overview

Balancer integration enables IPOR Fusion to interact with Balancer V3 pools and liquidity gauges. This integration allows users to provide liquidity to Balancer pools and stake LP tokens in gauges to earn additional rewards, while maintaining a unified interface for liquidity management and yield optimization.

**What Balancer does:**
Balancer is a decentralized exchange (DEX) and automated market maker (AMM) that enables users to create and manage liquidity pools with custom token weights and fee structures. Users can provide liquidity to earn trading fees and stake their LP tokens in gauges to earn additional protocol rewards (BAL tokens) and other incentive tokens.

## Market Structure

The integration uses a single market for all operations:

-   **Market ID 35** (`BALANCER`) - All liquidity and gauge operations

## Architecture

### Pool Structure

Balancer follows a flexible pool structure with BPT (Balancer Pool Token) as the LP token:

```
Balancer Pool
├── BPT Token (Balancer Pool Token)
    └── Underlying Assets (e.g., WETH, USDC, WBTC, etc.)
```

### Gauge System

Balancer pools can be staked in liquidity gauges to earn additional rewards:

```
Balancer Gauge
├── Staked BPT Tokens
    └── Earns BAL + Additional Rewards
```

### Key Components

-   **`BalancerBalanceFuse`**: Tracks total USD value across all configured pools and gauges
-   **`BalancerSingleTokenFuse`**: Handles single-token deposits and withdrawals from pools
-   **`BalancerLiquidityProportionalFuse`**: Manages proportional liquidity operations
-   **`BalancerLiquidityUnbalancedFuse`**: Handles custom/unbalanced liquidity operations
-   **`BalancerGaugeFuse`**: Manages staking and unstaking of BPT tokens in gauges

## Balance Calculation

The balance calculation follows a multi-step process for each configured pool or gauge:

1. **Get LP balance**: Retrieve Plasma Vault's balance in BPT tokens or gauge tokens
2. **Convert to underlying**: Calculate proportional amounts of underlying tokens from BPT holdings
3. **Get prices**: Retrieve underlying asset prices from price oracle
4. **Calculate USD value**: Convert to USD using WAD decimals and add to total balance

### Important Notes

-   Balancer pools use BPT (Balancer Pool Token) as the LP token
-   Proportional calculations are based on current pool balances and total supply
-   Gauge positions are tracked separately from pool positions
-   **Pool Operations**: Direct interaction with Balancer pools for liquidity provision
-   **Gauge Operations**: Staking BPT tokens in gauges to earn additional rewards

## Liquidity Operations

### Operation Types

1. **Single Token Operations**: Deposit/withdraw using a single token
2. **Proportional Operations**: Deposit/withdraw maintaining pool proportions
3. **Unbalanced Operations**: Custom token amounts for deposits/withdrawals
4. **Gauge Operations**: Stake/unstake BPT tokens in gauges

### Key Features

-   **Permit2 Integration**: Gas-efficient token approvals using Permit2
-   **Substrate Validation**: Ensures only authorized pools/gauges are used
-   **Flexible Liquidity**: Support for various liquidity provision strategies
-   **Reward Optimization**: Gauge staking for additional yield

## Substrate Configuration

### 1. BALANCER Market (Market ID: 35) - All Operations

For all operations, substrates are configured as **pool addresses** or **gauge addresses**.

#### Pool examples on Arbitrum:

| Pool Name      | Pool Address                                                         | Token 1 | Token 2 | Token 3 | Pool Type     |
| -------------- | -------------------------------------------------------------------- | ------- | ------- | ------- | ------------- |
| WETH/USDC      | `0x5c6ee304399dbdb9c8ef030ab642b10820db8f56000200000000000000000014` | WETH    | USDC    | -       | Weighted Pool |
| WETH/WBTC/USDC | `0x64541216bafffeec8ea53571b73d7d4f4b4af7bd000000000000000000000000` | WETH    | WBTC    | USDC    | Weighted Pool |
| BAL/WETH       | `0x5c6ee304399dbdb9c8ef030ab642b10820db8f56000200000000000000000014` | BAL     | WETH    | -       | Weighted Pool |

#### Gauge examples on Arbitrum:

| Gauge Name           | Gauge Address | LP Token           | Rewards          |
| -------------------- | ------------- | ------------------ | ---------------- |
| WETH/USDC Gauge      | `0x...`       | WETH/USDC BPT      | BAL + Additional |
| WETH/WBTC/USDC Gauge | `0x...`       | WETH/WBTC/USDC BPT | BAL + Additional |

## Price Oracle Setup

### Required Price Feeds

The integration requires price feeds for all underlying pool tokens. Price feed configuration via `Price Oracle Middleware Manager` or `Price Oracle Middleware`

Example:

-   price feed for pair: **WETH/USD**
-   price feed for pair: **USDC/USD**
-   price feed for pair: **WBTC/USD**
-   price feed for pair: **BAL/USD**

## Security Considerations

### Access Control

-   Immutable market ID and router addresses prevent configuration changes
-   Substrate validation ensures only authorized pools/gauges are accessible
-   Input validation prevents zero addresses and invalid parameters

### Token Safety

-   Uses SafeERC20 for secure token operations
-   Automatic approval cleanup after operations
-   Permit2 integration reduces gas costs and approval risks

### Pool Validation

-   Token validation ensures only pool-registered tokens are used
-   Proportional calculations prevent manipulation attacks
-   View functions for balance calculations prevent state changes

## Usage Patterns

### Single Token Liquidity

```solidity
// Enter with single token
BalancerSingleTokenFuseEnterData memory enterData = BalancerSingleTokenFuseEnterData({
    pool: poolAddress,
    tokenIn: tokenAddress,
    maxAmountIn: amount,
    exactBptAmountOut: minBptOut
});
```

### Proportional Liquidity

```solidity
// Enter proportionally
BalancerLiquidityProportionalFuseEnterData memory enterData = BalancerLiquidityProportionalFuseEnterData({
    pool: poolAddress,
    tokens: [token1, token2],
    maxAmountsIn: [amount1, amount2],
    exactBptAmountOut: minBptOut
});
```

### Gauge Staking

```solidity
// Stake in gauge
BalancerGaugeFuseEnterData memory enterData = BalancerGaugeFuseEnterData({
    gaugeAddress: gaugeAddress,
    bptAmount: amount,
    minBptAmount: minAmount
});
```
