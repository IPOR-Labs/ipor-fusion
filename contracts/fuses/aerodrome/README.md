# Aerodrome Integration

## Overview

This module provides integration with [Aerodrome](https://aerodrome.finance/) - the native liquidity layer on Base chain, a fork of Velodrome V2.

**What Aerodrome does:**
Aerodrome is the central liquidity hub for the Base ecosystem. Users can provide liquidity to AMM pools (stable or volatile) to earn trading fees, and stake their LP tokens in gauges to earn AERO token emissions. The protocol uses a vote-escrow model where veAERO holders direct emissions to gauges.

## Responsibility Separation

### AerodromeBalanceFuse
Calculates the USD value of Plasma Vault positions:
- **Pool positions:** LP token value (based on reserves) + accumulated trading fees
- **Gauge positions:** LP token value only (staked LP tokens)

**Does NOT include:** AERO emission rewards

### RewardsManager + Reward Fuses
Handle all reward-related operations:
- `AerodromeGaugeClaimFuse` - claims AERO rewards from gauges
- `RewardsManager` - manages reward distribution and accounting

This separation allows for:
- Cleaner balance calculations (only principal + fees)
- Flexible reward handling strategies
- Independent reward claiming schedules

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            AERODROME PROTOCOL (Base)                         │
└─────────────────────────────────────────────────────────────────────────────┘

                              ┌─────────────────┐
                              │   PlasmaVault   │
                              └────────┬────────┘
                                       │
                     ┌─────────────────┴─────────────────┐
                     │                                   │
                     ▼                                   ▼
        ┌────────────────────────┐          ┌────────────────────────┐
        │     POOL POSITION      │          │    GAUGE POSITION      │
        │  (LP tokens in pool)   │          │ (LP tokens in gauge)   │
        └────────────────────────┘          └────────────────────────┘
                     │                                   │
         ┌───────────┴───────────┐           ┌──────────┴──────────┐
         │                       │           │                     │
         ▼                       ▼           ▼                     ▼
   ┌───────────┐          ┌───────────┐ ┌───────────┐       ┌───────────┐
   │ LIQUIDITY │          │  TRADING  │ │ LIQUIDITY │       │   AERO    │
   │   VALUE   │          │   FEES    │ │   VALUE   │       │ EMISSIONS │
   └───────────┘          └───────────┘ └───────────┘       └───────────┘
         │                       │           │                     │
         │  token0 + token1      │           │                     │
         │  proportional to      │           │                     │
         │  LP share             │           │                     │
         ▼                       ▼           ▼                     ▼
   ┌─────────────────────────────────┐ ┌─────────────────────────────────┐
   │         BalanceFuse             │ │       RewardsManager            │
   │  = LP Value + Trading Fees      │ │  (handles AERO separately)      │
   └─────────────────────────────────┘ └─────────────────────────────────┘
```

## Fee & Reward Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           FEE & REWARD DISTRIBUTION                          │
└─────────────────────────────────────────────────────────────────────────────┘

SCENARIO A: LP tokens held directly in Pool
─────────────────────────────────────────────

    Swaps happen
         │
         ▼
    ┌─────────┐     Trading Fees      ┌──────────────┐
    │  Pool   │ ───────────────────►  │ PlasmaVault  │  ✓ COUNTED IN BALANCE
    └─────────┘   (claimable0/1)      └──────────────┘
         │
         │ NO staking = NO emissions
         ▼
    ┌─────────┐
    │  AERO   │  ✗ NO EMISSIONS
    └─────────┘


SCENARIO B: LP tokens staked in Gauge
─────────────────────────────────────────────

    Swaps happen
         │
         ▼
    ┌─────────┐     Trading Fees      ┌──────────────────┐
    │  Pool   │ ───────────────────►  │ FeesVotingReward │ ──► veAERO Voters
    └─────────┘                       └──────────────────┘
                                              │
                                              │  ✗ NOT TO STAKERS!
                                              ▼
    ┌─────────┐      AERO Emissions   ┌──────────────┐
    │  Gauge  │ ───────────────────►  │ PlasmaVault  │  ✓ HANDLED BY RewardsManager
    └─────────┘       (earned)        └──────────────┘
                                              │
                                              │  ✗ NOT IN BALANCE FUSE!
                                              ▼
                                      ┌──────────────────┐
                                      │  RewardsManager  │
                                      │  + Claim Fuses   │
                                      └──────────────────┘
```

## Balance Calculation Summary

```
┌────────────────┬─────────────────────────┬─────────────────────────┐
│                │       POOL POSITION     │      GAUGE POSITION     │
├────────────────┼─────────────────────────┼─────────────────────────┤
│ LP Value       │  ✓ reserves/totalSupply │  ✓ reserves/totalSupply │
├────────────────┼─────────────────────────┼─────────────────────────┤
│ Trading Fees   │  ✓ claimable0/1 + delta │  ✗ (go to veAERO)       │
├────────────────┼─────────────────────────┼─────────────────────────┤
│ AERO Emissions │  ✗ (not staked)         │  ✗ (RewardsManager)     │
└────────────────┴─────────────────────────┴─────────────────────────┘
```

## Components

### Balance Fuse

| Contract | Purpose |
|----------|---------|
| `AerodromeBalanceFuse` | Calculates USD value of LP positions + trading fees (NO rewards) |

### Action Fuses

| Contract | Purpose |
|----------|---------|
| `AerodromeLiquidityFuse` | Add/remove liquidity to pools |
| `AerodromeGaugeFuse` | Stake/unstake LP tokens in gauges |
| `AerodromeClaimFeesFuse` | Claim trading fees from pools |

### Reward Fuses (handled by RewardsManager)

| Contract | Purpose |
|----------|---------|
| `AerodromeGaugeClaimFuse` | Claim AERO rewards from gauges |

### External Interfaces

| Interface | Description |
|-----------|-------------|
| `IPool` | Aerodrome AMM pool (token0, token1, reserves, fees) |
| `IGauge` | Gauge for staking LP tokens |
| `IRouter` | Router for adding/removing liquidity |

## Substrate Configuration

Substrates encode both the address and type (Pool vs Gauge):

```solidity
enum AerodromeSubstrateType {
    UNDEFINED,
    Gauge,
    Pool
}

struct AerodromeSubstrate {
    AerodromeSubstrateType substrateType;
    address substrateAddress;
}
```

### Encoding

```solidity
// Substrate = address | (type << 160)
bytes32 substrate = bytes32(uint256(uint160(address)) | (uint256(type) << 160));
```

## Usage Examples

### Add Liquidity to Pool

```solidity
AerodromeLiquidityFuseEnterData memory data = AerodromeLiquidityFuseEnterData({
    tokenA: USDC,
    tokenB: WETH,
    stable: false,           // volatile pool
    amountADesired: 1000e6,
    amountBDesired: 1e18,
    amountAMin: 990e6,       // 1% slippage
    amountBMin: 0.99e18,
    deadline: block.timestamp + 300
});
```

### Stake LP in Gauge

```solidity
AerodromeGaugeFuseEnterData memory data = AerodromeGaugeFuseEnterData({
    gaugeAddress: gauge,
    amount: lpBalance
});
```

### Claim Trading Fees (from Pool positions)

```solidity
AerodromeClaimFeesFuseEnterData memory data = AerodromeClaimFeesFuseEnterData({
    pools: [USDC_WETH_POOL]
});
```

### Claim Rewards (via RewardsManager)

```solidity
// AERO emissions from gauge - handled by RewardsManager
AerodromeGaugeClaimFuse(claimFuse).claim(gaugeAddress);
```

## Price Oracle Setup

Required price feeds:
- All pool underlying tokens (e.g., USDC/USD, WETH/USD)
- AERO/USD is **NOT required** for BalanceFuse (rewards not counted)

## Security Considerations

### Access Control
- Immutable market ID prevents configuration changes
- Substrate validation ensures only authorized pools/gauges are used
- Router address is immutable

### Token Safety
- Uses `SafeERC20` for all token operations
- `forceApprove` pattern with cleanup after operations
- Balance checks before operations

### Pool Validation
- Token address validation (non-zero)
- Substrate type validation
- Division by zero protection (totalSupply check)

## Network

- **Chain:** Base (Chain ID: 8453)
- **Aerodrome Router:** `0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43`
