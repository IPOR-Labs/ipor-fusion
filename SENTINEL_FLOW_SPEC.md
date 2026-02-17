# Sentinel Strategy — PlasmaVault Flow Specification

## Overview

Flow for Simone Chiarello's Sentinel strategy on Ethereum mainnet.
The strategy deposits rETH as collateral, borrows BOLD, provides liquidity to Curve USDC/BOLD pool, and stakes LP tokens in Curve gauge for rewards.

## Full Pipeline (4 Steps)

```
rETH (collateral)
   │
   ▼  [Step 1] Ebisu / Liquity v2 — Open/Adjust Trove
   │  Deposit rETH as collateral → Borrow BOLD
   │  Fuses: EbisuZapperCreateFuse / EbisuAdjustTroveFuse
   │
BOLD token
   │
   ▼  [Step 2] Curve StableswapNG — Add Liquidity (single-side)
   │  Deposit BOLD → USDC/BOLD Curve pool → LP token
   │  Fuse: CurveStableswapNGSingleSideSupplyFuse
   │
Curve LP token (USDC/BOLD pool)
   │
   ▼  [Step 3] Curve Gauge — Stake LP
   │  Deposit LP token into gauge 0x07a01471...
   │  Fuse: CurveLiquidityGaugeV6SupplyFuse (NEW — V6 withdraw signature)
   │
Gauge receipt (staked LP)
   │
   ▼  [Step 4] Claim Rewards
   │  Claim CRV + other reward tokens from gauge
   │  Fuse: CurveGaugeTokenClaimFuse (ABI-compatible with V6)
```

## Key Addresses (Ethereum Mainnet)

| Contract | Address |
|----------|---------|
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| BOLD | `0x6440f144b7e50D6a8439336510312d2F54beB01D` |
| Curve Pool (BOLD/USDC) | `0xEFc6516323FbD28e80B85A497B65A86243a54B3E` |
| Curve Gauge (LiquidityGaugeV6) | `0x07a01471fA544D9C6531B631E6A96A79a9AD05E9` |
| Chainlink USDC/USD | `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6` |

## New Fuses (this PR)

| File | Description |
|------|-------------|
| `contracts/fuses/curve_gauge/ext/ILiquidityGaugeV6.sol` | Interface for mainnet Curve gauges — `withdraw(uint256, bool)` vs `withdraw(uint256, address, bool)` |
| `contracts/fuses/curve_gauge/CurveLiquidityGaugeV6SupplyFuse.sol` | Supply fuse using V6 withdraw signature |
| `contracts/fuses/curve_gauge/CurveLiquidityGaugeV6BalanceFuse.sol` | Balance fuse with pro-rata valuation (no `calc_withdraw_one_coin`) |

## Existing Fuses in Codebase

| Step | Fuse | File | Status |
|------|------|------|--------|
| 1. Open Trove | `EbisuZapperCreateFuse` | `contracts/fuses/ebisu/EbisuZapperCreateFuse.sol` | Ready |
| 1. Adjust Trove | `EbisuAdjustTroveFuse` | `contracts/fuses/ebisu/EbisuAdjustTroveFuse.sol` | Ready |
| 1. Lever Up/Down | `EbisuZapperLeverModifyFuse` | `contracts/fuses/ebisu/EbisuZapperLeverModifyFuse.sol` | Ready |
| 1. Adjust Interest | `EbisuAdjustInterestRateFuse` | `contracts/fuses/ebisu/EbisuAdjustInterestRateFuse.sol` | Ready |
| 1. Balance | `EbisuZapperBalanceFuse` | `contracts/fuses/ebisu/EbisuZapperBalanceFuse.sol` | Ready |
| 2. Add LP | `CurveStableswapNGSingleSideSupplyFuse` | `contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideSupplyFuse.sol` | Ready |
| 2. Balance | `CurveStableswapNGSingleSideBalanceFuse` | `contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideBalanceFuse.sol` | Ready |
| 3. Stake in gauge | `CurveLiquidityGaugeV6SupplyFuse` | `contracts/fuses/curve_gauge/CurveLiquidityGaugeV6SupplyFuse.sol` | **NEW** |
| 3. Balance | `CurveLiquidityGaugeV6BalanceFuse` | `contracts/fuses/curve_gauge/CurveLiquidityGaugeV6BalanceFuse.sol` | **NEW** (pro-rata) |
| 4. Claim rewards | `CurveGaugeTokenClaimFuse` | `contracts/rewards_fuses/curve_gauges/CurveGaugeTokenClaimFuse.sol` | Ready (ABI-compatible) |

## Why New Fuses?

### Supply Fuse
The mainnet gauge (`0x07a0...`) is **LiquidityGaugeV6** with `withdraw(uint256, bool)` (2 params).
The existing `CurveChildLiquidityGaugeSupplyFuse` uses `IChildLiquidityGauge.withdraw(uint256, address, bool)` (3 params).
The exit call would fail on mainnet.

### Balance Fuse
The existing `CurveChildLiquidityGaugeBalanceFuse` uses `calc_withdraw_one_coin` which is vulnerable to price manipulation.
The new `CurveLiquidityGaugeV6BalanceFuse` uses pro-rata valuation (pattern from `CurveStableswapNGSingleSideBalanceFuse`):
```
For each gauge substrate:
  stakedBalance = gauge.balanceOf(plasmaVault)
  lpToken = gauge.lp_token()
  totalSupply = pool.totalSupply()
  for each coin j in pool:
    coinAmount = pool.balances(j) * stakedBalance / totalSupply
    balance += convertToWad(coinAmount * coinPrice, decimals)
```

## Integration Test

`test/integrationTest/sentinelFlowEthereum/SentinelUsdcBoldCurveGaugeEthereum.t.sol`

Fork test on Ethereum mainnet (block 24475332) demonstrating full flow:
1. Deposit USDC into vault
2. `deal(BOLD)` — simulate having BOLD (skip Ebisu trove creation)
3. Add BOLD liquidity to Curve pool → LP tokens
4. Stake LP tokens into V6 gauge
5. `vm.warp(30 days)` + claim rewards
6. Unstake LP tokens from gauge
7. Remove liquidity → BOLD

## Reverse Flow (Unwinding)

```
Gauge receipt (staked LP)
   │
   ▼  [Step 1] Unstake from gauge
   │  CurveLiquidityGaugeV6SupplyFuse.exit()
   │
Curve LP token
   │
   ▼  [Step 2] Remove liquidity from Curve
   │  CurveStableswapNGSingleSideSupplyFuse.exit()
   │
BOLD token
   │
   ▼  [Step 3] Repay BOLD + close/adjust trove
   │  EbisuAdjustTroveFuse (reduce debt) or close trove
   │
rETH (returned collateral)
```
