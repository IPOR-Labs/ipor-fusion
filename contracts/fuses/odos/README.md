# Odos Swapper Fuse

Integration with [Odos Protocol](https://docs.odos.xyz) for optimized token swapping via Smart Order Routing V3 in IPOR Fusion PlasmaVault.

## Overview

OdosSwapperFuse enables PlasmaVault to execute token swaps using Odos aggregator, which finds optimal routing across multiple DEXs. The integration uses Odos Router V3 with compressed calldata for gas-efficient execution on L2 networks.

### Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│   PlasmaVault   │────>│  OdosSwapperFuse │────>│ OdosSwapExecutor │
│  (delegatecall) │     │   (validation)   │     │  (Odos Router)   │
└─────────────────┘     └──────────────────┘     └──────────────────┘
                                                          │
                                                          v
                                                 ┌──────────────────┐
                                                 │ Odos Router V3   │
                                                 │ 0x0D05...0D05    │
                                                 └──────────────────┘
```

## Contracts

| Contract | Description |
|----------|-------------|
| `OdosSwapperFuse.sol` | Main fuse contract with validation logic (executed via delegatecall) |
| `OdosSwapExecutor.sol` | Executor contract that interacts with Odos Router V3 |
| `OdosSubstrateLib.sol` | Library for encoding/decoding substrate configuration |

## Key Features

- **Smart Order Routing**: Leverages Odos SOR V3 for optimal swap execution
- **Dual Slippage Protection**:
  - Alpha-specified `minAmountOut` check
  - USD-based slippage validation via PriceOracleMiddleware
- **Substrate-based Configuration**: Token whitelist and slippage limits via market substrates
- **Gas Optimized**: Uses Odos `swapCompact()` with compressed calldata

## Odos Router V3

**Address (same on all EVM chains):**
```
0x0D05a7D3448512B78fa8A9e46c4872C88C4a0D05
```

This address is identical on: Ethereum, Arbitrum, Optimism, Base, Polygon, BNB Chain, Avalanche, zkSync Era, Linea, Scroll, Mantle, and other supported networks.

## Substrate Configuration

Substrates are used to configure allowed tokens and slippage limits for the Odos market. Each substrate is a `bytes32` value with type information encoded in the first byte.

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

### Using OdosSubstrateLib

```solidity
import {OdosSubstrateLib} from "./OdosSubstrateLib.sol";

// Encode token substrate
bytes32 usdcSubstrate = OdosSubstrateLib.encodeTokenSubstrate(USDC_ADDRESS);
bytes32 wethSubstrate = OdosSubstrateLib.encodeTokenSubstrate(WETH_ADDRESS);

// Encode slippage substrate (2% = 2e16 WAD)
bytes32 slippageSubstrate = OdosSubstrateLib.encodeSlippageSubstrate(2e16);

// Decode substrate type
OdosSubstrateType substrateType = OdosSubstrateLib.decodeSubstrateType(substrate);

// Check substrate type
bool isToken = OdosSubstrateLib.isTokenSubstrate(substrate);
bool isSlippage = OdosSubstrateLib.isSlippageSubstrate(substrate);

// Decode values
address token = OdosSubstrateLib.decodeToken(tokenSubstrate);
uint256 slippage = OdosSubstrateLib.decodeSlippage(slippageSubstrate);
```

### Configuration Example

```solidity
// Configure Odos market substrates
bytes32[] memory odosSubstrates = new bytes32[](5);

// Whitelist tokens
odosSubstrates[0] = OdosSubstrateLib.encodeTokenSubstrate(USDC);
odosSubstrates[1] = OdosSubstrateLib.encodeTokenSubstrate(WETH);
odosSubstrates[2] = OdosSubstrateLib.encodeTokenSubstrate(USDT);
odosSubstrates[3] = OdosSubstrateLib.encodeTokenSubstrate(DAI);

// Set slippage limit (2%)
odosSubstrates[4] = OdosSubstrateLib.encodeSlippageSubstrate(2e16);

// Apply configuration
MarketSubstratesConfig memory config = MarketSubstratesConfig(
    IporFusionMarkets.ODOS_SWAPPER,
    odosSubstrates
);
```

## Slippage Protection

The fuse implements two levels of slippage protection:

### 1. Alpha-specified minAmountOut

Alpha provides explicit minimum output amount in the swap request. The swap reverts if actual output is less than `minAmountOut`.

```solidity
if (tokenOutDelta < data_.minAmountOut) {
    revert OdosSwapperFuseMinAmountOutNotReached(data_.minAmountOut, tokenOutDelta);
}
```

### 2. USD-based Slippage Validation

The fuse calculates USD value of input and output tokens using PriceOracleMiddleware and validates that the exchange rate doesn't exceed the configured slippage limit.

```
quotient = USD_value_out / USD_value_in

if quotient < (1 - slippageLimit):
    revert OdosSwapperFuseSlippageFail()
```

**Default Slippage**: 1% (1e16 WAD) if not configured in substrates.

## Execution Flow

```
1. Alpha calls PlasmaVault.execute() with OdosSwapperEnterData
2. PlasmaVault delegatecalls OdosSwapperFuse.enter()
3. Fuse validates:
   - tokenIn is whitelisted in substrates
   - tokenOut is whitelisted in substrates
   - amountIn > 0
4. Fuse records balances before swap
5. Fuse transfers tokenIn to OdosSwapExecutor
6. Executor:
   a. Approves Odos Router for tokenIn
   b. Calls Odos Router with swapCallData
   c. Resets approval to 0
   d. Transfers remaining tokenIn back to PlasmaVault
   e. Transfers tokenOut to PlasmaVault
7. Fuse validates:
   - Actual output >= minAmountOut (alpha check)
   - USD slippage within limit
8. Fuse emits OdosSwapperFuseEnter event
```

## Usage

### Enter Data Structure

```solidity
struct OdosSwapperEnterData {
    address tokenIn;       // Token to swap from
    address tokenOut;      // Token to swap to
    uint256 amountIn;      // Amount of tokenIn to swap
    uint256 minAmountOut;  // Minimum acceptable output (alpha slippage protection)
    bytes swapCallData;    // Raw calldata from Odos API (/sor/quote/v3 response)
}
```

### Obtaining swapCallData from Odos API

**Important**: Use `/sor/quote/v3` endpoint (not v2) to get calldata for Router V3.

1. **Get Quote**:
```bash
POST https://api.odos.xyz/sor/quote/v3
{
  "chainId": 42161,
  "inputTokens": [{"tokenAddress": "0xUSDC...", "amount": "1000000000"}],
  "outputTokens": [{"tokenAddress": "0xWETH...", "proportion": 1}],
  "userAddr": "0x0000000000000000000000000000000000000000",
  "slippageLimitPercent": 1.0
}
```

**Note**: Set `userAddr` to `0x0` so that output tokens are sent to `msg.sender` (the executor), which then forwards them to PlasmaVault.

2. **Use response `transaction.data`** as `swapCallData`:
```json
{
  "transaction": {
    "to": "0x0D05a7D3448512B78fa8A9e46c4872C88C4a0D05",
    "data": "0x83bd37f9...",  // <- This is swapCallData
    "value": "0"
  }
}
```

### Executing Swap

```solidity
import {OdosSwapperEnterData} from "./OdosSwapperFuse.sol";
import {FuseAction, PlasmaVault} from "../../vaults/PlasmaVault.sol";

// Prepare swap data
OdosSwapperEnterData memory enterData = OdosSwapperEnterData({
    tokenIn: USDC,
    tokenOut: WETH,
    amountIn: 1000e6,           // 1000 USDC
    minAmountOut: 0.29 ether,   // Minimum ~0.29 WETH
    swapCallData: odosApiCalldata
});

// Create fuse action
FuseAction[] memory actions = new FuseAction[](1);
actions[0] = FuseAction(
    address(odosSwapperFuse),
    abi.encodeWithSignature("enter((address,address,uint256,uint256,bytes))", enterData)
);

// Execute via PlasmaVault
plasmaVault.execute(actions);
```

## Events

```solidity
event OdosSwapperFuseEnter(
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
| `OdosSwapperFuseUnsupportedAsset(address)` | Token not whitelisted in substrates |
| `OdosSwapperFuseMinAmountOutNotReached(uint256, uint256)` | Output less than minAmountOut |
| `OdosSwapperFuseSlippageFail()` | USD slippage exceeds configured limit |
| `OdosSwapperFuseZeroAmount()` | amountIn is zero |
| `OdosSwapperFuseInvalidMarketId()` | marketId is zero |
| `OdosSwapExecutorSwapFailed()` | Odos Router call failed |

## Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `ODOS_ROUTER` | `0x0D05a7D3448512B78fa8A9e46c4872C88C4a0D05` | Odos Router V3 address |
| `DEFAULT_SLIPPAGE_WAD` | `1e16` | Default slippage limit (1%) |
| `MARKET_ID` | `42` | IporFusionMarkets.ODOS_SWAPPER |

## Security Considerations

1. **Stateless Fuse**: OdosSwapperFuse has no storage variables (executed via delegatecall)
2. **SafeERC20**: All token transfers use OpenZeppelin SafeERC20
3. **Approval Cleanup**: Executor resets approval to 0 after swap
4. **Dual Slippage Protection**: Both alpha-specified and USD-based validation
5. **Token Whitelist**: Only tokens configured in substrates can be swapped
6. **CEI Pattern**: Checks-Effects-Interactions pattern in execution flow

## Testing

```bash
# Run all Odos fuse tests
forge test --match-path "test/fuses/odos/*" -vv

# Run fork integration test
forge test --match-test "testShouldSwapUsdcToWethOnArbitrumFork" -vvv
```

## References

- [Odos Documentation](https://docs.odos.xyz)
- [Odos API Reference](https://docs.odos.xyz/api/endpoints)
- [Odos Contracts](https://docs.odos.xyz/build/contracts)
- [IPOR Fusion Documentation](https://docs.ipor.io)
