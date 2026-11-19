# Balancer Integration

## Overview

Balancer integration enables IPOR Fusion to interact with Balancer V3 pools and liquidity gauges. This integration allows users to provide liquidity to Balancer pools and stake LP tokens in gauges to earn additional rewards, while maintaining a unified interface for liquidity management and yield optimization.

**What Balancer does:**
Balancer is a decentralized exchange (DEX) and automated market maker (AMM) that enables users to create and manage liquidity pools with custom token weights and fee structures. Users can provide liquidity to earn trading fees and stake their LP tokens in gauges to earn additional protocol rewards (BAL tokens) and other incentive tokens.

## Market Structure

The integration uses a single market for all operations:

-   **Market ID 36** (`BALANCER`) - All liquidity and gauge operations

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

### 1. BALANCER Market (Market ID: 36) - All Operations

Substrates of this market are typed: `bytes32(uint256(uint160(address)) | (uint256(type) << 160))` (`BalancerSubstrateLib.substrateToBytes32`), with the types `GAUGE` (1), `POOL` (2) and `TOKEN` (3). A plain address (type 0) matches no check of the action fuses and is skipped by the balance fuse. The type is the upper 96 bits of the value, converted to the enum `BalancerSubstrateType` by `bytes32ToSubstrate`, and the balance fuse converts it before its type branches and the zero-balance check. A value above 3 is not an enum member, so the conversion panics and `balanceOf()` reverts instead of skipping the entry; only type 0 is skipped.

-   **`POOL`**: the address of a Balancer V3 pool. In V3 the pool contract is also the BPT token, so the substrate carries the 20-byte pool address, not a 32-byte Balancer V2 pool id. Required by the three liquidity fuses; the balance fuse values the vault's directly held BPT of every granted pool. BPT is read only through this substrate.
-   **`GAUGE`**: the address of a liquidity gauge. Required by `BalancerGaugeFuse`; the balance fuse values the vault's gauge-token balance through the pool returned by the gauge's `lp_token()`, without requiring a `POOL` substrate for that pool. `BalancerGaugeFuse` requires only the `GAUGE` substrate and returns the BPT to the vault on withdrawal. Grant the matching `POOL` substrate together with every `GAUGE` substrate: without it, BPT unstaked from the gauge is not valued in market 36.
-   **`TOKEN`**: a pool token. Required for every token the vault pays into a pool and for the tokens it can receive on an exit: the output token of the single-token exit, and all tokens of the pool for the proportional and unbalanced exits.

#### Example pools and gauges (Balancer V3, Ethereum)

Examples of the address format only, not recommendations. State as read on the Balancer V3 Vault (`0xbA1333333333a1BA1108E8412f11850A5C319bA9`) at Ethereum block 26 433 356 (17 November 2026).

| Pool | Pool address (also the BPT) | Type | Pool tokens | Gauge | State at that block |
| --- | --- | --- | --- | --- | --- |
| Balancer Surge Fluid wstETH-wETH (used by `test/fuses/balancer/BalancerTest.t.sol`) | `0x6b31a94029fd7840d780191B6D63Fa0D269bd883` | Stable, StableSurge hook | fwstETH, fWETH (rate-bearing) | `0x1CCE9d493224A19FcB5f7fBade8478630141CB54` | paused, in recovery mode |
| Alchemix 80ALCX-20WETH | `0x1535D7CA00323Aa32BD62AEDdf7ca651e4b95966` | Weighted | WETH, ALCX | `0x2F534f93928B99A4759a5C6a75a61b34132a06ff` | paused, in recovery mode |
| Balancer rETH - Aave WETH | `0x1ea5870f7C037930CE1d5d8d9317c670e89e13E3` | Stable | waEthWETH, rETH (rate-bearing) | `0x62A66eB9aBf7a788F48D0ce7C0C065df9e09dA19` | not paused |

## Price Oracle Setup

### Required Price Feeds

The integration requires price feeds for all underlying pool tokens. Price feed configuration via `Price Oracle Middleware Manager` or `Price Oracle Middleware`

Generic examples of the feed format only. This is not the feed list for the example pools above: their tokens need feeds that price the pool token itself, including its rate, as described below.

-   price feed for pair: **WETH/USD**
-   price feed for pair: **USDC/USD**
-   price feed for pair: **WBTC/USD**
-   price feed for pair: **BAL/USD**

A feed is needed for every token of every granted `POOL` substrate and for every token of the pool returned by `lp_token()` of every granted `GAUGE` substrate, and it must price the pool token itself. For a rate-bearing pool token (an ERC-4626 wrapper, wstETH) the feed prices that token, including its rate: the balance fuse multiplies the pool's raw balance of the token by the token's own price, so the rate is applied once, by the feed.

