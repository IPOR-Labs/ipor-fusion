# Enso Integration

## Overview

Enso integration enables IPOR Fusion to execute complex DeFi strategies through Enso's routing infrastructure. This integration provides a secure and flexible way to interact with multiple DeFi protocols through a single interface, using a delegatecall-based executor pattern that maintains asset custody within the Plasma Vault ecosystem.

**What Enso does:**
Enso is a DeFi routing and automation platform that provides smart routing across multiple protocols. It optimizes capital deployment by finding the best paths for token swaps, liquidity provision, and yield strategies. The Enso API generates optimized execution plans (shortcuts) that can perform complex multi-step operations across various DeFi protocols in a single transaction.

## Market Structure

The integration uses a single market for all operations:

-   **Market ID** (configurable) - Enso routing and strategy execution operations, it is fixed in IporFusionMarkets to 38

## Architecture

### Enso Architecture

Enso integration follows a secure delegatecall-based executor pattern:

```
PlasmaVault
├── EnsoFuse (Main entry point)
│   ├── enter() - Execute Enso shortcuts
│   └── exit() - Withdraw tokens from executor
├── EnsoExecutor (Isolated execution context)
│   ├── execute() - Execute via delegatecall to DelegateEnsoShortcuts
│   ├── withdrawAll() - Transfer tokens back to PlasmaVault
│   └── recovery() - Emergency recovery function
└── EnsoStorageLib (Executor address storage)
    └── Stores EnsoExecutor address in isolated storage slot
```

**Key Design Principles:**

-   **Delegatecall Pattern**: EnsoExecutor uses delegatecall to execute shortcuts through Enso's DelegateEnsoShortcuts contract
-   **Asset Isolation**: The executor holds assets temporarily during execution, maintaining separation from PlasmaVault
-   **Substrate Validation**: All token transfers and protocol interactions must be pre-approved as substrates
-   **Command Validation**: Each command in an Enso shortcut is validated against granted substrates
-   **Storage Isolation**: Uses ERC-7201 storage pattern to store executor address in isolated slot

### Key Components

-   **`EnsoFuse`**: Main fuse handling Enso shortcut execution and token withdrawal
-   **`EnsoExecutor`**: Delegatecall-based executor that executes Enso shortcuts in isolated context
-   **`EnsoBalanceFuse`**: Tracks USD value of assets held in the EnsoExecutor
-   **`EnsoInitExecutorFuse`**: Optional fuse for pre-initializing the executor
-   **`EnsoStorageLib`**: Library for managing EnsoExecutor address in storage
-   **`EnsoSubstrateLib`**: Library for encoding/decoding substrate information (address + function selector)

## Executor Pattern

### Why Use EnsoExecutor?

The EnsoExecutor provides several critical benefits:

1. **Execution Isolation**: Separates Enso shortcut execution from PlasmaVault's main context
2. **Asset Safety**: Temporarily holds assets during multi-protocol operations
3. **Delegatecall Security**: Executes Enso shortcuts via delegatecall while maintaining PlasmaVault ownership
4. **Balance Tracking**: Tracks pending balances for cross-chain or delayed operations
5. **ETH/WETH Handling**: Manages ETH unwrapping/wrapping for protocols requiring native ETH

### Executor Lifecycle

```
1. First enter() call → Creates EnsoExecutor if not exists
2. Transfer tokens → PlasmaVault transfers tokens to EnsoExecutor
3. Execute shortcut → EnsoExecutor performs delegatecall to DelegateEnsoShortcuts
4. Return tokens → EnsoExecutor transfers result tokens back to PlasmaVault
5. Track balance → Store any pending balance for future reconciliation
6. exit() call → Withdraw remaining tokens from EnsoExecutor
```

## Balance Calculation

The balance calculation reads the pending balance stored in the EnsoExecutor:

1. **Get executor address**: Retrieve EnsoExecutor address from storage
2. **Get balance**: Call `IEnsoExecutor.getBalance()` to get asset address and amount
3. **Get price**: Query price oracle for asset price
4. **Calculate USD value**: Convert asset balance to USD using price and decimals
5. **Return total**: Return total balance in 18 decimal format (WAD)

