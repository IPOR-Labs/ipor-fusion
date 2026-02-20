# Midas RWA Integration

## Overview

Midas integration enables IPOR Fusion to interact with the Midas RWA tokenization protocol. This integration supports both instant and asynchronous (request-based) deposit/redemption flows for mTokens (mTBILL, mBASIS).

**What Midas does:**
Midas is a tokenized Real World Asset (RWA) protocol that issues mTokens backed by traditional financial instruments. mTBILL represents tokenized US Treasury Bills, and mBASIS represents a diversified yield product. Midas operates two deposit/redemption models:
- **Instant**: Direct mint/redeem through Deposit Vault and Instant Redemption Vault
- **Async (Request-based)**: Submit deposit/redemption requests that require Midas admin approval

## Market Structure

The integration uses a single market for all operations:

-   **Market ID 45** (`MIDAS`) - All deposit, redemption, and balance operations

## Architecture

### Dual-Flow Model

```
Instant Flow (MidasSupplyFuse):
  PlasmaVault -> depositInstant() -> mTokens received immediately
  PlasmaVault -> redeemInstant()  -> USDC received immediately

Async Flow (MidasRequestSupplyFuse):
  PlasmaVault -> depositRequest() -> USDC leaves vault, pending request created
  Midas Admin -> approveRequest() -> mTokens minted to PlasmaVault (push-based)
  PlasmaVault -> redeemRequest()  -> mTokens locked, pending request created
  Midas Admin -> approveRequest() -> USDC sent to PlasmaVault (push-based)
```

### Key Components

-   **`MidasBalanceFuse`**: Reports total NAV in USD (18 decimals) across three components:
    - A) mTokens held by PlasmaVault (balance * price from data feed)
    - B) Pending deposit requests (USDC in transit)
    - C) Pending redemption requests (mTokens in transit, priced via data feed)
-   **`MidasSupplyFuse`**: Instant deposit/redemption via Deposit Vault and Instant Redemption Vault
-   **`MidasRequestSupplyFuse`**: Async deposit/redemption requests via Deposit Vault and Standard Redemption Vault. Includes `cleanupPendingDeposits()` and `cleanupPendingRedemptions()` for stale request cleanup.
-   **`MidasSubstrateLib`**: Typed substrate encoding (M_TOKEN, DEPOSIT_VAULT, REDEMPTION_VAULT, INSTANT_REDEMPTION_VAULT, ASSET)
-   **`MidasPendingRequestsStorageLib`**: Storage library tracking pending request IDs per vault for NAV reporting

## Balance Calculation

The balance fuse computes total value across three components:

1. **Component A (mToken holdings)**: For each unique mToken resolved from deposit vaults, query `balanceOf(PlasmaVault)` and multiply by the mToken price from `mTokenDataFeed().getDataInBase18()`
2. **Component B (pending deposits)**: Sum `depositedUsdAmount` for all pending deposit requests (status == Pending)
3. **Component C (pending redemptions)**: Sum `amountMToken * mTokenPrice` for all pending redemption requests (status == Pending)

### Important Notes

-   mToken prices are sourced from Midas data feeds (`mTokenDataFeed()` on deposit vaults)
-   Each mToken is counted only once even if multiple deposit vaults reference it
-   Pending request IDs are tracked in `MidasPendingRequestsStorageLib` and cleaned up during supply fuse operations

## Substrate Configuration

### Typed Substrate Encoding

Midas uses typed substrates following the same pattern as other integrations:

```
bytes32 layout:
+----------+---------------------------+---------------------+
| Bits     | 255..160 (96 bits)        | 159..0 (160 bits)   |
+----------+---------------------------+---------------------+
| Content  | Type flag (uint96)        | Address             |
+----------+---------------------------+---------------------+
```

