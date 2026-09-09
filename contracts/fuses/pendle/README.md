# Pendle Integration

## Overview

The Pendle integration lets a PlasmaVault buy and sell Pendle **Principal Tokens (PT)** on Pendle markets and redeem matured PT for the underlying token. PT is a fixed-yield instrument: it trades below the value of its underlying before maturity and redeems 1:1 for the SY's asset at or after maturity.

**What Pendle does:**

- Splits a yield-bearing asset wrapped as a Standardized Yield token (SY) into PT (principal) and YT (yield).
- Runs an AMM per market (`IPMarket`) between SY and PT; the router (`IPAllActionV3`) routes token ↔ SY ↔ PT swaps, optionally through an external aggregator.
- Exposes a PY oracle (`PendlePYOracleLib`) with TWAP rates PT/asset and PT/SY.

## Market Structure

The integration uses a single market for all operations:

- **Market ID 23** (`IporFusionMarkets.PENDLE`) – swap token → PT, swap PT → token, redeem PT after maturity.

The fuses do not value the PT they buy. Valuation runs through **Market ID 7** (`ERC20_VAULT_BALANCE`), see [Balance Calculation](#balance-calculation).

## Architecture

### Key Components

- **`PendleSwapPTFuse`** (`contracts/fuses/pendle/PendleSwapPTFuse.sol`): `enter` swaps an SY input token for PT (`router.swapExactTokenForPt`), `exit` swaps an exact PT amount for an SY output token (`router.swapExactPtForToken`). Limit orders are always empty.
- **`PendleRedeemPTAfterMaturityFuse`** (`contracts/fuses/pendle/PendleRedeemPTAfterMaturityFuse.sol`): `enter` redeems PT (and the matching YT position, `router.redeemPyToToken`) for an SY output token; reverts with `PendleRedeemPTAfterMaturityFusePTNotExpired` before maturity. No `exit`.
- Both fuses take `(marketId, router)` in the constructor, expose `enterTransient`/`exitTransient` variants that read inputs from transient storage, and approve the router only for the duration of the call (`forceApprove(max)` then `forceApprove(0)`).

### Data structures

`PendleSwapPTFuseEnterData` – `enter((address,uint256,(uint256,uint256,uint256,uint256,uint256),(address,uint256,address,address,(uint8,address,bytes,bool))))`

| Field        | Type           | Meaning                                                                                             |
| ------------ | -------------- | --------------------------------------------------------------------------------------------------- |
| `market`     | `address`      | Pendle market; must be a granted substrate of market 23                                             |
| `minPtOut`   | `uint256`      | Slippage floor on PT received (PT smallest units)                                                   |
| `guessPtOut` | `ApproxParams` | Router binary-search parameters `guessMin, guessMax, guessOffchain, maxIteration, eps`              |
| `input`      | `TokenInput`   | `tokenIn` (must satisfy `sy.isValidTokenIn`), `netTokenIn`, `tokenMintSy`, `pendleSwap`, `swapData` |

`PendleSwapPTFuseExitData` – `exit((address,uint256,(address,uint256,address,address,(uint8,address,bytes,bool))))`

| Field       | Type          | Meaning                                                                                                  |
| ----------- | ------------- | -------------------------------------------------------------------------------------------------------- |
| `market`    | `address`     | Pendle market; must be a granted substrate                                                               |
| `exactPtIn` | `uint256`     | Exact PT amount to sell                                                                                  |
| `output`    | `TokenOutput` | `tokenOut` (must satisfy `sy.isValidTokenOut`), `minTokenOut`, `tokenRedeemSy`, `pendleSwap`, `swapData` |

`PendleRedeemPTAfterMaturityFuseEnterData` – `enter((address,uint256,(address,uint256,address,address,(uint8,address,bytes,bool))))`

| Field     | Type          | Meaning                                                         |
| --------- | ------------- | --------------------------------------------------------------- |
| `market`  | `address`     | Pendle market whose PT is redeemed; must be a granted substrate |
| `netPyIn` | `uint256`     | PT amount to redeem                                             |
| `output`  | `TokenOutput` | Same shape as above                                             |

`ApproxParams`, `TokenInput`, `TokenOutput` and `SwapData` (with `enum SwapType { NONE, KYBERSWAP, ONE_INCH, ETH_WETH }`) come from `@pendle/core-v2`.

The fuses do not cap amounts at the vault balance; an `amount` above it reverts inside the router transfer.

## Balance Calculation

There is no Pendle balance fuse. Market 23 is registered with a `ZeroBalanceFuse` (`contracts/fuses/ZeroBalanceFuse.sol`), and the PT the vault holds is valued by `Erc20BalanceFuse` in market 7 (`ERC20_VAULT_BALANCE`):

1.  grant every PT the vault may hold as a substrate of market 7,
2.  register one `PtPriceFeed` per PT in the price oracle middleware,
3.  add a dependency balance graph `PENDLE → ERC20_VAULT_BALANCE` so the ERC20 balance is refreshed after every Pendle action.

`PtPriceFeed` (`contracts/price_oracle/price_feed/PtPriceFeed.sol`, created through `PtPriceFeedFactory`) reads the Pendle PY oracle TWAP (`getPtToAssetRate` or `getPtToSyRate`, at least a 5-minute window) and multiplies it by the middleware price of the SY asset. Values are USD in WAD (18 decimals).

This is the setup `test/test_helpers/PendleHelper.sol` builds.

## Substrate Configuration

Substrates of market 23 are the **Pendle market addresses** (`IPMarket`), granted as address-shaped substrates (`PlasmaVaultGovernance.grantMarketSubstrates`, checked with `PlasmaVaultConfigLib.isSubstrateAsAssetGranted`). Every action checks `data.market`. Input and output tokens are validated against the market's SY (`isValidTokenIn` / `isValidTokenOut`), not against substrates.

## Price Oracle Setup

- one `PtPriceFeed` per PT, registered for the PT address in the `PriceOracleMiddlewareManager` or `PriceOracleMiddleware`;
- the SY asset (from `SY.assetInfo()`) must already be priced by the middleware, since `PtPriceFeed` multiplies by it;
- the SY input/output tokens the vault holds between actions are priced like any other ERC20 in market 7.

## Roles

- `ALPHA_ROLE` (200) executes the fuses through `PlasmaVault.execute`.
- `FUSE_MANAGER_ROLE` (300) registers the two action fuses, the `ZeroBalanceFuse` for market 23 and the `Erc20BalanceFuse` for market 7, and grants substrates.
- `ATOMIST_ROLE` (100) sets market limits.
- `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE` (1200) registers the PT price feeds.

## Tests

- `test/fuses/pendle/PendleSwapPTFuseTest.t.sol` — Arbitrum fork (`ARBITRUM_PROVIDER_URL`, block 276241475).
- `test/test_helpers/PendleHelper.sol` — the reference vault setup (substrates, `ZeroBalanceFuse`, `PtPriceFeed`).
- There is no test for `PendleRedeemPTAfterMaturityFuse` in this checkout.

## Deployments

Observed on Ethereum at block 25939091 (registry: IPOR-Labs/ipor-abi `mainnet/mainnet-ethereum-fusion/addresses.json`, commit a0089cf):

| Registry name                     | Address                                      | Notes                                                                  |
| --------------------------------- | -------------------------------------------- | ---------------------------------------------------------------------- |
| `FusePendleSwapPt`                | `0xEEA3812B60ca4c6D0e2672a865bf7217eCd49f95` | `MARKET_ID() = 23`; enter/exit selectors of this checkout present      |
| `FusePendleRedeemPtAfterMaturity` | `0x40430a509188b71BdA9a0c06b132e978Ea2015BE` | `MARKET_ID() = 23`; enter selector present                             |
| `BalanceFusePendle`               | `0x48bD852d83f6e58Af59255aBc708e3ddeCB1d1E6` | `MARKET_ID() = 23`; 167-byte runtime consistent with `ZeroBalanceFuse` |

Bytecode equivalence with this checkout was not established; see `catalog/fuses.json` (`ethereum-pendle-market-23`).

## Security Notes

- PT price depends on a TWAP; a short window (`PtPriceFeed` enforces ≥ 5 minutes, Pendle recommends 15) is manipulable within the window.
- `SwapData` may route through an external aggregator (`pendleSwap`, `extRouter`, `extCalldata`); the fuse does not validate that calldata, only `minPtOut` / `minTokenOut` bound the outcome.
- After maturity `PendleSwapPTFuse.exit` still works through the AMM; `PendleRedeemPTAfterMaturityFuse` redeems at par and is the intended exit.
