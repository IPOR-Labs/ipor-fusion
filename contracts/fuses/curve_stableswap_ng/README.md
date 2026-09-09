# Curve StableSwap-NG Single-Side Integration

## Overview

The Curve StableSwap-NG integration lets an IPOR Fusion Plasma Vault add liquidity to a
Curve StableSwap-NG pool with a single coin and remove liquidity back into a single coin.
A StableSwap-NG pool is its own LP token, so one substrate address identifies both the pool
and the token the vault holds after entering.

Staking the LP token in a Curve gauge is a separate integration,
[`contracts/fuses/curve_gauge/`](../curve_gauge/README.md), on its own market.

## Market Structure

The integration uses a single market:

- **Market ID 16** (`CURVE_POOL`) — `add_liquidity` / `remove_liquidity_one_coin`

## Architecture

### Key Components

- **`CurveStableswapNGSingleSideSupplyFuse`** — enters and exits a pool single-sided.
- **`CurveStableswapNGSingleSideBalanceFuse`** — values the LP tokens the vault holds.

### CurveStableswapNGSingleSideSupplyFuse

`enter(CurveStableswapNGSingleSideSupplyFuseEnterData)` — selector `0x2242c270`

| Field                      | Type                 | Meaning                                                                     |
| -------------------------- | -------------------- | --------------------------------------------------------------------------- |
| `curveStableswapNG`        | `ICurveStableswapNG` | Pool (= LP token) to enter; must be a granted substrate of market 16        |
| `asset`                    | `address`            | Coin to deposit; must be one of the pool's `coins()`                        |
| `assetAmount`              | `uint256`            | Amount in the coin's smallest unit; `0` is a no-op                          |
| `minLpTokenAmountReceived` | `uint256`            | Slippage floor on LP tokens minted (18 decimals), passed to `add_liquidity` |

`exit(CurveStableswapNGSingleSideSupplyFuseExitData)` — selector `0xf753aa96`

| Field                   | Type                 | Meaning                                                                                                                                                            |
| ----------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `curveStableswapNG`     | `ICurveStableswapNG` | Pool to exit; must be a granted substrate                                                                                                                          |
| `lpTokenAmount`         | `uint256`            | LP tokens to burn (18 decimals); `0` is a no-op                                                                                                                    |
| `asset`                 | `address`            | The single coin to receive; must be one of the pool's `coins()`                                                                                                    |
| `minCoinAmountReceived` | `uint256`            | Slippage floor in the coin's smallest unit; a failing `remove_liquidity_one_coin` is caught and only emits `CurveSupplyStableswapNGSingleSideSupplyFuseExitFailed` |

Both operations also exist as `enterTransient()` / `exitTransient()` reading the same values
from transient storage (`TransientStorageLib`) for fuse chaining.

Errors: `CurveStableswapNGSingleSideSupplyFuseUnsupportedPool(address)` when the pool is not a
substrate, `CurveStableswapNGSingleSideSupplyFuseUnsupportedPoolAsset(address)` when the coin
is not in the pool.

## Balance Calculation

`CurveStableswapNGSingleSideBalanceFuse.balanceOf()` iterates the market substrates. For each
pool with a nonzero LP balance it values every coin pro rata:

```
coinAmount_j = pool.balances(j) * lpBalance / pool.totalSupply()
balance    += convertToWad(coinAmount_j * price(coin_j), decimals(coin_j) + priceDecimals)
```

The result is USD in 18 decimals. Gauge rewards and staked LP tokens are not included here.

## Substrate Configuration

Substrates are the **pool addresses** (address-shaped, granted with
`PlasmaVaultGovernance.grantMarketSubstrates` through
`PlasmaVaultConfigLib.grantSubstratesAsAssetsToMarket`). The fuse checks
`PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, pool)` on enter and exit; the
balance fuse iterates the same list. The code comment says "substrateAsAsset here refers to
the Curve pool LP token" — for StableSwap-NG that is the pool itself.

## Price Oracle Setup

A price source is required for **every coin of every substrate pool**, configured through the
vault's Price Oracle Middleware (or its Manager). A pool with a coin the middleware cannot
price makes `balanceOf()` revert.

## Roles

- `ALPHA_ROLE` (200) executes the fuse through `PlasmaVault.execute`.
- `FUSE_MANAGER_ROLE` (300) adds the fuses and grants substrates.
- `ATOMIST_ROLE` (100) sets the market limit.
- `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE` (1200) adds price sources.

## Tests

- `test/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideSupplyFuseArbitrumTest.t.sol` (Arbitrum fork)
- `test/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideBalanceFuseArbitrumTest.t.sol` (Arbitrum fork)
- `test/integrationTest/curveGaugesArbitrum/*.t.sol` (Arbitrum fork, together with the gauge market)

## Deployments

See `catalog/fuses.json`, entry `ethereum-curve-stableswap-ng-market-16`, for the fuse addresses
observed on Ethereum and the block they were read at. The catalog, not this file, is the
place for addresses.

## Security Notes

- `exit` swallows a failing `remove_liquidity_one_coin` (event only, returns `0`); callers
  must check the received amount rather than rely on a revert.
- Single-sided entry and exit pay the pool's imbalance fee; the `min*` fields are the only
  slippage protection.
