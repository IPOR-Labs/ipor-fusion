# Velodrome Superchain Integration

## Overview

Velodrome Superchain integration enables IPOR Fusion to interact with Velodrome V2 pools and gauges on Superchain networks (OP Stack L2s like Mode, Lisk, Fraxtal, etc.). This integration allows users to provide liquidity to Velodrome pools and stake LP tokens in gauges to earn VELO emission rewards.

**What Velodrome Superchain does:**
Velodrome is the central liquidity hub for the Superchain ecosystem. Users can provide liquidity to AMM pools (stable or volatile) to earn trading fees, and stake their LP tokens in gauges to earn VELO token emissions. The protocol uses a vote-escrow model where veVELO holders direct emissions to gauges.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         VELODROME SUPERCHAIN PROTOCOL                        │
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
   │ LIQUIDITY │          │  TRADING  │ │ LIQUIDITY │       │   VELO    │
   │   VALUE   │          │   FEES    │ │   VALUE   │       │ EMISSIONS │
   └───────────┘          └───────────┘ └───────────┘       └───────────┘
         │                       │           │                     │
         │  token0 + token1      │           │                     │ earned()
         │  proportional to      │           │                     │
         │  LP share             │           │                     │
         ▼                       ▼           ▼                     ▼
   ┌─────────────────────────────────┐ ┌─────────────────────────────────┐
   │         USD VALUE (Pool)        │ │        USD VALUE (Gauge)        │
   │  = LP Value + Trading Fees      │ │  = LP Value + VELO Rewards      │
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
    │  Pool   │ ───────────────────►  │ PlasmaVault  │  ✓ YOU GET FEES
    └─────────┘   (claimable0/1)      └──────────────┘
         │
         │ NO staking = NO emissions
         ▼
    ┌─────────┐
    │  VELO   │  ✗ NO EMISSIONS
    └─────────┘


SCENARIO B: LP tokens staked in Gauge
─────────────────────────────────────────────

    Swaps happen
         │
         ▼
    ┌─────────┐     Trading Fees      ┌──────────────────┐
    │  Pool   │ ───────────────────►  │ FeesVotingReward │ ──► veVELO Voters
    └─────────┘                       └──────────────────┘
                                              │
                                              │  ✗ NOT TO YOU!
                                              ▼
    ┌─────────┐      VELO Emissions   ┌──────────────┐
    │  Gauge  │ ───────────────────►  │ PlasmaVault  │  ✓ YOU GET EMISSIONS
    └─────────┘       (earned)        └──────────────┘
```

## Balance Calculation Summary

```
┌────────────────┬─────────────────────────┬─────────────────────────┐
│                │       POOL POSITION     │      GAUGE POSITION     │
├────────────────┼─────────────────────────┼─────────────────────────┤
│ LP Value       │  ✓ reserves/totalSupply │  ✓ reserves/totalSupply │
├────────────────┼─────────────────────────┼─────────────────────────┤
│ Trading Fees   │  ✓ claimable0/1 + delta │  ✗ (go to veVELO)       │
├────────────────┼─────────────────────────┼─────────────────────────┤
│ VELO Emissions │  ✗ (not staked)         │  ✓ earned()             │
└────────────────┴─────────────────────────┴─────────────────────────┘
```

## Components

### Fuses

| Contract | Purpose |
|----------|---------|
| `VelodromeSuperchainBalanceFuse` | Calculates total USD value of positions |
| `VelodromeSuperchainLiquidityFuse` | Add/remove liquidity to pools |
| `VelodromeSuperchainGaugeFuse` | Stake/unstake LP tokens in gauges |

### Reward Fuses

| Contract | Purpose |
|----------|---------|
| `VelodromeSuperchainGaugeClaimFuse` | Claim VELO rewards from gauges |

### External Interfaces

| Interface | Description |
|-----------|-------------|
| `IPool` | Velodrome AMM pool (token0, token1, reserves, fees) |
| `ILeafGauge` | Superchain gauge for staking LP tokens |
| `IRouter` | Router for adding/removing liquidity |

## Substrate Configuration

Substrates encode both the address and type (Pool vs Gauge):

```solidity
enum VelodromeSuperchainSubstrateType {
    UNDEFINED,
    Gauge,
    Pool
}

struct VelodromeSuperchainSubstrate {
    VelodromeSuperchainSubstrateType substrateType;
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
VelodromeSuperchainLiquidityFuseEnterData memory data = VelodromeSuperchainLiquidityFuseEnterData({
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
VelodromeSuperchainGaugeFuseEnterData memory data = VelodromeSuperchainGaugeFuseEnterData({
    gaugeAddress: gauge,
    amount: lpBalance,
    minAmount: lpBalance * 99 / 100  // 1% slippage
});
```

### Claim Rewards

```solidity
address[] memory gauges = new address[](1);
gauges[0] = gaugeAddress;
VelodromeSuperchainGaugeClaimFuse(claimFuse).claim(gauges);
```

## Price Oracle Setup

Required price feeds:
- All pool underlying tokens (e.g., USDC/USD, WETH/USD)
- VELO/USD (for emission rewards valuation)

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
- Liquidity amount validation

---

## Comparison with Other Integrations

### Standard Fuse Pattern

All IPOR Fusion protocol integrations follow the same pattern:

```
┌─────────────────────────────────────────────────────────────────┐
│                    STANDARD FUSE ARCHITECTURE                    │
└─────────────────────────────────────────────────────────────────┘

┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  Balance Fuse    │     │  Action Fuses    │     │  Claim Fuses     │
│                  │     │                  │     │                  │
│ balanceOf()      │     │ enter()          │     │ claim()          │
│ → USD value      │     │ exit()           │     │ → to RewardsMgr  │
└──────────────────┘     └──────────────────┘     └──────────────────┘
        │                        │                        │
        │                        │                        │
        ▼                        ▼                        ▼
┌─────────────────────────────────────────────────────────────────┐
│                         External Protocol                        │
│              (Velodrome, Aave, Morpho, Balancer, etc.)          │
└─────────────────────────────────────────────────────────────────┘
```

### Balance Fuse Patterns

| Protocol | Position Types | What's Counted |
|----------|---------------|----------------|
| **Velodrome Superchain** | Pool, Gauge | LP value + fees (Pool) / LP value + emissions (Gauge) |
| **Aerodrome** | Pool, Gauge | LP value + fees (Pool only) |
| **Aave V3** | Supply | aToken balance + interest |
| **Morpho** | Supply, Borrow | Supply balance - borrow balance |
| **Balancer** | Pool, Gauge | BPT value based on pool tokens |
| **Compound V3** | Supply | cToken balance + interest |

### Key Differences

1. **AMM protocols** (Velodrome, Aerodrome, Balancer):
   - Track LP token value + fees/rewards
   - Different fee distribution for staked vs unstaked positions

2. **Lending protocols** (Aave, Morpho, Compound):
   - Track supply/borrow positions
   - Interest accrues automatically

3. **Staking protocols** (Gauges, Convex, StakeDAO):
   - Track staked tokens + emission rewards
   - Rewards need explicit claiming
