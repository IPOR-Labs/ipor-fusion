# Uniswap Fuses

Fuses integrating the PlasmaVault with Uniswap V2, V3 and V4. All fuses are stateless contracts executed via `delegatecall` from the PlasmaVault, so `address(this)` inside a fuse is the vault itself. Position tokenIds are tracked in dedicated `FuseStorageLib` slots (separate for V3 and V4).

## Contracts

| Contract | Type | Market ID | Purpose |
|---|---|---|---|
| `UniswapV2SwapFuse` | action | `UNISWAP_SWAP_V2` (9) | Exact-input swaps through V2 pools via the Universal Router |
| `UniswapV3SwapFuse` | action | `UNISWAP_SWAP_V3` (10) | Exact-input swaps through V3 pools via the Universal Router |
| `UniswapV3NewPositionFuse` | action | `UNISWAP_SWAP_V3_POSITIONS` (8) | Mint / burn V3 concentrated liquidity positions (NFTs) |
| `UniswapV3ModifyPositionFuse` | action | `UNISWAP_SWAP_V3_POSITIONS` (8) | Increase / decrease liquidity of an existing V3 position |
| `UniswapV3CollectFuse` | action | `UNISWAP_SWAP_V3_POSITIONS` (8) | Collect owed tokens (fees + decreased principal) from V3 positions |
| `UniswapV3Balance` | balance | `UNISWAP_SWAP_V3_POSITIONS` (8) | USD (WAD) valuation of all tracked V3 positions |
| `UniswapV4NewPositionFuse` | action | `UNISWAP_V4` (53) | Mint / burn V4 concentrated liquidity positions (NFTs) |
| `UniswapV4ModifyPositionFuse` | action | `UNISWAP_V4` (53) | Increase / decrease liquidity of an existing V4 position |
| `UniswapV4CollectFuse` | action | `UNISWAP_V4` (53) | Collect accrued fees from V4 positions (zero-liquidity decrease) |
| `UniswapV4Balance` | balance | `UNISWAP_V4` (53) | USD (WAD) valuation of all tracked V4 positions |
| `UniswapV4SubstrateLib` | library | — | Substrate gating (PoolId + tokens) shared by the V4 fuses |

`ext/` contains vendored Uniswap periphery interfaces and math libraries (`INonfungiblePositionManager`, `PositionValue`, `IUniversalRouter`, …); `ext/v4/` contains the V4 counterparts (`IPositionManagerV4`, `ActionsV4`, `LiquidityAmountsV4`, `PositionInfoLib`).

## Substrate configuration

Substrates are granted per market via `PlasmaVaultGovernance.grantMarketSubstrates`.

### V2 / V3 (markets 8, 9, 10) — tokens only

Grant every token the vault may touch as **substrate-as-asset** (`PlasmaVaultConfigLib.substrateAsAssetToBytes32(token)`):

- Swap fuses validate **every token in the swap path** (including intermediate hops).
- V3 position fuses validate `token0` and `token1` of the pool.
- The pool itself is **not** a substrate in V3 — any fee tier / pool for granted tokens is allowed.

### V4 (market 53) — pool + tokens (two-level whitelist)

`UniswapV4SubstrateLib.checkPoolKeyGranted` requires **both**:

1. **PoolId** granted as a raw market substrate: `bytes32 poolId = keccak256(abi.encode(poolKey))` (`UniswapV4SubstrateLib.poolKeyToId(poolKey)`). Because the `PoolKey` includes the hook address, fee and tick spacing, granting a PoolId transitively whitelists that exact pool configuration — including its hook.
2. **Both currencies** granted as substrate-as-asset (needed for price-oracle valuation in `UniswapV4Balance` and for asset distribution protection).

Native-currency pools (`currency0 == address(0)`) are **rejected** — the vault holds ERC-20 only and the price oracle has no feed for the zero address.

```solidity
bytes32[] memory substrates = new bytes32[](3);
substrates[0] = UniswapV4SubstrateLib.poolKeyToId(poolKey);                    // pool
substrates[1] = PlasmaVaultConfigLib.substrateAsAssetToBytes32(token0);        // currency0
substrates[2] = PlasmaVaultConfigLib.substrateAsAssetToBytes32(token1);        // currency1
governance.grantMarketSubstrates(IporFusionMarkets.UNISWAP_V4, substrates);
```

## Usage

### Swaps (V2 / V3)

Constructor: `(marketId, universalRouter)`. `enter` transfers the input token to the Universal Router and executes a `V3_SWAP_EXACT_IN` / V2 swap command; output is returned to the vault. Slippage is controlled with `minOutAmount`.

### V3 position lifecycle

Constructor: `NewPosition`/`Modify`/`Collect` take `(marketId, nonfungiblePositionManager)`; `UniswapV3Balance` takes `(marketId, nonfungiblePositionManager, uniswapFactory)`.

