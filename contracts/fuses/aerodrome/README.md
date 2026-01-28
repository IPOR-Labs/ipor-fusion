# Aerodrome Integration

This module provides integration with [Aerodrome](https://aerodrome.finance/) - the native liquidity layer on Base chain, a fork of Velodrome V2.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              PlasmaVault                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐  │
│  │AerodromeLiquidityFuse│  │  AerodromeGaugeFuse │  │AerodromeClaimFeesFuse│ │
│  │                     │  │                     │  │                     │  │
│  │ • Add liquidity     │  │ • Deposit to gauge  │  │ • Claim trading fees│  │
│  │ • Remove liquidity  │  │ • Withdraw from     │  │   from pools        │  │
│  │                     │  │   gauge             │  │                     │  │
│  └──────────┬──────────┘  └──────────┬──────────┘  └──────────┬──────────┘  │
│             │                        │                        │             │
│  ┌──────────┴────────────────────────┴────────────────────────┴──────────┐  │
│  │                      AerodromeBalanceFuse                             │  │
│  │  Calculates total USD value of:                                       │  │
│  │  • LP tokens held (Pool positions)                                    │  │
│  │  • Staked LP tokens (Gauge positions)                                 │  │
│  │  • Accumulated trading fees                                           │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Aerodrome Protocol (Base)                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────────────┐      ┌──────────────────────────┐            │
│  │          Pool            │      │          Gauge           │            │
│  │                          │      │                          │            │
│  │  • token0 / token1       │◄─────│  • stakingToken (Pool)   │            │
│  │  • reserves              │      │  • deposit / withdraw    │            │
│  │  • totalSupply           │      │  • getReward (AERO)      │            │
│  │  • claimable0/1 (fees)   │      │                          │            │
│  │  • index0/1 (fee index)  │      └──────────────────────────┘            │
│  │                          │                                              │
│  └──────────────────────────┘                                              │
│                                                                             │
│  ┌──────────────────────────┐                                              │
│  │         Router           │                                              │
│  │                          │                                              │
│  │  • addLiquidity          │                                              │
│  │  • removeLiquidity       │                                              │
│  │  • poolFor               │                                              │
│  └──────────────────────────┘                                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Fee vs Reward Distribution

Understanding the value flow is critical for correct balance calculation:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Value Flow Diagram                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│    TRADING FEES (0.3% per swap)              EMISSIONS (AERO tokens)        │
│           │                                          │                      │
│           ▼                                          ▼                      │
│    ┌─────────────┐                           ┌─────────────┐                │
│    │    Pool     │                           │    Gauge    │                │
│    │             │                           │             │                │
│    │  index0/1   │                           │  getReward  │                │
│    │ claimable0/1│                           │             │                │
│    └──────┬──────┘                           └──────┬──────┘                │
│           │                                         │                       │
│           ▼                                         ▼                       │
│    ┌─────────────┐                           ┌─────────────┐                │
│    │ LP Holders  │                           │   Stakers   │                │
│    │ (Pool pos.) │                           │ (Gauge pos.)│                │
│    └─────────────┘                           └─────────────┘                │
│                                                                             │
│    Pool positions:    Gauge positions:                                      │
│    ✓ Trading fees     ✓ AERO emissions                                      │
│    ✗ No emissions     ✗ Fees go to veAERO voters (not stakers)              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Key Points

1. **Pool Positions** (LP tokens held directly):
   - Receive trading fees proportionally
   - Fees tracked via `index0/index1` and `claimable0/claimable1`
   - No AERO emissions

2. **Gauge Positions** (LP tokens staked in gauge):
   - Receive AERO emissions via `getReward()`
   - Trading fees from gauges go to veAERO voters, NOT to stakers
   - Balance calculation includes staked LP value only

## Components

### AerodromeLiquidityFuse

Manages liquidity positions in Aerodrome pools.

**Operations:**
- `enter()` - Add liquidity to a pool, receive LP tokens
- `exit()` - Remove liquidity from a pool, receive underlying tokens

**Parameters:**
- `tokenA`, `tokenB` - Pool tokens
- `stable` - Pool type (stable vs volatile)
- `amountADesired/amountBDesired` - Desired token amounts
- `amountAMin/amountBMin` - Slippage protection
- `deadline` - Transaction deadline

### AerodromeGaugeFuse

Manages gauge staking for AERO emissions.

**Operations:**
- `enter()` - Deposit LP tokens into gauge
- `exit()` - Withdraw LP tokens from gauge

**Parameters:**
- `gaugeAddress` - Target gauge address
- `amount` - Amount of LP tokens to deposit/withdraw

### AerodromeClaimFeesFuse

Claims accumulated trading fees from pool positions.

**Operations:**
- `enter()` - Claim fees from one or more pools

**Parameters:**
- `pools` - Array of pool addresses to claim fees from

**Returns:**
- `totalClaimed0` - Total token0 fees claimed
- `totalClaimed1` - Total token1 fees claimed

### AerodromeBalanceFuse

Read-only fuse that calculates total USD value of all Aerodrome positions.

**Balance Calculation:**

For each substrate (Pool or Gauge):

1. **Liquidity Value** (when liquidity > 0):
   ```
   amount0 = (liquidity * reserve0) / totalSupply
   amount1 = (liquidity * reserve1) / totalSupply
   balanceUSD = amount0 * price0 + amount1 * price1
   ```

2. **Fee Value** (always calculated, even when liquidity = 0):
   ```
   delta0 = index0 - supplyIndex0
   delta1 = index1 - supplyIndex1

   claimable0 = pool.claimable0(vault) + (liquidity * delta0) / 1e18
   claimable1 = pool.claimable1(vault) + (liquidity * delta1) / 1e18

   feesUSD = claimable0 * price0 + claimable1 * price1
   ```

**Important:** Fee calculation runs even when `liquidity = 0` to capture unclaimed fees after LP withdrawal.

## Substrate Configuration

Substrates are encoded using `AerodromeSubstrateLib`:

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

Encoding: `bytes32 = address | (substrateType << 160)`

## External Interfaces

### IPool
```solidity
interface IPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint256, uint256, uint256);
    function totalSupply() external view returns (uint256);
    function index0() external view returns (uint256);
    function index1() external view returns (uint256);
    function supplyIndex0(address) external view returns (uint256);
    function supplyIndex1(address) external view returns (uint256);
    function claimable0(address) external view returns (uint256);
    function claimable1(address) external view returns (uint256);
    function claimFees() external returns (uint256, uint256);
}
```

### IGauge
```solidity
interface IGauge {
    function stakingToken() external view returns (address);
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward(address account) external;
    function balanceOf(address account) external view returns (uint256);
}
```

### IRouter
```solidity
interface IRouter {
    function addLiquidity(...) external returns (uint256, uint256, uint256);
    function removeLiquidity(...) external returns (uint256, uint256);
    function poolFor(address tokenA, address tokenB, bool stable, address factory)
        external view returns (address);
}
```

## Usage Example

```solidity
// 1. Add liquidity to get LP tokens
AerodromeLiquidityFuse.enter(AerodromeLiquidityFuseEnterData({
    tokenA: USDC,
    tokenB: WETH,
    stable: false,
    amountADesired: 1000e6,
    amountBDesired: 1e18,
    amountAMin: 990e6,
    amountBMin: 0.99e18,
    deadline: block.timestamp + 3600
}));

// 2. Stake LP tokens in gauge for AERO rewards
AerodromeGaugeFuse.enter(AerodromeGaugeFuseEnterData({
    gaugeAddress: USDC_WETH_GAUGE,
    amount: lpBalance
}));

// 3. Claim trading fees (for pool positions)
AerodromeClaimFeesFuse.enter(AerodromeClaimFeesFuseEnterData({
    pools: [USDC_WETH_POOL]
}));

// 4. Withdraw from gauge
AerodromeGaugeFuse.exit(AerodromeGaugeFuseExitData({
    gaugeAddress: USDC_WETH_GAUGE,
    amount: stakedBalance
}));

// 5. Remove liquidity
AerodromeLiquidityFuse.exit(AerodromeLiquidityFuseExitData({
    tokenA: USDC,
    tokenB: WETH,
    stable: false,
    liquidity: lpBalance,
    amountAMin: 0,
    amountBMin: 0,
    deadline: block.timestamp + 3600
}));
```

## Network

- **Chain:** Base (Chain ID: 8453)
- **Aerodrome Router:** `0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43`

## Related

- [Velodrome Superchain Integration](../velodrome_superchain/README.md) - Similar architecture for Optimism/Mode
