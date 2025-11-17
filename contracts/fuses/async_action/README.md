# Async Action Integration

## Overview

Async Action integration enables IPOR Fusion to execute complex, multi-step DeFi operations asynchronously through a dedicated executor contract. This integration allows users to perform sophisticated operations (such as swaps, deposits, and other protocol interactions) that require multiple sequential calls, while maintaining security through substrate-based validation and slippage protection.

**What Async Action does:**
Async Action provides a mechanism for executing off-chain encoded action sequences through an isolated executor contract. The executor receives tokens from the Plasma Vault, executes a series of validated calls, and holds resulting assets until they are fetched back to the vault. This pattern enables complex DeFi strategies that require multiple protocol interactions while maintaining strict access control and validation.

## Market Structure

The integration uses a single market for all operations:

-   **Market ID 32** (`ASYNC_ACTION`) - Enter/exit operations and balance tracking

## Architecture

### Component Hierarchy

Async Action follows a multi-contract architecture:

```
Plasma Vault
├── AsyncActionFuse (validation & orchestration)
├── AsyncActionBalanceFuse (balance tracking)
├── AsyncExecutor (isolated execution environment)
└── AsyncActionFuseLib (substrate encoding/decoding & storage)
```

### Key Components

-   **`AsyncActionFuse`**: Validates and orchestrates async action execution. Handles `enter()` (transfer tokens and execute) and `exit()` (fetch assets back) operations.
-   **`AsyncExecutor`**: Isolated contract that receives tokens, executes validated call sequences, and holds resulting assets. Each Plasma Vault has its own executor instance.
-   **`AsyncActionFuseLib`**: Library for encoding/decoding substrate data and managing AsyncExecutor storage using ERC-7201 namespaced storage pattern.
-   **`AsyncActionBalanceFuse`**: Tracks USD value of assets held by the AsyncExecutor, converting cached balance to USD using price oracle.
-   **`ReadAsyncExecutor`**: Reader contract that provides method to read AsyncExecutor address from storage via delegatecall through UniversalReader.

## Execution Flow

### Enter Flow

1. **Validation**: `AsyncActionFuse.enter()` validates:
    - Token and amount against `ALLOWED_AMOUNT_TO_OUTSIDE` substrates
    - Target/selector pairs against `ALLOWED_TARGETS` substrates
    - Executor balance must be zero when `amountOut > 0`
2. **Token Transfer**: If executor balance is zero and `amountOut > 0`, tokens are transferred to executor
3. **Execution**: Executor executes the sequence of calls with optional ETH values
4. **Balance Caching**: Executor caches balance in underlying asset units (if balance was zero before execution)

### Exit Flow

1. **Validation**: `AsyncActionFuse.exit()` validates:
    - Target/selector pairs for fetch operations against `ALLOWED_TARGETS` substrates
    - Executor address must be set
    - Price oracle must be configured
2. **Balance Calculation**: Executor calculates total USD value of all assets to fetch
3. **Slippage Check**: Validates that actual balance meets minimum threshold (cached balance - slippage tolerance)
4. **Asset Transfer**: Transfers all specified assets back to Plasma Vault
5. **Balance Reset**: Resets cached balance to zero

## Balance Calculation

The balance calculation follows these steps:

1. **Read Cached Balance**: Retrieve executor's cached balance (in underlying asset units)
2. **Get Underlying Asset**: Resolve underlying asset from Plasma Vault (via ERC4626.asset())
3. **Get Price**: Fetch underlying asset price from price oracle middleware
4. **Convert to USD**: Convert balance \* price to WAD (18 decimals) accounting for both price and underlying asset decimals

### Important Notes

-   Executor caches balance only when it transitions from zero to non-zero (during first execution)
-   Balance is expressed in underlying asset units, not USD
-   Balance is reset to zero after successful `exit()` operation
-   If executor doesn't exist or balance is zero, `AsyncActionBalanceFuse` returns 0

## Substrate Configuration

### Substrate Types

The integration uses three types of substrates:

1. **`ALLOWED_AMOUNT_TO_OUTSIDE`**: Defines maximum allowed amount per token that can be transferred to executor
    - Encodes: `address asset` (20 bytes) + `uint88 amount` (11 bytes) = 31 bytes