1. `UniswapV3NewPositionFuse.enter` — mints a position NFT (`token0`, `token1`, `fee`, tick range, desired/min amounts) and registers the tokenId in fuse storage. The pool must already exist and be initialized.
2. `UniswapV3ModifyPositionFuse.enter` / `exit` — increases / decreases liquidity. **Decrease only accrues owed tokens on the NFT — it does not transfer them to the vault.**
3. `UniswapV3CollectFuse.enter` — calls `collect`, transferring owed tokens (fees + previously decreased principal) to the vault.
4. `UniswapV3NewPositionFuse.exit` — burns NFTs (liquidity must be 0 and everything collected first) and unregisters the tokenIds.

Typical full close in one `FuseAction` batch: `Modify.exit` (decrease to 0) → `Collect.enter` → `NewPosition.exit` (burn).

### V4 position lifecycle

Constructor: `NewPosition`/`Modify` take `(marketId, positionManager, poolManager, permit2)`; `Collect` takes `(marketId, positionManager)`; `UniswapV4Balance` takes `(marketId, positionManager, poolManager)`.

Pools are identified by a full `PoolKey` struct (`currency0`, `currency1`, `fee`, `tickSpacing`, `hooks`); `hookData` is forwarded to the pool's hook (empty for hookless pools). Token payments go through **Permit2** (approvals are set before the call and reset to zero afterwards).

1. `UniswapV4NewPositionFuse.enter` — computes liquidity from desired amounts and the current pool price, then `MINT_POSITION + SETTLE_PAIR`; `amount0Max`/`amount1Max` are the slippage caps. TokenId is registered in fuse storage.
2. `UniswapV4ModifyPositionFuse.enter` / `exit` — `INCREASE_LIQUIDITY + SETTLE_PAIR` / `DECREASE_LIQUIDITY + TAKE_PAIR`. **Decrease transfers principal plus all accrued fees to the vault in the same call** — no separate collect needed.
3. `UniswapV4CollectFuse.enter` — realizes fees via `DECREASE_LIQUIDITY(0) + TAKE_PAIR` (V4 has no dedicated collect). Zero-liquidity positions are skipped (poking them reverts in v4-core and they have no pending fees).
4. `UniswapV4NewPositionFuse.exit` — `BURN_POSITION + TAKE_PAIR`; returns principal + fees to the vault and unregisters the tokenId. Works in one step regardless of remaining liquidity.

The V4 fuses only operate on tokenIds registered by `UniswapV4NewPositionFuse.enter` (`TokenIdNotTracked` otherwise) — NFTs transferred to the vault out-of-band cannot be managed or corrupted in storage.

All action fuses also expose `enterTransient`/`exitTransient` variants reading parameters from `TransientStorageLib`. V4 transient variants always use empty `hookData`, so they do not support pools whose hooks require non-empty `hookData`; use the regular `enter`/`exit` functions for such pools.

### Balance fuses

Both balance fuses iterate the tokenIds tracked in fuse storage and return the total USD value in WAD. `UniswapV3Balance` uses `PositionValue.total()` (principal + fees). `UniswapV4Balance` composes the value from core reads (`getSlot0` price → principal, fee-growth deltas → pending fees), since V4 has no `PositionValue` equivalent. Every pool token must have a price feed in the price oracle middleware.

## Key V3 vs V4 differences

| Aspect | V3 | V4 |
|---|---|---|
| Pool identity | `token0` + `token1` + `fee`; pool is a separate contract from the factory | `PoolKey` (`currency0`, `currency1`, `fee`, `tickSpacing`, `hooks`); pools live inside the singleton `PoolManager`, identified by `PoolId = keccak256(abi.encode(poolKey))` |
| Substrates | tokens only (substrate-as-asset) | PoolId as market substrate **and** both tokens as substrate-as-asset |
| Hooks | n/a | hook address is part of the PoolKey (whitelisted via the PoolId); `hookData` parameter on enter/exit |
| Token payments | direct ERC-20 approvals to the NonfungiblePositionManager | via Permit2 (`approve` before, reset to 0 after) |
| Slippage on mint/increase | `amount0Min`/`amount1Min` (minimum spent) | `amount0Max`/`amount1Max` (maximum spent); liquidity is precomputed from desired amounts and the current price |
| Decrease liquidity | only accrues owed tokens on the NFT; separate `Collect` required to receive them | `TAKE_PAIR` transfers principal + all accrued fees to the vault in the same call |
| Collect fees | dedicated `collect()` call | no dedicated call — zero-liquidity decrease + `TAKE_PAIR`; zero-liquidity positions are skipped |
| Burn position | requires liquidity = 0 and fees collected first (decrease → collect → burn) | `BURN_POSITION` closes the position in one step, returning principal + fees |
| Native currency | n/a (WETH pools) | native-currency pools rejected by `UniswapV4SubstrateLib` |
| TokenId tracking | tokenIds registered on mint | tokenIds registered on mint; all V4 fuses additionally **require** the tokenId to be tracked |
| Valuation | `PositionValue.total()` on the position manager | composed from `PoolManager` core reads (slot0 price + fee growth deltas) |