### Important Notes

-   **Pending Balance**: The executor tracks pending balances for cross-chain or delayed operations
-   **Single Asset**: The executor tracks one asset at a time (the last `tokenOut`)
-   **Automatic Cleanup**: Balance is cleared when tokens are withdrawn via `exit()`
-   **Zero Balance Handling**: Returns 0 if no executor exists or no pending balance

## Operations

### Enter Operation (Execute Enso Shortcut)

The `enter()` function executes an Enso shortcut through the following steps:

1. **Substrate Validation**: Validates that all tokens and commands are granted as substrates
2. **Command Validation**: Validates that all protocol interactions are pre-approved
3. **Executor Creation**: Creates EnsoExecutor if it doesn't exist (lazy initialization)
4. **Token Transfer**: Transfers specified tokens (tokenOut) to the executor
5. **WETH Transfer**: Transfers WETH to the executor if needed for ETH operations
6. **Shortcut Execution**: Executor performs delegatecall to execute the Enso shortcut
7. **Return Tokens**: Executor automatically returns tokens to PlasmaVault
8. **Balance Tracking**: Stores pending balance for future reconciliation

**Parameters:**

```solidity
struct EnsoFuseEnterData {
    address tokenOut; // Token to transfer from PlasmaVault to executor
    uint256 amountOut; // Amount to transfer (in token decimals)
    uint256 wEthAmount; // WETH amount to unwrap to ETH (0 if not needed)
    bytes32 accountId; // Enso API user identifier
    bytes32 requestId; // Enso API request identifier
    bytes32[] commands; // Array of encoded commands (target + selector + flags)
    bytes[] state; // Calldata parameters for each command
    address[] tokensToReturn; // Tokens expected to be returned to PlasmaVault
}
```

### Exit Operation (Withdraw Tokens)

The `exit()` function withdraws tokens from the EnsoExecutor back to PlasmaVault:

1. **Substrate Validation**: Validates that all tokens have transfer function granted
2. **Executor Check**: Verifies that executor exists
3. **Withdraw Tokens**: Calls `withdrawAll()` to transfer all specified tokens back
4. **Balance Cleanup**: Clears the pending balance in executor storage

**Parameters:**

```solidity
struct EnsoFuseExitData {
    address[] tokens; // Array of token addresses to withdraw
}
```

### Recovery Operation

The `recovery()` function provides emergency access to execute arbitrary delegatecalls:

-   **Emergency Use**: Only callable when balance is empty (safety check)
-   **PlasmaVault Only**: Only callable by the PlasmaVault
-   **Delegatecall**: Executes arbitrary data via delegatecall to specified target

## Command Structure

### Command Encoding

Each command is encoded as bytes32 with the following structure:

```
[0:20]  - Target address (20 bytes)
[20:24] - Function selector (4 bytes)
[24:32] - Flags (8 bytes)
```

### Command Flags

-   **FLAG_CT_CALL (0x01)**: Standard CALL operation (state-changing, no ETH)
-   **FLAG_CT_STATICCALL (0x02)**: STATICCALL operation (read-only, skipped in validation)
-   **FLAG_CT_VALUECALL (0x03)**: CALL with ETH value transfer
-   **FLAG_EXTENDED_COMMAND (0x40)**: Next command contains indices/metadata (not a call)

### Command Validation

The integration validates all commands (except STATICCALL) against granted substrates:

1. **Extract command data**: Parse target address, function selector, and flags
2. **Skip read-only calls**: STATICCALL commands are skipped (no state changes)
3. **Skip extended commands**: FLAG_EXTENDED_COMMAND indicates metadata, not a call
4. **Validate substrate**: Check if substrate (target + selector) is granted
5. **Revert if not granted**: Throws `EnsoFuseUnsupportedCommand` error

## Substrate Configuration

Substrates in Enso integration represent **allowed interactions** encoded as:

```
bytes32 substrate = encode(address target, bytes4 functionSelector)
```

### Required Substrate Types

#### 1. Token Transfer Substrates

**Required for all tokens involved in operations:**

