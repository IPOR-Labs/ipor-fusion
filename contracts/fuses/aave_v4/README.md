# Aave V4 Integration

## Overview

Aave V4 integration enables IPOR Fusion to interact with Aave V4 lending protocol through Spoke contracts. This integration allows users to supply assets as collateral, borrow assets, and set E-Mode categories, while maintaining proper balance tracking across all reserves.

**What Aave V4 does:**
Aave V4 is the next generation of the Aave lending protocol, built around a Hub-Spoke architecture. Instead of a single monolithic pool, Aave V4 organizes lending markets into Spoke contracts, each managing multiple reserves. Users interact with Spoke contracts to supply, borrow, and repay assets. Each Spoke has its own set of reserves indexed sequentially from 0.

## Market Structure

The integration uses a single market for all operations:

-   **Market ID 43** (`AAVE_V4`) - Supply/withdrawal/borrow/repay/E-Mode operations

## Architecture

### Hub-Spoke Architecture

Aave V4 follows a Hub-Spoke architecture where Spokes manage individual lending markets:

```
Aave V4 Hub
├── Spoke A (e.g., Main Market)
│   ├── Reserve 0 (e.g., USDC)
│   ├── Reserve 1 (e.g., WETH)
│   └── Reserve N (...)
└── Spoke B (e.g., Isolated Market)
    ├── Reserve 0 (e.g., DAI)
    └── Reserve 1 (e.g., GHO)
```

### Key Components

-   **`AaveV4BalanceFuse`**: Tracks total USD value across all configured Spokes, accounting for supply and debt positions
-   **`AaveV4SupplyFuse`**: Handles deposits and withdrawals of assets via Spoke contracts
-   **`AaveV4BorrowFuse`**: Manages borrowing and repaying assets via Spoke contracts
-   **`AaveV4EModeFuse`**: Sets E-Mode categories on Spoke contracts for capital efficiency
-   **`AaveV4SubstrateLib`**: Typed substrate encoding (Asset/Spoke) for market configuration

## Balance Calculation

The balance calculation follows a multi-step process for each configured Spoke:

1. **Filter substrates**: Identify Spoke substrates from market configuration
2. **Iterate reserves**: For each reserve in the Spoke, check if the underlying asset is a granted Asset substrate
3. **Query positions**: Get supply and debt amounts via `getUserSuppliedAssets()` and `getUserTotalDebt()`
4. **Get price**: Retrieve underlying asset price from PriceOracleMiddleware
5. **Calculate net value**: `(supply - debt) * price`, normalized to WAD (18 decimals)
6. **Aggregate**: Sum net values across all Spokes

### Gas Optimization

The balance fuse skips reserves whose underlying asset is not a granted Asset substrate. Since Supply/Borrow fuses validate asset substrates on enter/exit, the vault cannot hold positions in reserves with non-granted assets.

### Important Notes

-   Reverts with `AaveV4BalanceFuseNegativeBalance` if total debt exceeds total supply
-   Prices are obtained from PlasmaVault's PriceOracleMiddleware
-   Reserve and asset substrate declarations are hoisted outside loops for gas efficiency

## Substrate Configuration

### Typed Substrate Encoding

Aave V4 uses typed substrates with a flag byte in the most significant position:

```
bytes32 layout:
+----------+---------------------------+---------------------+
| Bits     | 255..248 (8 bits)         | 247..0 (248 bits)   |
+----------+---------------------------+---------------------+
| Content  | Type flag (uint8)         | Padded address data |
+----------+---------------------------+---------------------+
```

-   **Flag 0 (Undefined)**: Uninitialized / invalid
-   **Flag 1 (Asset)**: ERC20 token address
-   **Flag 2 (Spoke)**: Aave V4 Spoke contract address

Both Asset and Spoke substrates must be granted in the market configuration. Supply, Borrow, and E-Mode fuses validate substrates before any operation.

### Example Configuration

```
Market ID 43 (AAVE_V4) substrates:
├── Spoke substrate: encodeSpoke(0xSpokeAddress)    // Flag 2
├── Asset substrate: encodeAsset(0xUSDC)             // Flag 1
├── Asset substrate: encodeAsset(0xWETH)             // Flag 1
└── Asset substrate: encodeAsset(0xDAI)              // Flag 1
```

## Operations

### Supply Operations

-   **Enter**: Supply assets to a Spoke reserve, receive supply shares
-   **Exit**: Withdraw assets from a Spoke reserve by burning supply shares
-   **Instant Withdraw**: Withdraw with exception handling for graceful failure

Slippage protection:
-   `minShares` on enter (minimum supply shares to receive)
-   `minAmount` on exit (minimum asset amount to withdraw)

### Borrow Operations

-   **Enter**: Borrow assets from a Spoke reserve, creating debt shares
-   **Exit**: Repay borrowed assets, burning debt shares

Slippage protection:
-   `minShares` on enter (minimum borrow shares to receive)
-   `minSharesRepaid` on exit (minimum debt shares to burn)

### E-Mode Operations

-   **Enter**: Set E-Mode category on a Spoke for capital efficiency
-   Set category to 0 to disable E-Mode

### Transient Storage

All fuses support transient storage variants (`enterTransient()` / `exitTransient()`) for composable multi-step operations within a single transaction.

## Reserve/Asset Mismatch Protection

Supply and Borrow fuses validate that the reserve's underlying asset matches the expected asset address. This protects against reserve index shifts that could occur due to Aave governance changes.

## Security Considerations

### Access Control

-   Immutable `MARKET_ID` and `VERSION` prevent configuration changes
-   Substrate validation ensures only authorized assets and Spokes are accessible
-   Reserve/asset mismatch validation prevents index shift attacks

### Token Safety

-   Uses `SafeERC20` (`forceApprove`) for secure token operations
-   Supply fuse approves exact amounts before Spoke interaction

### Fuse Safety

-   No storage variables (fuses run via delegatecall)
-   Stateless design with immutable-only state
-   All position data queried from Spoke contracts

## Price Oracle Setup

### Required Price Feeds

The integration requires price feeds for all underlying assets of reserves where the vault holds positions.

Configuration via `PriceOracleMiddleware`:

-   Price feed for each asset configured as an Asset substrate (e.g., USDC/USD, WETH/USD, DAI/USD)
-   Missing price feeds will cause balance calculation to revert with `UnsupportedQuoteCurrencyFromOracle`
-   Zero prices are explicitly rejected

## Usage Patterns

### Supply

```solidity
AaveV4SupplyFuseEnterData memory enterData = AaveV4SupplyFuseEnterData({
    spoke: spokeAddress,
    asset: usdcAddress,
    reserveId: 0,
    amount: 1000e6,
    minShares: 990e6
});
supplyFuse.enter(enterData);
```

### Borrow

```solidity
AaveV4BorrowFuseEnterData memory borrowData = AaveV4BorrowFuseEnterData({
    spoke: spokeAddress,
    asset: wethAddress,
    reserveId: 1,
    amount: 1e18,
    minShares: 0
});
borrowFuse.enter(borrowData);
```

### Set E-Mode

```solidity
AaveV4EModeFuseEnterData memory emodeData = AaveV4EModeFuseEnterData({
    spoke: spokeAddress,
    eModeCategory: 1
});
emodeFuse.enter(emodeData);
```
