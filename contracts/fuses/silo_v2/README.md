# Silo V2 Integration

## Overview

Silo V2 integration enables IPOR Fusion to interact with Silo V2 lending protocol through risk-isolated markets. This integration allows users to supply assets as collateral (both borrowable and non-borrowable) and borrow assets from the protocol, while maintaining proper balance tracking across different asset types and share tokens.

**What Silo V2 does:**
Silo V2 is a lending protocol based on risk-isolated markets (silos) with default two-asset pairs (base asset + bridge asset). This design isolates exposures and liquidations per market, preventing risk mixing between unrelated assets. Each market consists of two silos (silo0 and silo1) containing different assets, where users can supply assets as either protected (non-borrowable) collateral or regular (borrowable) collateral, and borrow assets against their collateral.

## Market Structure

The integration uses a single market for all operations:

-   **Market ID 32** (`SILO_V2`) - Supply/withdrawal/borrow/repay operations

## Architecture

### Silo Architecture

Silo V2 follows a risk-isolated market structure:

```
SiloConfig (Risk-Isolated Market)
├── Silo0 (Base Asset - e.g., WETH)
│   ├── Protected Share Token (non-borrowable collateral)
│   ├── Collateral Share Token (borrowable collateral)
│   └── Debt Share Token (borrowed assets)
└── Silo1 (Bridge Asset - e.g., USDC)
    ├── Protected Share Token (non-borrowable collateral)
    ├── Collateral Share Token (borrowable collateral)
    └── Debt Share Token (borrowed assets)
```

**Key Design Principles:**

-   **Risk Isolation**: Each market (SiloConfig) isolates risk between its two assets
-   **Bridge Assets**: Connect markets but don't mix risk between unrelated assets
-   **Liquidation Isolation**: Liquidations are contained within each market

### Key Components

-   **`SiloV2BalanceFuse`**: Tracks total USD value across all configured silos, accounting for collateral and debt
-   **`SiloV2SupplyBorrowableCollateralFuse`**: Handles deposits and withdrawals of borrowable collateral
-   **`SiloV2SupplyNonBorrowableCollateralFuse`**: Handles deposits and withdrawals of protected (non-borrowable) collateral
-   **`SiloV2BorrowFuse`**: Manages borrowing and repaying assets

## Balance Calculation

The balance calculation follows a multi-step process for each configured silo:

1. **Get share token balances**: Retrieve Plasma Vault's balance in each share token type
2. **Convert to assets**: Convert share token balances to underlying asset amounts using `convertToAssets()`
3. **Calculate net balance**:
    - Add protected and collateral assets (gross assets)
    - Subtract debt assets
    - Net balance = max(0, gross assets - debt assets)
4. **Get price**: Retrieve underlying asset price from price oracle
5. **Calculate USD value**: Convert to USD using WAD decimals and add to total balance

### Important Notes

-   **Protected Share Tokens**: Represent non-borrowable collateral deposits
-   **Collateral Share Tokens**: Represent borrowable collateral deposits
-   **Debt Share Tokens**: Represent borrowed assets (subtracted from balance)
-   Each silo can contain different underlying assets
-   Balance calculation accounts for both collateral and debt positions

## Asset Types and Share Tokens

### Share Token Types

-   **Protected Share Token**: Tracks non-borrowable collateral deposits
-   **Collateral Share Token**: Tracks borrowable collateral deposits
-   **Debt Share Token**: Tracks borrowed assets

### Asset Types

-   **Protected**: Non-borrowable collateral (earns yield but cannot be used for borrowing)
-   **Collateral**: Borrowable collateral (can be used as collateral for borrowing)
-   **Debt**: Borrowed assets (creates debt position)

## Operations

### Supply Operations

-   **Borrowable Collateral**: Users can supply assets as collateral that can be used for borrowing
-   **Non-Borrowable Collateral**: Users can supply assets as protected collateral that earns yield but cannot be borrowed against

### Borrow Operations

-   **Borrow**: Users can borrow assets against their collateral
-   **Repay**: Users can repay borrowed assets to reduce their debt position

## Substrate Configuration

### 1. SILO_V2 Market (Market ID: 32) - Supply/Withdrawal/Borrow/Repay Operations

For all operations, substrates are configured as **SiloConfig contract addresses** representing risk-isolated markets.

#### SiloConfig Structure:

Each SiloConfig represents a risk-isolated market managing:

-   **Silo0**: Base asset silo (e.g., WETH, WBTC)
-   **Silo1**: Bridge asset silo (e.g., USDC, USDT)
-   **Share Tokens**: Three share token types per silo (protected, collateral, debt)
-   **Oracle Integration**: Chainlink/DIA/RedStone/Uniswap v3 price feeds
-   **Risk Parameters**: LTV, liquidation thresholds, solvency checks

#### Example Configuration:

**Real-world example on Ethereum Mainnet:**

