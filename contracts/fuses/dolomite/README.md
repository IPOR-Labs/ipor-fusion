# Dolomite Integration

## Overview

Dolomite integration enables IPOR Fusion to interact with Dolomite protocol on Arbitrum. This integration allows users to supply assets, borrow against collateral, manage positions across sub-accounts, and enable E-mode for higher capital efficiency.

**What Dolomite does:**
Dolomite is a decentralized margin trading and lending protocol that uses a unique sub-account system. Each address can have up to 256 isolated margin accounts (numbered 0-255), enabling sophisticated position management, risk isolation, and cross-collateralization strategies.

## Market Structure

The integration uses a single market for all operations:

-   **Market ID 46** (`DOLOMITE`) - Supply/withdraw/borrow/repay/collateral/E-mode operations

## Architecture

### Sub-Account System

Dolomite uses a unique sub-account architecture:

```
PlasmaVault (owner address)
├── Sub-account 0 (default)
│   ├── USDC: +5000 (supply)
│   └── WETH: -0.5 (debt)
├── Sub-account 1 (isolated position)
│   ├── WETH: +2.0 (collateral)
│   └── USDC: -1000 (debt)
└── Sub-account 2..255 (additional isolated positions)
```

**Key Design Principles:**

-   **Position Isolation**: Each sub-account maintains independent positions and risk
-   **Signed Balances**: Positive = supply, Negative = debt (borrow)
-   **Cross-Sub-Account Transfers**: Internal transfers without external token movements
-   **E-mode Support**: Higher LTV ratios for correlated asset pairs

### Key Components

-   **`DolomiteSupplyFuse`**: Handles deposits and withdrawals via DepositWithdrawalRouter
-   **`DolomiteBorrowFuse`**: Manages borrowing and repaying via DolomiteMargin.operate()
-   **`DolomiteCollateralFuse`**: Transfers collateral between sub-accounts
-   **`DolomiteEModeFuse`**: Enables/disables E-mode for higher capital efficiency
-   **`DolomiteBalanceFuse`**: Tracks total USD value across all configured substrates
-   **`DolomiteFuseLib`**: Utility library for substrate encoding and permission checks

## Balance Calculation

The balance calculation aggregates positions across all configured substrates:

1. **Get substrates**: Retrieve all configured (asset, subAccountId, canBorrow) tuples
2. **Query Dolomite**: For each substrate, call `getAccountWei()` to get signed balance
3. **Apply sign**:
    - Positive (sign=true): Add to total (supply position)
    - Negative (sign=false): Subtract from total (debt position)
4. **Convert to USD**: Use price oracle for each asset
5. **Sum all positions**: Return total USD value (reverts if negative)

### Important Notes

-   **Signed Wei Balance**: Dolomite uses `Wei { bool sign; uint256 value }` where sign=true means positive
-   **Net Balance**: Total can be negative if debt exceeds collateral (fuse reverts in this case)
-   **Multi-Asset**: Each substrate can have different assets with different sub-accounts

## Substrate Configuration

### DolomiteSubstrate Structure

```solidity
struct DolomiteSubstrate {
    address asset; // ERC20 token address
    uint8 subAccountId; // Sub-account number (0-255)
    bool canBorrow; // Whether borrowing is allowed
}
```

### Encoding (bytes32)

```
bytes32 layout (256 bits):
┌─────────────────────────────────────────────────────────────────┐
│ bits 96-255 (160 bits) │ bits 88-95 (8 bits) │ bits 80-87 (8 bits) │
│ asset address          │ subAccountId        │ canBorrow flag      │
└─────────────────────────────────────────────────────────────────┘
```

### Example Configuration

```solidity
// USDC in sub-account 0, can supply and borrow
bytes32 usdcBorrow = DolomiteFuseLib.substrateToBytes32(
    DolomiteSubstrate({
        asset: USDC,
        subAccountId: 0,
        canBorrow: true
    })
);

// WETH in sub-account 0, supply only (collateral)
bytes32 wethCollateral = DolomiteFuseLib.substrateToBytes32(
    DolomiteSubstrate({
        asset: WETH,
        subAccountId: 0,
        canBorrow: false
    })
);

// USDC in sub-account 1 (isolated position)
bytes32 usdcIsolated = DolomiteFuseLib.substrateToBytes32(
    DolomiteSubstrate({
        asset: USDC,
        subAccountId: 1,
        canBorrow: true
    })
);
```

## Operations

### Supply Operations

```solidity
// Supply 1000 USDC to sub-account 0
DolomiteSupplyFuseEnterData memory data = DolomiteSupplyFuseEnterData({
    asset: USDC,
    amount: 1000e6,
    minBalanceIncrease: 990e6,  // Slippage protection
    subAccountId: 0,
    isolationModeMarketId: 0    // 0 for non-isolation mode
});
```

### Withdraw Operations

