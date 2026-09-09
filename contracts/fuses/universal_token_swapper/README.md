# Universal Token Swapper Integration

## Overview

The Universal Token Swapper lets an IPOR Fusion Plasma Vault swap one ERC20 token for another
on any DEX or aggregator, without a dedicated fuse per venue. The vault hands `amountIn` of
`tokenIn` to a small executor contract, the executor performs an arbitrary list of calls
(`targets` / calldata prepared off-chain, for example by an aggregator API), and sweeps
`tokenIn`, `tokenOut` (and optionally ETH and dust tokens) back to the vault. The fuse then
measures the balance deltas on the vault and enforces the rate limits.

The integration is a set of four fuses over two markets:

| Fuse                                        | Executor               | Rate protection                                            | Substrate encoding                                                         |
| ------------------------------------------- | ---------------------- | ---------------------------------------------------------- | -------------------------------------------------------------------------- |
| `UniversalTokenSwapperFuse`                 | `SwapExecutor` (ERC20) | `minAmountOut` + USD slippage (substrate or 1% default)    | typed bytes32 (`UniversalTokenSwapperSubstrateLib`)                        |
| `UniversalTokenSwapperEthFuse`              | `SwapExecutorEth`      | `minAmountOut` + USD slippage (substrate or 1% default)    | typed bytes32 (`UniversalTokenSwapperSubstrateLib`)                        |
| `UniversalTokenSwapperEthFuseNoSlippage`    | `SwapExecutorEth`      | none                                                       | plain addresses (`isSubstrateAsAssetGranted`)                              |
| `UniversalTokenSwapperWithVerificationFuse` | `SwapExecutorEth`      | USD slippage fixed in the constructor (`SLIPPAGE_REVERSE`) | `(functionSelector << 224) \| target` (`toBytes32`, selector 0 for tokens) |

`SwapExecutorRestricted` is an ERC20-only executor variant that rejects native ETH and only
accepts calls from one configured address; it is exercised by `SwapExecutorTest.t.sol` and is
not created by any fuse in this checkout.

## Market Structure

- **Market ID 12** (`UNIVERSAL_TOKEN_SWAPPER`) — the original swapper market.
- **Market ID 1202** (`UNIVERSAL_TOKEN_SWAPPER_V2`, written `12_02` in Solidity) — the same
  fuses redeployed with the typed substrate scheme (Token / Target / Slippage).

Both markets need a **dependency graph** link to `ERC20_VAULT_BALANCE` (market 7): a swap
changes only idle balances, and the swapper market itself is valued by a `ZeroBalanceFuse`.

## Architecture

### `UniversalTokenSwapperFuse` (primary)

`enter(UniversalTokenSwapperEnterData)` — selector `0xc674d752`

| Field          | Type        | Meaning                                                                                         |
| -------------- | ----------- | ----------------------------------------------------------------------------------------------- |
| `tokenIn`      | `address`   | token transferred from the vault to the executor; must be a granted Token substrate             |
| `tokenOut`     | `address`   | token expected back on the vault; must be a granted Token substrate                             |
| `amountIn`     | `uint256`   | amount moved to the executor, in `tokenIn` smallest units; `0` reverts                          |
| `minAmountOut` | `uint256`   | floor on the `tokenOut` delta, in `tokenOut` smallest units; `0` disables it                    |
| `data.targets` | `address[]` | contracts the executor calls, in order; every one must be a granted Target substrate; non-empty |
| `data.data`    | `bytes[]`   | calldata for each target; same length as `targets`                                              |

Flow: `_validateSubstrates` reads all market substrates once; the fuse transfers `amountIn` to
`EXECUTOR` (a `SwapExecutor` created in the fuse constructor); `SwapExecutor.execute` runs the
calls and transfers any `tokenIn` / `tokenOut` it holds back to the vault; the fuse computes
`tokenInDelta` / `tokenOutDelta` from the vault's balances. If no `tokenIn` was consumed the
call is a no-op (zero deltas are emitted). Otherwise a zero `tokenOut` delta reverts
(`UniversalTokenSwapperFuseSlippageFail`), `minAmountOut` is enforced, and the USD value of
the deltas (prices from `PlasmaVaultLib.getPriceOracleMiddleware()`) must satisfy
`usdOut / usdIn >= 1 - slippageWad`. There is no `exit`: a swap has no position to leave.

`enterTransient()` reads the same inputs from transient storage (`minAmountOut` is `0` there).

### `UniversalTokenSwapperEthFuse`

`enter(UniversalTokenSwapperEthEnterData)` — selector `0x8f605271`. Same fields as the primary
fuse plus, inside `data`: `callDatas`, `ethAmounts` (native value forwarded with each call) and
`tokensDustToCheck` (extra tokens the executor sweeps back; each must be a granted Token
substrate). The `SwapExecutorEth` (created in the constructor with the WETH address) wraps any
ETH left on it into WETH and returns it to the vault.

### `UniversalTokenSwapperEthFuseNoSlippage`

`enter(UniversalTokenSwapperEthEnterDataNoSlippage)` — selector `0x44ce06fa`. Same executor
data as the Eth fuse, **no** `minAmountOut` and **no** USD check: the emitted deltas are
informational only. Substrates are plain addresses (tokens, targets and dust tokens are all
checked with `PlasmaVaultConfigLib.isSubstrateAsAssetGranted`). The executor address is a
constructor argument.

### `UniversalTokenSwapperWithVerificationFuse`