2. **`ALLOWED_TARGETS`**: Defines allowed target contract addresses and function selectors
    - Encodes: `address target` (20 bytes) + `bytes4 selector` (4 bytes) = 24 bytes (7 bytes unused)
3. **`ALLOWED_SLIPPAGE`**: Defines maximum slippage tolerance for exit operations
    - Encodes: `uint248 slippage` (31 bytes) in WAD format (1e18 = 100%, 5e16 = 5%)

### Substrate Encoding

Each substrate is encoded as `bytes32`:

-   First byte: `AsyncActionFuseSubstrateType` enum value
-   Remaining 31 bytes: Substrate-specific data

### Example Configuration

```solidity
// Encode allowed amount
AllowedAmountToOutside memory amountSubstrate = AllowedAmountToOutside({
    asset: USDC,
    amount: 10_000e6
});
bytes32 encodedAmount = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
    AsyncActionFuseSubstrate({
        substrateType: AsyncActionFuseSubstrateType.ALLOWED_AMOUNT_TO_OUTSIDE,
        data: AsyncActionFuseLib.encodeAllowedAmountToOutside(amountSubstrate)
    })
);

// Encode allowed target
AllowedTargets memory targetSubstrate = AllowedTargets({
    target: USDC,
    selector: IERC20.approve.selector
});
bytes32 encodedTarget = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
    AsyncActionFuseSubstrate({
        substrateType: AsyncActionFuseSubstrateType.ALLOWED_TARGETS,
        data: AsyncActionFuseLib.encodeAllowedTargets(targetSubstrate)
    })
);

// Encode slippage (5% = 5e16)
AllowedSlippage memory slippageSubstrate = AllowedSlippage({
    slippage: 5e16
});
bytes32 encodedSlippage = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
    AsyncActionFuseSubstrate({
        substrateType: AsyncActionFuseSubstrateType.ALLOWED_SLIPPAGE,
        data: AsyncActionFuseLib.encodeAllowedSlippage(slippageSubstrate)
    })
);
```

## AsyncExecutor Management

### Executor Deployment

-   Executor is deployed lazily on first use via `AsyncActionFuseLib.getAsyncExecutorAddress()`
-   Each Plasma Vault has its own executor instance
-   Executor address is stored using ERC-7201 namespaced storage pattern
-   Executor is immutable: `W_ETH` and `PLASMA_VAULT` addresses are set at deployment

### Reading Executor Address

The executor address can be read using `ReadAsyncExecutor` contract via UniversalReader:

```solidity
// Via UniversalReader delegatecall
ReadAsyncExecutor reader = new ReadAsyncExecutor();
bytes memory result = UniversalReader.read(
    plasmaVaultAddress,
    abi.encodeWithSelector(ReadAsyncExecutor.readAsyncExecutorAddress.selector)
);
address executor = abi.decode(result, (address));
```

## Security Considerations

### Validation

-   All tokens and amounts must be explicitly allowed via substrates
-   All target/selector pairs must be whitelisted
-   Executor balance must be zero before new `enter()` with `amountOut > 0`
-   Price oracle must be configured for both enter and exit operations

### Slippage Protection

-   Exit operations validate that fetched assets meet minimum value threshold
-   Slippage tolerance is configurable per market via `ALLOWED_SLIPPAGE` substrate
-   Calculation: `minimumAllowedBalance = cachedBalance - (cachedBalance * slippage / WAD)`

### Isolation

-   Executor is isolated from Plasma Vault storage
-   Only authorized Plasma Vault can call executor functions
-   Executor can receive ETH for calls requiring native value

## Price Oracle Setup

### Required Price Feeds

The integration requires price feeds for:

-   All tokens that can be transferred to executor (for balance calculation)
-   Underlying asset of the Plasma Vault (for USD conversion)

Price feed configuration via `Price Oracle Middleware Manager` or `Price Oracle Middleware`

Example:

-   price feed for pair: **USDC/USD**
-   price feed for pair: **WETH/USD** (if underlying asset is WETH)
