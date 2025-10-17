# Yield Basis Integration

## Overview

Yield Basis integration enables IPOR Fusion to interact with Yield Basis leveraged liquidity token (LT) vaults, providing 2x leveraged yield farming opportunities while maintaining optimal debt-to-collateral ratios.

**What Yield Basis does:**
Yield Basis creates leveraged liquidity tokens (LT) that automatically manage debt positions. Users deposit assets (BTC, ETH) and receive leveraged exposure to yield-generating strategies with 2x leverage through sophisticated AMM mechanisms.

**Key Protocol Advantages:**

-   **Automated Debt Management**: AMM mechanisms maintain optimal 2x leverage ratios automatically
-   **Built-in Safety**: Protocol-enforced limits prevent over-leveraging and liquidation risks
-   **Advanced AMM Design**: Custom implementation optimized for leveraged positions with superior capital efficiency
-   **Emergency Withdrawal**: Built-in crisis exit mechanisms with proper debt adjustment
-   **MEV Protection**: Integrated sandwich attack protection through minimum parameters

## Market Structure

-   **Market ID 37** (`YIELD_BASIS_LT`) - Supply/withdrawal operations

## Architecture

### Vault Structure

```
Yield Basis LT Token (Leveraged Liquidity Token)
├── Underlying Asset (e.g., WBTC, WETH)
└── Debt Position (USD stablecoin, 18 decimals)
```

### Key Components

-   **`YieldBasisLtBalanceFuse`**: Tracks total USD value of LT token holdings
-   **`YieldBasisLtSupplyFuse`**: Handles deposits/withdrawals with proportional debt adjustment

## Balance Management

### Balance Calculation Process

1. **Get LT balance**: Retrieve Plasma Vault's balance in LT tokens
2. **Convert to assets**: Convert LT shares to underlying asset amount using `pricePerShare()`
3. **Get asset price**: Retrieve underlying asset price from price oracle
4. **Calculate USD value**: Convert to USD using WAD decimals and add to total balance

## Substrates

### Configuration

Substrates are configured as **LT token addresses** for Market ID 37.

| Asset | LT Token Address | Underlying Asset | Leverage |
| ----- | ---------------- | ---------------- | -------- |
| WBTC  | `0x...`          | WBTC             | 2x       |
| WETH  | `0x...`          | WETH             | 2x       |

### Setup Process

1. Deploy `YieldBasisLtSupplyFuse` and `YieldBasisLtBalanceFuse` with Market ID 37
2. Add fuses to Plasma Vault governance
3. Grant market substrates (LT token addresses) via governance
4. Configure price feeds for underlying assets

## Price Feeds

### Required Configuration

Price feeds must be configured for **all underlying assets** of LT tokens via Price Oracle Middleware.

**Required Price Feeds:**

-   **WBTC/USD**: For WBTC underlying asset
-   **WETH/USD**: For WETH underlying asset

### Price Feed Integration

The balance fuse calls `IPriceOracleMiddleware.getAssetPrice(lt.ASSET_TOKEN())` to get:

-   Asset price in USD
-   Price decimals for proper scaling

**Critical:** Price feeds must be configured for the exact asset addresses returned by `IYieldBasisLT.ASSET_TOKEN()`.

## Leverage Mechanism

### 2x Leverage System

-   **Target Leverage**: 2x (debt = ~50% of collateral value)
-   **Debt Format**: USD stablecoin with 18 decimals
-   **Collateral**: Native asset (BTC, ETH, etc.)

### Mathematical Foundation

```vyper
# debt in equilibrium = coll_value * (LEVERAGE - 1.0) / LEVERAGE
# For 2x leverage: debt = coll_value * 0.5
```

Where:

-   `coll_value` = collateral_amount × asset_price
-   `debt` = USD amount in stablecoin (18 decimals)

## Safety Mechanisms

### Leverage Limits

-   **Minimum Safe Debt**: `coll_value * MIN_SAFE_DEBT`
-   **Maximum Safe Debt**: `coll_value * MAX_SAFE_DEBT`
-   **Equilibrium Debt**: `coll_value * 0.5` (for 2x leverage)

### Risk Management

-   **Proportional Debt Adjustment**: Maintains correct leverage when deposits are reduced
-   **Price Oracle Integration**: Ensures accurate USD value calculations
-   **Instant Withdrawal**: Supports emergency liquidity needs
