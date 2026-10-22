# Velora Swapper Fuse

Integration with [Velora/ParaSwap](https://developers.paraswap.network) for optimized token swapping via Augustus v6.2 in IPOR Fusion PlasmaVault.

## Overview

VeloraSwapperFuse enables PlasmaVault to execute token swaps using Velora (ParaSwap) aggregator, which finds optimal routing across multiple DEXs. The integration uses Augustus v6.2 for efficient swap execution.

### Architecture

```
┌─────────────────┐     ┌───────────────────┐     ┌───────────────────┐
│   PlasmaVault   │────>│ VeloraSwapperFuse │────>│ VeloraSwapExecutor│
│  (delegatecall) │     │   (validation)    │     │   (Augustus v6.2) │
└─────────────────┘     └───────────────────┘     └───────────────────┘
                                                           │
                                                           v
                                                  ┌───────────────────┐
                                                  │   Augustus v6.2   │
                                                  │ 0x6A000F2000...   │
                                                  └───────────────────┘
```

## Contracts

| Contract | Description |
|----------|-------------|
| `VeloraSwapperFuse.sol` | Main fuse contract with validation logic (executed via delegatecall) |
| `VeloraSwapExecutor.sol` | Executor contract that interacts with Augustus v6.2 |
| `VeloraSubstrateLib.sol` | Library for encoding/decoding substrate configuration |

## Key Features

- **DEX Aggregation**: Leverages ParaSwap's routing for optimal swap execution across multiple DEXs
- **Dual Slippage Protection**:
  - Alpha-specified `minAmountOut` check
  - USD-based slippage validation via PriceOracleMiddleware
- **Substrate-based Configuration**: Token whitelist and slippage limits via market substrates
- **Security**: Approval cleanup after swaps, SafeERC20 usage

## Augustus v6.2

**Address (same on all EVM chains):**
```
0x6A000F20005980200259B80c5102003040001068
```

This address is identical on: Ethereum, Arbitrum, Optimism, Base, Polygon, BNB Chain, Avalanche, and other supported networks.

## Substrate Configuration

Substrates are used to configure allowed tokens and slippage limits for the Velora market. Each substrate is a `bytes32` value with type information encoded in the first byte.

### Substrate Types

| Type | Value | Description |
|------|-------|-------------|
| `Unknown` | 0 | Invalid/unknown type |
| `Token` | 1 | Token address whitelist |
| `Slippage` | 2 | Slippage limit configuration |

### Encoding Format

**Token Substrate** (type = 1):
```
Layout: [type (1 byte)][padding (11 bytes)][address (20 bytes)]
Example: 0x01_0000000000000000000000_af88d065e77c8cC2239327C5EDb3A432268e5831
         ^type                      ^token address (USDC on Arbitrum)
```

**Slippage Substrate** (type = 2):
```
Layout: [type (1 byte)][slippage in WAD (31 bytes)]
Example: 0x02_00000000000000000000000000000000000000000000000000002386f26fc10000
         ^type                                                  ^1% = 1e16 WAD
```

### Using VeloraSubstrateLib

```solidity
import {VeloraSubstrateLib} from "./VeloraSubstrateLib.sol";

// Encode token substrate
bytes32 usdcSubstrate = VeloraSubstrateLib.encodeTokenSubstrate(USDC_ADDRESS);
bytes32 wethSubstrate = VeloraSubstrateLib.encodeTokenSubstrate(WETH_ADDRESS);

// Encode slippage substrate (2% = 2e16 WAD)
bytes32 slippageSubstrate = VeloraSubstrateLib.encodeSlippageSubstrate(2e16);

// Decode substrate type
VeloraSubstrateType substrateType = VeloraSubstrateLib.decodeSubstrateType(substrate);

// Check substrate type
bool isToken = VeloraSubstrateLib.isTokenSubstrate(substrate);
bool isSlippage = VeloraSubstrateLib.isSlippageSubstrate(substrate);

// Decode values
address token = VeloraSubstrateLib.decodeToken(tokenSubstrate);
uint256 slippage = VeloraSubstrateLib.decodeSlippage(slippageSubstrate);
```

### Configuration Example

```solidity
// Configure Velora market substrates
bytes32[] memory veloraSubstrates = new bytes32[](5);

// Whitelist tokens
veloraSubstrates[0] = VeloraSubstrateLib.encodeTokenSubstrate(USDC);
veloraSubstrates[1] = VeloraSubstrateLib.encodeTokenSubstrate(WETH);
veloraSubstrates[2] = VeloraSubstrateLib.encodeTokenSubstrate(USDT);
veloraSubstrates[3] = VeloraSubstrateLib.encodeTokenSubstrate(DAI);

// Set slippage limit (2%)
veloraSubstrates[4] = VeloraSubstrateLib.encodeSlippageSubstrate(2e16);

// Apply configuration
MarketSubstratesConfig memory config = MarketSubstratesConfig(
    IporFusionMarkets.VELORA_SWAPPER,
    veloraSubstrates
);
```

## Slippage Protection

The fuse implements two levels of slippage protection:

### 1. Alpha-specified minAmountOut

Alpha provides explicit minimum output amount in the swap request. The swap reverts if actual output is less than `minAmountOut`.

```solidity
if (tokenOutDelta < data_.minAmountOut) {
    revert VeloraSwapperFuseMinAmountOutNotReached(data_.minAmountOut, tokenOutDelta);
}
```

### 2. USD-based Slippage Validation

The fuse calculates USD value of input and output tokens using PriceOracleMiddleware and validates that the exchange rate doesn't exceed the configured slippage limit.

```
quotient = USD_value_out / USD_value_in

if quotient < (1 - slippageLimit):
    revert VeloraSwapperFuseSlippageFail()
```

**Default Slippage**: 1% (1e16 WAD) if not configured in substrates.

**Range**: the slippage substrate must be `<= 1e18` (100%). Values above 1e18 are rejected by both `VeloraSubstrateLib.encodeSlippageSubstrate` and the fuse at read time (`VeloraSwapperFuseSlippageExceeds100Percent`). Exactly `1e18` is a valid configuration that **disables the USD bound**: the swap is then protected only by the ALPHA-supplied `minAmountOut`. Curators should treat `1e18` (and any value close to it) as "trust ALPHA fully" and set it only for markets where that is intended.

## Execution Flow

```
1. Alpha calls PlasmaVault.execute() with VeloraSwapperEnterData
2. PlasmaVault delegatecalls VeloraSwapperFuse.enter()
3. Fuse validates:
   - tokenIn is whitelisted in substrates
   - tokenOut is whitelisted in substrates
   - every tokensToReturn entry is whitelisted
   - tokenIn != tokenOut
   - amountIn > 0
4. Fuse records the executor's tokenIn/tokenOut balances before the swap
5. Fuse transfers tokenIn to VeloraSwapExecutor
6. Executor:
   a. Approves Augustus v6.2 for tokenIn
   b. Calls Augustus v6.2 with swapCallData
   c. Resets approval to 0
   d. Transfers remaining tokenIn back to PlasmaVault
   e. Transfers tokenOut to PlasmaVault
   f. Transfers every tokensToReturn balance to PlasmaVault
   g. Returns the tokenIn / tokenOut amounts it transferred to the fuse
7. Fuse computes spent / received from the executor return values and validates:
   - Actual output >= minAmountOut (alpha check)
   - USD slippage within limit
8. Fuse emits VeloraSwapperFuseEnter event
```

### Swap measurement (IL-8767)

`VeloraSwapExecutor.execute()` returns the `tokenIn` / `tokenOut` amounts it transferred back to the fuse. The fuse measures
the swap on the executor, **not** on the vault balances:

- `spent = amountIn + executorTokenInBefore - tokenInReturned` (0 means nothing of the vault's `tokenIn` was used and
  `enter` returns without emitting an event);
- `received = tokenOutReturned - executorTokenOutBefore` (a spend with `received == 0` reverts with
  `VeloraSwapperFuseSlippageFail`).

spent/received are the amounts the executor transferred, not the amounts the vault received: a token that delivers less than the nominal amount on transfer loosens minAmountOut and the USD slippage check by that difference on the final transfer. Do not grant tokens with an active transfer fee as tokenIn/tokenOut; stETH-style share rounding (1-2 wei) is accepted; USDT is accepted while its fee is 0 (Tether can set at most 19 bps, capped at 49 USDT per transfer).

`minAmountOut` and the USD slippage check use `spent` / `received`. Inflows to the vault during the call (for example a
permissionless "claim on behalf of the vault" executed by the route) therefore neither hide a `tokenIn` outflow nor
count as swap output. **Consequence:** the router must pay `tokenOut` to the executor (Velora: `userAddress`/`receiver` = executor). Output that does not reach the executor is not counted: `enter` reverts with `VeloraSwapperFuseSlippageFail` when nothing reaches it, and with `VeloraSwapperFuseMinAmountOutNotReached` or the USD check (`VeloraSwapperFuseSlippageFail`) when only part does. Each fuse deploys its own executor, so a new fuse brings a new executor address that the off-chain route builders must use.

## Usage

### Enter Data Structure

```solidity
struct VeloraSwapperEnterData {
    address tokenIn;              // Token to swap from
    address tokenOut;             // Token to swap to
    uint256 amountIn;             // Amount of tokenIn to swap
    uint256 minAmountOut;         // Minimum acceptable output (alpha slippage protection)
    bytes swapCallData;           // Raw calldata from Velora/ParaSwap API
    address[] tokensToReturn;     // Additional output/intermediate tokens the router may leave in the
                                   // executor (e.g. multi-output routes); each must be a granted token
                                   // substrate; swept to PlasmaVault in the same call. Limited to 256 entries.
}
```

### Obtaining swapCallData from ParaSwap API

1. **Get Prices** (find best route):
```bash
GET https://api.paraswap.io/prices?srcToken={tokenIn}&destToken={tokenOut}&amount={amountIn}&srcDecimals={decimals}&destDecimals={decimals}&network={chainId}&side=SELL
```

2. **Build Transaction** (get swap calldata):
```bash
POST https://api.paraswap.io/transactions/{chainId}
{
  "srcToken": "0xUSDC...",
  "destToken": "0xWETH...",
  "srcAmount": "1000000000",
  "destAmount": "300000000000000000",
  "priceRoute": { ... }, // Response from /prices
  "userAddress": "0x...", // Executor address
  "receiver": "0x...",    // Executor address
  "ignoreChecks": true    // Required for contract interactions
}
```

3. **Use response `data`** as `swapCallData`:
```json
{
  "to": "0x6A000F20005980200259B80c5102003040001068",
  "data": "0x...",  // <- This is swapCallData
  "value": "0"
}
```

### Executing Swap

```solidity
import {VeloraSwapperEnterData} from "./VeloraSwapperFuse.sol";
import {FuseAction, PlasmaVault} from "../../vaults/PlasmaVault.sol";

// Prepare swap data
VeloraSwapperEnterData memory enterData = VeloraSwapperEnterData({
    tokenIn: USDC,
    tokenOut: WETH,
    amountIn: 1000e6,           // 1000 USDC
    minAmountOut: 0.29 ether,   // Minimum ~0.29 WETH
    swapCallData: paraswapApiCalldata,
    tokensToReturn: new address[](0)   // list any extra output token the route may leave in the executor
});

// Create fuse action
FuseAction[] memory actions = new FuseAction[](1);
actions[0] = FuseAction(
    address(veloraSwapperFuse),
    abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes,address[]))", enterData)
);

// Execute via PlasmaVault
plasmaVault.execute(actions);
```

## Events

```solidity
event VeloraSwapperFuseEnter(
    address indexed version,    // Fuse deployment address
    address indexed tokenIn,    // Input token
    address indexed tokenOut,   // Output token
    uint256 tokenInDelta,       // Actual amount of tokenIn consumed
    uint256 tokenOutDelta       // Actual amount of tokenOut received
);
```

## Errors

| Error | Description |
|-------|-------------|
| `VeloraSwapperFuseUnsupportedAsset(address)` | Token not whitelisted in substrates (tokenIn, tokenOut, or a tokensToReturn entry) |
| `VeloraSwapperFuseMinAmountOutNotReached(uint256, uint256)` | Output less than minAmountOut |
| `VeloraSwapperFuseSlippageFail()` | USD slippage exceeds configured limit |
| `VeloraSwapperFuseZeroAmount()` | amountIn is zero |
| `VeloraSwapperFuseSameTokens()` | tokenIn and tokenOut are the same |
| `VeloraSwapperFuseInvalidMarketId()` | marketId is zero |
| `VeloraSwapperFuseInvalidPrice(address)` | Price oracle returned zero for asset |
| `VeloraSwapperFuseInvalidPriceOracleMiddleware()` | Price oracle middleware not configured |
| `VeloraSwapperFuseSlippageExceeds100Percent(uint256)` | Configured slippage substrate exceeds 100% (1e18 WAD) |
| `VeloraSubstrateLibSlippageExceeds100Percent(uint256)` | `encodeSlippageSubstrate` was called with a value above 1e18 |
| `VeloraSwapExecutorSwapFailed()` | Augustus v6.2 call failed |

## Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `AUGUSTUS_V6_2` | `0x6A000F20005980200259B80c5102003040001068` | Augustus v6.2 address |
| `DEFAULT_SLIPPAGE_WAD` | `1e16` | Default slippage limit (1%) |
| `MARKET_ID` | `43` | IporFusionMarkets.VELORA_SWAPPER |

## Security Considerations

1. **Stateless Fuse**: VeloraSwapperFuse has no storage variables (executed via delegatecall)
2. **SafeERC20**: All token transfers use OpenZeppelin SafeERC20
3. **Approval Cleanup**: Executor resets approval to 0 after swap
4. **Dual Slippage Protection**: Both alpha-specified and USD-based validation
5. **Token Whitelist**: Only tokens configured in substrates can be swapped
6. **CEI Pattern**: Checks-Effects-Interactions pattern in execution flow
7. **Same Token Protection**: Swapping token to itself is not allowed

### Residual tokens and accounting

- `VeloraSwapExecutor.execute()` is permissionless and pays `msg.sender`. Any token left in the executor after
  `enter()` is **not** held for the vault: it is available to whoever next calls `execute()` on the executor
  (e.g. `execute(token, token, 0, "", [])`), typically the next block. Augustus routes with multiple output
  tokens, partial fills, or rebate tokens can all leave a residual. List every possible extra output token in
  `tokensToReturn` so it is swept to PlasmaVault in the same call instead of being stranded.
- A token returned to PlasmaVault is counted in `totalAssets()` only if it is the vault's underlying asset
  (counted immediately as idle), or if it is granted under `ERC20_VAULT_BALANCE` (market 7) **and**
  `VELORA_SWAPPER` is included in that market's dependency graph. `IporFusionMarkets.sol` does not currently
  declare that dependency for `VELORA_SWAPPER` (unlike `UNIVERSAL_TOKEN_SWAPPER`, see `:36-39`), so a
  `tokenOut`/`tokensToReturn` token other than the vault's underlying is invisible to `totalAssets()` unless the
  vault's governance configures market 7 accordingly. This is pre-existing behaviour for `tokenOut`, now also
  documented for `tokensToReturn`. Per policy, fuses do not police grant/revoke consequences or missing
  dependency-graph configuration; this is a documentation note, not an enforced guard.
- `VeloraSwapExecutor.execute()` has no access control (SEC-001, see `testExecutorCanBeCalledDirectlyByAnyone`).
  `tokensToReturn` does not widen this: anyone who could already drain a token from the executor one call at a
  time can still do so; the new parameter only lets the *fuse* sweep several tokens atomically instead of
  leaving them for a permissionless third-party call. Adding access control to the executor is a separate,
  out-of-scope follow-up.

## Testing

```bash
# Run all Velora fuse tests
forge test --match-path "test/fuses/velora/*" -vv

# Run fork integration test
forge test --match-test "testShouldSwapUsdcToWethOnArbitrumFork" -vvv
```

## References

- [ParaSwap Documentation](https://developers.paraswap.network)
- [ParaSwap API Reference](https://developers.paraswap.network/api/get-rate-for-a-token-pair)
- [ParaSwap Smart Contracts](https://developers.paraswap.network/smart-contracts)
- [IPOR Fusion Documentation](https://docs.ipor.io)