-   **Type 0 (UNDEFINED)**: Invalid
-   **Type 1 (M_TOKEN)**: mToken address (mTBILL, mBASIS)
-   **Type 2 (DEPOSIT_VAULT)**: Midas Deposit Vault address
-   **Type 3 (REDEMPTION_VAULT)**: Midas Standard Redemption Vault address
-   **Type 4 (INSTANT_REDEMPTION_VAULT)**: Midas Instant Redemption Vault address
-   **Type 5 (ASSET)**: Allowed deposit/withdrawal asset (e.g., USDC)

### Example Configuration

```
Market ID 45 (MIDAS) substrates:
├── M_TOKEN: mTBILL (0xDD629E5241CbC5919847783e6C96B2De4754e438)
├── M_TOKEN: mBASIS (0x2a8c22E3b10036f3AEF5875d04f8441d4188b656)
├── DEPOSIT_VAULT: mTBILL Deposit Vault
├── DEPOSIT_VAULT: mBASIS Deposit Vault
├── REDEMPTION_VAULT: mTBILL Standard Redemption Vault
├── REDEMPTION_VAULT: mBASIS Standard Redemption Vault
├── INSTANT_REDEMPTION_VAULT: mTBILL Instant Redemption Vault
└── ASSET: USDC
```

## Operations

### Instant Supply (MidasSupplyFuse)

-   **Enter**: Deposit underlying token (USDC) via `depositInstant()`, receive mTokens immediately
-   **Exit**: Redeem mTokens via `redeemInstant()` for underlying tokens immediately
-   **Instant Withdraw**: Withdraw with exception handling for graceful failure

Slippage protection:
-   `minMTokenAmountOut` on enter (minimum mTokens to receive)
-   `minTokenOutAmount` on exit (minimum underlying tokens to receive)

### Async Supply (MidasRequestSupplyFuse)

-   **Enter**: Submit deposit request via `depositRequest()`. USDC leaves PlasmaVault; mTokens minted after admin approval.
-   **Exit**: Submit redemption request via `redeemRequest()`. mTokens locked; USDC sent after admin approval.
-   **Cleanup**: `cleanupPendingDeposits()` / `cleanupPendingRedemptions()` to remove stale non-pending requests with bounded iterations.

### Pending Request Management

Pending requests are automatically cleaned up during `enter()` and `exit()` calls. For long idle periods, use the dedicated cleanup methods:

```solidity
fuse.cleanupPendingDeposits(depositVaultAddress, 10);     // Process up to 10
fuse.cleanupPendingRedemptions(redemptionVaultAddress, 0); // Process all
```

## Security Considerations

### Access Control

-   Immutable `MARKET_ID` and `VERSION` prevent configuration changes
-   All substrate types validated before any operation

### Token Safety

-   Uses `SafeERC20` (`forceApprove`) for secure token operations
-   Approval cleanup after every operation (set to 0)

### Fuse Safety

-   No storage variables (fuses run via delegatecall)
-   Stateless design with immutable-only state
-   Pending request state stored in dedicated storage library with namespaced slots

## Usage Patterns

### Instant Deposit

```solidity
MidasSupplyFuseEnterData memory data = MidasSupplyFuseEnterData({
    mToken: MTBILL,
    tokenIn: USDC,
    amount: 1000e6,
    minMTokenAmountOut: 990e18,
    depositVault: MTBILL_DEPOSIT_VAULT
});
supplyFuse.enter(data);
```

### Async Deposit Request

```solidity
MidasRequestSupplyFuseEnterData memory data = MidasRequestSupplyFuseEnterData({
    mToken: MTBILL,
    tokenIn: USDC,
    amount: 1000e6,
    depositVault: MTBILL_DEPOSIT_VAULT
});
requestSupplyFuse.enter(data);
```

### Async Redemption Request

```solidity
MidasRequestSupplyFuseExitData memory data = MidasRequestSupplyFuseExitData({
    mToken: MTBILL,
    amount: 100e18,
    tokenOut: USDC,
    standardRedemptionVault: MTBILL_STANDARD_REDEMPTION_VAULT
});
requestSupplyFuse.exit(data);
```