`enter(UniversalTokenSwapperWithVerificationEnterData)` — selector `0x44ce06fa` (same tuple
shape as the NoSlippage fuse). Every `(target, first 4 bytes of callData)` pair must be granted
as `toBytes32(UniversalTokenSwapperSubstrate{functionSelector, target})`; tokens and dust
tokens are granted with selector `0x00000000`. The USD slippage limit is fixed at deployment
(`SLIPPAGE_REVERSE = 1e18 - slippageReverse_`); `amountIn == 0` returns zero deltas without
calling the executor.

### Executors

- `SwapExecutor` — ERC20 only; `execute(SwapExecutorData)` runs `dexs[i].functionCall(dexsData[i])`
  and returns remaining `tokenIn` / `tokenOut` to `msg.sender` (the vault). `nonReentrant`.
- `SwapExecutorEth` — adds `ethAmounts` per call, wraps leftover ETH to WETH, sweeps
  `tokensDustToCheck`. Has a `receive()`.
- `SwapExecutorRestricted` — ERC20 only, single allowed caller, rejects ETH.

Executors hold funds only within one `execute` call; they perform no approvals of their own —
approvals to the DEX must be part of the prepared calldata.

## Balance Calculation

The markets have no balance fuse of their own: they are registered with a `ZeroBalanceFuse`
(always `0`). The tokens live on the vault and are valued by the ERC20 balance market, which is
why the dependency graph must refresh market 7 after a swap.

## Substrate Configuration

Market 1202 (and the checkout's primary and Eth fuse on any market) uses typed `bytes32`
substrates from `UniversalTokenSwapperSubstrateLib`:

| Type       | Byte 0 | Payload                     | Encoder                   |
| ---------- | ------ | --------------------------- | ------------------------- |
| `Token`    | `1`    | address in the low 20 bytes | `encodeTokenSubstrate`    |
| `Target`   | `2`    | address in the low 20 bytes | `encodeTargetSubstrate`   |
| `Slippage` | `3`    | `uint248` slippage in WAD   | `encodeSlippageSubstrate` |

Without a `Slippage` substrate the default is `DEFAULT_SLIPPAGE_WAD = 1e16` (1%); a value above
`1e18` reverts. The NoSlippage fuse expects plain addresses, the WithVerification fuse expects
its own `(selector, target)` packing — a vault that registers several of these fuses on one
market must grant substrates in every encoding its fuses read.

Grant with `PlasmaVaultGovernance.grantMarketSubstrates(marketId, bytes32[])`.

## Price Oracle Setup

The primary, Eth and WithVerification fuses call `getAssetPrice` on the vault's
`PriceOracleMiddleware` for `tokenIn` and `tokenOut`; a missing middleware or a zero price
reverts. The NoSlippage fuse needs no prices.

## Roles

- `ALPHA_ROLE` (200) executes the fuse through `PlasmaVault.execute`.
- `FUSE_MANAGER_ROLE` (300) registers the fuses and the `ZeroBalanceFuse`, grants substrates.
- `ATOMIST_ROLE` (100) sets the market limit (irrelevant for a zero-valued market, but the
  dependency graph must be configured).
- `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE` (1200) adds the price sources.

## Deployments

See `catalog/fuses.json` (`ethereum-universal-token-swapper-market-12`,
`ethereum-universal-token-swapper-v2-market-1202`) for the Ethereum addresses read at block
25939091 from the IPOR-Labs/ipor-abi registry. Two facts matter before encoding a call:

- The market-12 fuse most production vaults hold, `SwapFuseUniversalTokenSwapper`
  `0x08dFdBB6Ecf19f1fc974E0675783E1150B2B650F`, answers
  `enter((address,address,uint256,(address[],bytes[])))` `0x950ca9fa` — a struct **without**
  `minAmountOut` and with a constructor-fixed slippage. Encoding this checkout's
  `UniversalTokenSwapperEnterData` against it reverts.
- The market-1202 deployments (`…FuseV2`, `…V2`) carry this checkout's selectors and
  `enterTransient()`; the market-12 ones named after the sources carry the selectors but not
  `enterTransient()` (older builds).

## Tests

Fork (Ethereum, blocks 20590113 and 22266405):
`test/fuses/universal_token_swapper/UniversalSwapOnUniswapV2FuseTest.t.sol`,
`UniversalSwapOnUniswapV3SwapFuseTest.t.sol`, `UniversalSwapOnMockDexTest.t.sol`,
`UniversalSwapEthOnUniswapV3SwapFuseTest.t.sol`, `UniversalSwapEthNoSlippageFuseTest.t.sol`,
`UniversalTokenSwapperSlippageForkTest.t.sol`, `UniversalTokenSwapperWithVerificationFuseTest.t.sol`.

Local (no fork): `SwapExecutorTest.t.sol` (14), `UniversalTokenSwapperSubstrateLibTest.t.sol`
(21), `UniversalTokenSwapperWithVerificationFuse.t.sol` (3).

## Security Notes

- The executor executes arbitrary calldata against granted targets; the Target substrates are
  the only thing that bounds what a swap can touch. Grant routers, not tokens, as targets.
- Rate protection differs per fuse: the NoSlippage fuse has none by design; prefer
  `minAmountOut` on the primary/Eth fuses for anything price-sensitive.
- The executor never approves anything itself, but the prepared calldata may leave an allowance
  from the executor to a DEX; the executor holds no funds between calls, so such allowances are
  harmless to the vault.
- `minAmountOut` is not available through `enterTransient()`.