```solidity
// For tokenOut
substrate = encode(tokenOut, ERC20.transfer.selector)

// For WETH (if wEthAmount > 0)
substrate = encode(WETH, ERC20.transfer.selector)

// For each token in tokensToReturn
substrate = encode(tokenToReturn, ERC20.transfer.selector)
```

#### 2. Protocol Interaction Substrates

**Required for each command in the Enso shortcut:**

```solidity
// Extract from each command
address target = address(uint160(uint256(command)));
bytes4 selector = bytes4(command);

// Substrate must be granted
substrate = encode(target, selector)
```

### Example Configuration

**Scenario: Swap USDC to ETH via Uniswap V3, then deposit ETH into Aave V3**

**Required Substrates:**

```
Market ID: [Your Enso Market ID]

Token Substrates:
├── USDC address + transfer() selector
├── WETH address + transfer() selector
└── aWETH address + transfer() selector

Protocol Substrates:
├── Uniswap V3 Router + exactInputSingle() selector
├── Aave V3 Pool + supply() selector
└── WETH address + withdraw() selector (for ETH unwrapping)
```

**Substrate Encoding Example:**

```solidity
// Token substrate
bytes32 usdcSubstrate = EnsoSubstrateLib.encodeRaw(
    0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,  // USDC on Ethereum
    0xa9059cbb  // transfer(address,uint256) selector
);

// Protocol substrate
bytes32 uniswapSubstrate = EnsoSubstrateLib.encodeRaw(
    0xE592427A0AEce92De3Edee1F18E0157C05861564,  // Uniswap V3 Router
    0x414bf389  // exactInputSingle(params) selector
);
```

## Storage Pattern

### EnsoStorageLib - ERC-7201 Storage

The integration uses ERC-7201 namespaced storage to prevent storage collisions:

```solidity
Storage Slot: keccak256(abi.encode(uint256(keccak256("io.ipor.enso.Executor")) - 1)) & ~bytes32(uint256(0xff))
Storage Slot Value: 0x2be19acf1082fe0f31c0864ff2dc58ff9679d12ca8fb47a012400b2f6ce3af00

struct EnsoExecutorStorage {
    address executor;  // EnsoExecutor address
}
```

**Benefits:**

-   **Collision Prevention**: Isolated storage slot prevents conflicts with other storage
-   **Upgradeability**: Storage location remains constant across upgrades
-   **Standard Compliance**: Follows ERC-7201 namespaced storage pattern

## Balance Tracking

### EnsoExecutor Balance Structure

The EnsoExecutor tracks a single pending balance using an optimized storage structure:

```solidity
struct EnsoExecutorBalance {
    address assetAddress; // 20 bytes (160 bits)
    uint96 assetBalance; // 12 bytes (96 bits) - max ~79 trillion tokens
}
```

**Single Storage Slot**: The entire structure fits in one 32-byte storage slot for gas efficiency.

**Max Balance**: uint96 supports up to 79,228,162,514 tokens with 18 decimals (sufficient for most use cases).

### Balance Lifecycle

1. **Execution Start**: Balance is set to zero (or reverts if not zero)
2. **After Execution**: Tracks remaining `tokenOut` that wasn't returned to PlasmaVault
3. **Cross-Chain Scenarios**: Holds expected balance for tokens arriving later
4. **Withdrawal**: Balance is cleared when tokens are withdrawn via `exit()`

### Important Balance Behaviors

-   **One Asset at a Time**: Only tracks the last `tokenOut` from the most recent execution
-   **Safety Check**: New execution reverts if previous balance is not zero
-   **Automatic Return**: Tokens returned during execution reduce the pending balance
-   **Complete Cleanup**: `withdrawAll()` clears both address and balance to zero

## ETH/WETH Handling

The integration provides seamless ETH/WETH conversion:

1. **Before Execution**: If `wEthAmount > 0`, WETH is unwrapped to ETH in the executor
2. **During Execution**: Protocols can use native ETH for operations
3. **After Execution**: Any remaining ETH is wrapped back to WETH and returned to PlasmaVault

**Flow:**