```
SiloConfig Address: 0xeC7C5CAaEA12A1a6952F3a3D0e3ca5B678433934 (weETH/wETH Market)
├── Silo ID: 105
├── Silo0: 0xDb81E17B5CE19e9B2F64B378F98d88E4Ca6726E7 (weETH silo)
│   ├── Protected Share Token: 0x2791A35E81C5a5D7a5287a28Bbd6263Ba9CE7Ff2 (Non-borrowable weETH Deposit)
│   ├── Collateral Share Token: 0xDb81E17B5CE19e9B2F64B378F98d88E4Ca6726E7 (Borrowable weETH Deposit)
│   └── Debt Share Token: 0xDFC782FeA37645E68c20646AaCE73951B2817516 (weETH Debt)
└── Silo1: 0x160287E2D3fdCDE9E91317982fc1Cc01C1f94085 (wETH silo)
    ├── Protected Share Token: 0x84851b559B05FD33cbad5087dF531f5ea0be7aFc (Non-borrowable wETH Deposit)
    ├── Collateral Share Token: 0x160287E2D3fdCDE9E91317982fc1Cc01C1f94085 (Borrowable wETH Deposit)
    └── Debt Share Token: 0x0a437aB5Cb5fE60ed4aE827D54bD0e5753f46Acb (wETH Debt)
```

**Configuration Details:**

-   **SiloConfig.SILO_ID**: 105
-   **Assets**: weETH (Wrapped Ether with staking rewards) and wETH (Wrapped Ether)
-   **Market Type**: Two-asset market with risk isolation between weETH and wETH
-   **Share Token Naming**: Each share token includes the asset name, deposit type, and Silo ID

**How to Use This Configuration:**

1. **Add SiloConfig as Substrate**: Configure `0xeC7C5CAaEA12A1a6952F3a3D0e3ca5B678433934` as a substrate in Market ID 32
2. **Supply Operations**: Use either Silo0 or Silo1 addresses for supply/withdraw operations
3. **Balance Tracking**: The system automatically tracks all 6 share tokens (3 per silo) for accurate balance calculation
4. **Borrow Operations**: Can borrow weETH from either silo against collateral in the other silo

**Share Token Types Explained:**

-   **Protected Share Tokens**: Non-borrowable deposits that earn yield but cannot be used as collateral
-   **Collateral Share Tokens**: Borrowable deposits that can be used as collateral for borrowing
-   **Debt Share Tokens**: Represent borrowed assets (subtracted from net balance)

#### Risk Management Features:

-   **Oracle Integration**: Dual oracle checks (solvency vs maxLTV)
-   **Health Factor Monitoring**: Real-time position health tracking
-   **Liquidation Isolation**: Liquidations contained within each market
-   **Bridge Asset Safety**: Bridge assets connect markets without risk mixing

## Important Considerations

### Key Architectural Differences

-   **Silo V2 ≠ Simple Vault**: Silo V2 is a lending protocol with risk-isolated markets, not a simple vault system
-   **Market vs Vault**: Each SiloConfig represents a risk-isolated market (two-asset pair), not a vault
-   **Risk Isolation**: Exposures and liquidations are isolated per market, preventing risk mixing between unrelated assets
-   **Bridge Assets**: Connect markets but maintain risk separation

### Operational Constraints

-   **Oracle Dependencies**: Each market requires reliable price feeds for both assets
-   **Health Factor Monitoring**: Positions must maintain healthy collateralization ratios
-   **Liquidation Risk**: Positions can be liquidated if health factor drops below threshold
-   **Asset-Specific Limits**: Each market has its own LTV and liquidation parameters

## Price Oracle Setup

### Required Price Feeds

The integration requires price feeds for **all silo underlying assets**. Based on the `SiloV2BalanceFuse` implementation, the system calls `IPriceOracleMiddleware.getAssetPrice(siloAssetAddress)` for each silo's underlying asset.

**Critical Configuration Requirements:**

1. **Silo Underlying Assets**: Each silo has an underlying asset (e.g., WETH, USDC, weETH) that must be configured in the Price Manager
2. **Asset Address Mapping**: The price oracle must have price feeds configured for the exact asset addresses returned by `ISilo(silo).asset()`
3. **Price Feed Format**: Prices must be returned in the format expected by `IPriceOracleMiddleware.getAssetPrice()`

**Supported Oracle Types:**

-   Chainlink
-   DIA
-   RedStone
-   Uniswap v3
-   Custom oracles

**Dual Oracle Checks:**

-   **Solvency Oracle**: For liquidation calculations
-   **MaxLTV Oracle**: For borrowing limits

### Example Configuration for weETH/wETH Market

For the weETH/wETH market example (SiloConfig: `0xeC7C5CAaEA12A1a6952F3a3D0e3ca5B678433934`):

**Required Price Feeds:**

-   **weETH/USD**: Price feed for the weETH token address (underlying asset of Silo0)
-   **wETH/USD**: Price feed for the wETH token address (underlying asset of Silo1)
-   **Price Feed Addresses**: Must be configured in Price Manager for the exact weETH and wETH token addresses

**Configuration Steps:**

1. Identify the underlying asset address by calling `ISilo(siloAddress).asset()` for each silo
2. Configure price feed in Price Manager for each unique underlying asset address
3. Ensure price feeds return prices in the expected format with proper decimals

**Balance Calculation Process:**

1. For each SiloConfig, get both silo addresses (silo0, silo1)
2. For each silo, get the underlying asset address via `ISilo(silo).asset()`
3. Query price oracle for the underlying asset price
4. Convert share token balances to underlying asset amounts
5. Calculate USD value using the price feed
6. Sum all silo balances for total market balance

**Important Notes:**

-   The system queries prices for **underlying assets**, not share tokens
-   Each silo in a market typically has different underlying assets (as in the weETH/wETH example)
-   Price feeds must be configured for the exact token addresses returned by the silo contracts
-   Missing price feeds will cause balance calculation failures
-   Both assets in the market require separate price feed configurations