```solidity
// Withdraw 500 USDC from sub-account 0
DolomiteSupplyFuseExitData memory data = DolomiteSupplyFuseExitData({
    asset: USDC,
    amount: 500e6,              // Use type(uint256).max for full withdrawal
    minAmountOut: 490e6,        // Slippage protection
    subAccountId: 0,
    isolationModeMarketId: 0
});
```

### Borrow Operations

```solidity
// Borrow 500 USDC against collateral
DolomiteBorrowFuseEnterData memory data = DolomiteBorrowFuseEnterData({
    asset: USDC,
    amount: 500e6,
    minAmountOut: 500e6,        // Slippage protection
    subAccountId: 0
});
```

### Repay Operations

```solidity
// Repay 250 USDC debt
DolomiteBorrowFuseExitData memory data = DolomiteBorrowFuseExitData({
    asset: USDC,
    amount: 250e6,              // Use type(uint256).max for full repayment
    minDebtReduction: 250e6,    // Slippage protection
    subAccountId: 0
});
```

### Collateral Transfer Operations

```solidity
// Transfer 0.5 WETH from sub-account 0 to sub-account 1
DolomiteCollateralFuseEnterData memory data = DolomiteCollateralFuseEnterData({
    asset: WETH,
    amount: 0.5 ether,
    minSharesOut: 0.49 ether,   // Slippage protection
    fromSubAccountId: 0,
    toSubAccountId: 1
});
```

### E-mode Operations

```solidity
// Enable stablecoin E-mode (category 1)
DolomiteEModeFuseEnterData memory enterData = DolomiteEModeFuseEnterData({
    subAccountId: 0,
    categoryId: 1
});

// Disable E-mode
DolomiteEModeFuseExitData memory exitData = DolomiteEModeFuseExitData({
    subAccountId: 0
});
```

## Price Oracle Setup

### Required Price Feeds

The integration requires price feeds for all assets configured in substrates:

| Asset | Feed Example                                  |
| ----- | --------------------------------------------- |
| USDC  | Chainlink USDC/USD                            |
| WETH  | Chainlink ETH/USD (via WETHPriceFeed wrapper) |
| WBTC  | Chainlink BTC/USD                             |

### Configuration

```solidity
// Setup in PriceOracleMiddleware
address[] memory assets = new address[](2);
address[] memory sources = new address[](2);

assets[0] = USDC;
sources[0] = CHAINLINK_USDC_USD;

assets[1] = WETH;
sources[1] = address(new WETHPriceFeed(CHAINLINK_ETH_USD));

priceOracle.setAssetsPricesSources(assets, sources);
```

## Security Considerations

### Access Control

-   Immutable `MARKET_ID`, `DOLOMITE_MARGIN`, and router addresses prevent configuration changes
-   Substrate validation ensures only authorized (asset, subAccountId, canBorrow) combinations are used
-   E-mode category validation through DolomiteAccountRegistry

### Token Safety

-   Uses `SafeERC20` for all token operations
-   `forceApprove` pattern for maximum compatibility (USDT, etc.)
-   Balance checks before operations (amount > 0)

### Position Safety

-   Slippage protection on all operations (`minAmountOut`, `minBalanceIncrease`, etc.)
-   Debt existence check before repayment
-   Source balance validation before collateral transfers
-   Negative total balance check in BalanceFuse

### Substrate Validation

```solidity
// Supply: Check canSupply (allows both canBorrow=true and canBorrow=false)
if (!DolomiteFuseLib.canSupply(MARKET_ID, asset, subAccountId)) {
    revert DolomiteSupplyFuseUnsupportedAsset(...);
}

// Borrow: Check canBorrow (requires canBorrow=true)
if (!DolomiteFuseLib.canBorrow(MARKET_ID, asset, subAccountId)) {
    revert DolomiteBorrowFuseUnsupportedBorrowAsset(...);
}
```

## Instant Withdraw Support

`DolomiteSupplyFuse` implements `IFuseInstantWithdraw` for emergency withdrawals:

```solidity
// params_: [amount, asset, subAccountId (optional), isolationModeMarketId (optional), minAmountOut (optional)]
function instantWithdraw(bytes32[] calldata params_) external;
```

Features:

-   Try-catch wrapper for graceful failure handling
-   Emits `DolomiteSupplyFuseExitFailed` on failure instead of reverting
-   Returns (asset, 0) on failure to allow other withdrawals to proceed

## Network

-   **Chain:** Arbitrum One (Chain ID: 42161)
-   **Dolomite Margin:** `0x6Bd780E7fDf01D77e4d475c821f1e7AE05409072`
-   **DepositWithdrawalRouter:** `0xf8b2c637A68cF6A17b1DF9F8992EeBeFf63d2dFf`
-   **DolomiteAccountRegistry:** `0xC777fB526922fB61581b65f8eb55bb769CD59C63`

## External References

-   [Dolomite Documentation](https://docs.dolomite.io/)
-   [Dolomite GitHub](https://github.com/dolomite-exchange)