```
PlasmaVault (WETH) → EnsoExecutor (unwrap to ETH) → Protocol Operations (ETH)
                   ← EnsoExecutor (wrap to WETH) ← Protocol Returns (ETH)
```

## Security Features

### Multi-Layer Validation

1. **Substrate Validation**: All token transfers and protocol calls must be pre-approved
2. **Command Validation**: Each command in shortcuts is validated against granted substrates
3. **Executor Access Control**: Only PlasmaVault can call executor functions
4. **Balance Safety**: Prevents concurrent executions when balance is pending
5. **Address Validation**: All addresses are validated as non-zero

### Substrate Validation Steps

**For enter() operation:**

1. Validate `tokenOut` has transfer substrate granted
2. Validate `WETH` has transfer substrate granted (if `wEthAmount > 0`)
3. Validate each `tokenToReturn` has transfer substrate granted
4. Validate each command's target + selector is granted (except STATICCALL)

**For exit() operation:**

1. Validate each token in array has transfer substrate granted

## Important Considerations

### Key Architectural Principles

-   **Enso = DeFi Router**: Enso provides optimized routing across multiple protocols, not a single protocol
-   **Executor Pattern**: Uses delegatecall executor for secure and isolated execution
-   **Lazy Initialization**: EnsoExecutor is created on first use (gas optimization)
-   **Temporary Custody**: Executor holds assets only during shortcut execution
-   **Command-Based**: Operations are defined as sequences of commands from Enso API

### Operational Constraints

-   **Single Pending Balance**: Only one asset balance can be tracked at a time
-   **Substrate Pre-approval**: All interactions must be configured as substrates before use
-   **Executor Dependency**: Enso shortcuts depend on DelegateEnsoShortcuts contract
-   **Cross-Chain Timing**: For cross-chain operations, tokens may arrive with delay
-   **Balance Cleanup Required**: Must call `exit()` to clear pending balances before next execution

### Best Practices

1. **Pre-Initialize Executor**: Use `EnsoInitExecutorFuse.enter()` to create executor in advance (optional)
2. **Validate Substrates**: Ensure all required substrates are granted before execution
3. **Monitor Balances**: Check `EnsoBalanceFuse.balanceOf()` to track pending balances
4. **Clean Up**: Call `exit()` to withdraw tokens and clear balance after cross-chain operations
5. **Test Commands**: Validate Enso shortcuts in test environment before production use

## Price Oracle Setup

### Required Price Feeds

The integration requires price feeds for assets tracked in the EnsoExecutor's balance:

**Configuration Requirements:**

1. **Asset Price Feeds**: Configure price feed for any asset that can be `tokenOut` in Enso shortcuts
2. **Price Oracle Middleware**: Must have `IPriceOracleMiddleware` configured in PlasmaVault
3. **Price Format**: Prices must include both value and decimals via `getAssetPrice()`

**Example Configuration:**

```solidity
// For USDC balance in EnsoExecutor
priceOracleMiddleware.getAssetPrice(USDC_ADDRESS)
// Returns: (price: uint256, decimals: uint256)

// Balance calculation in EnsoBalanceFuse
balanceUSD = IporMath.convertToWad(
    assetBalance * price,
    assetDecimals + priceDecimals
);
```

**Supported Oracle Types:**

-   Chainlink
-   DIA
-   RedStone
-   Uniswap v3
-   Custom oracles implementing `IPriceOracleMiddleware`

### Balance Calculation Process

1. Get executor address from `EnsoStorageLib`
2. Call `executor.getBalance()` to get asset address and balance
3. Query `priceOracleMiddleware.getAssetPrice(assetAddress)` for price
4. Get asset decimals from `IERC20Metadata(assetAddress).decimals()`
5. Convert to USD in 18 decimals: `convertToWad(balance * price, assetDecimals + priceDecimals)`

**Important Notes:**

-   Only tracks single asset balance at a time (the pending `tokenOut`)
-   Returns 0 if no executor exists or no pending balance
-   Price feed must be configured for the exact asset address returned by executor
-   Missing price feeds will cause `balanceOf()` to revert