A missing feed is not skipped. The price oracle middleware reverts with `UnsupportedAsset()`, so `balanceOf()` reverts, and with it every refresh of market 36, as soon as the vault holds a non-zero balance of the BPT (for a `POOL` substrate) or of the gauge token (for a `GAUGE` substrate); zero balances are skipped. BPT is a transferable ERC-20, so a third party can create that balance. Check the feeds of all pool tokens before granting a pool or gauge substrate; the fuses do not check this at grant time.

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
-   The balance fuse values a position from the pool's current balances; this does not protect against manipulation of those balances, see "Balance valuation: current pool balances, no oracle version (IL-9742)" below
-   View functions for balance calculations prevent state changes

### Balance valuation: current pool balances, no oracle version (IL-9742)

**What the fuse reports.** For every granted `POOL` or `GAUGE` substrate with a non-zero balance, `BalancerBalanceFuse` applies the vault's share of the BPT supply to the pool's current raw token balances (`balancesRaw` from `getTokenInfo()`) and converts the resulting token amounts to USD with the vault's price oracle middleware. This is a valuation at the pool's state at the moment of the call, not an oracle-derived value of the BPT.

**Spot-balance risk.** The pool's balances can be moved within a single transaction (a large swap, a flash loan) while the oracle prices stay unchanged. The reported value moves with them: a swap that pushes the pool away from the price implied by the oracle raises it, and nothing in the fuse bounds the move. A refresh of market 36 in that transaction stores the moved value in the vault's NAV. A holder who then redeems at a share price that is too high takes value from the remaining holders, and the performance fee can be charged on a gain that did not exist. A later correct refresh does not undo either.

**Pending yield fees.** `balancesRaw` are gross balances. For a pool token that pays yield fees they include the part of the accrued yield that the Balancer Vault has not collected yet; the Balancer V3 Vault's `getCurrentLiveBalances(pool)` returns balances net of it. The fourth return value of `getTokenInfo()` is only the last saved live balances, and the fuse uses `balancesRaw`, not either of those. For a pool in recovery mode the Vault does not deduct yield fees, so the difference is zero there. The fuse therefore overstates such a position by the pending fee. The amount is small for a pool that is used often and grows with the time since the pool's last operation.

**No oracle version.** The Uniswap V3, Uniswap V4 and Ramses V2 families have a second, oracle-derived balance fuse that the atomist can choose. This family has none: `BalancerBalanceFuse` is the only balance fuse of market 36. The risk is documented, not mitigated in code.

**State of Balancer V3 pools.** Read on Ethereum on 16 November 2026 (block 26 427 345): 21 of the 26 largest Balancer V3 pools that we read were paused and in recovery mode, across pool types and factory versions. The Balancer V3 Vault itself was not paused (also not on 17 November 2026, block 26 433 356). A paused pool rejects adding liquidity and every removal that the fuses of this family use: `removeLiquiditySingleTokenExactOut`, `removeLiquidityProportional` and `removeLiquidityCustom` revert with `PoolPaused`. Unstaking BPT from a gauge (the `BalancerGaugeFuse` exit, which calls the gauge's withdraw) still works on a paused pool, because BPT transfers are not blocked by the pool pause; redeeming BPT for pool tokens does not. The recovery exit `removeLiquidityRecovery` is not blocked by the pause, but no fuse of this family calls it. A vault that holds BPT of a pool that gets paused cannot redeem that position for pool tokens with these fuses, while the balance fuse keeps reporting a value for it.

**Guidance for atomists.**

1. Do not grant market 36 substrates (pools or gauges) to a new vault: the only balance fuse of the market is a spot valuation, and a position in a pool that gets paused cannot be redeemed for pool tokens with these fuses.
2. On a vault that already holds a Balancer position, keep market 36 out of every refresh that an account other than the keeper or the alpha can trigger: no balance-refreshing pre-hook that covers market 36 on a selector that users can call, no dependency-graph edge to market 36 from a market that a user operation refreshes, and `updateMarketsBalances` held by trusted operators only. This is the rule written for market 11 in "Pre-hooks and vaults with a live EulerSwap pool (IL-9331)" of the [vaults README](../../vaults/README.md#pre-hooks-and-vaults-with-a-live-eulerswap-pool-il-9331); it applies here for the same reason. The keeper's or the alpha's own refresh is a public transaction that can be sandwiched, so submit it privately.
3. Before any operation on a pool, read `isPoolPaused(pool)` and `isPoolInRecoveryMode(pool)` on the Balancer V3 Vault, and `isVaultPaused()`.
4. A deep pool raises the cost of moving the balances but does not remove the risk.

Status: known limitation, documented, no code change (owner decision). The fuses check none of the above; configuration is the only control.

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
