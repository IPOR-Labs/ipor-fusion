# Aave V3 Integration

## Overview

The Aave V3 fuses connect an IPOR Fusion PlasmaVault to **Aave V3** pools: supplying reserves (receiving aTokens),
enabling reserves as collateral, borrowing at variable rate, repaying, and repaying directly with aTokens.

Every fuse takes an Aave **`PoolAddressesProvider`** as an immutable constructor argument and resolves the pool,
the pool data provider and (for `AaveV3BalanceFuse`) the Aave price oracle from it at call time. Deploying the
same sources with a different provider targets a different Aave instance (e.g. the Lido market on Ethereum).

## Market Structure

| Market ID | Constant       | Aave instance (Ethereum)                       | Registry fuse names (ipor-abi)                                                                                               |
| --------- | -------------- | ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| 1         | `AAVE_V3`      | main market, `AaveV3PoolAddressesProvider`     | `SupplyFuseAaveV3`, `BorrowFuseAaveV3`, `AaveV3CollateralFuse`, `AaveV3WithPriceOracleMiddlewareBalanceFuse`                 |
| 20        | `AAVE_V3_LIDO` | Lido market, `AaveV3LidoPoolAddressesProvider` | `SupplyFuseAaveV3Lido`, `BorrowFuseAaveV3Lido`, `AaveV3CollateralFuseLido`, `AaveV3WithPriceOracleMiddlewareBalanceLidoFuse` |

Both markets use the same Solidity sources; only the constructor arguments differ. Other chains (Arbitrum, Base)
deploy the market-1 set with their own providers.

## Architecture

### Key Components

| Contract                                                                                       | Operation                                                   | Data                                                                                                        |
| ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| [`AaveV3SupplyFuse`](AaveV3SupplyFuse.sol)                                                     | `enter` supply, `exit` withdraw                             | `AaveV3SupplyFuseEnterData{asset, amount, userEModeCategoryId}` / `AaveV3SupplyFuseExitData{asset, amount}` |
| [`AaveV3BorrowFuse`](AaveV3BorrowFuse.sol)                                                     | `enter` borrow (variable), `exit` repay                     | `AaveV3BorrowFuseEnterData{asset, amount}` / `AaveV3BorrowFuseExitData{asset, amount}`                      |
| [`AaveV3CollateralFuse`](AaveV3CollateralFuse.sol)                                             | `enter(address)` enable, `exit(address)` disable collateral | plain `address` parameter                                                                                   |
| [`AaveV3RepayWithATokensFuse`](AaveV3RepayWithATokensFuse.sol)                                 | `enter` repay with aTokens (no `exit`)                      | `AaveV3RepayWithATokensFuseEnterData{asset, amount, minAmount}`                                             |
| [`AaveV3WithPriceOracleMiddlewareBalanceFuse`](AaveV3WithPriceOracleMiddlewareBalanceFuse.sol) | `balanceOf`                                                 | prices through the vault's `PriceOracleMiddleware`                                                          |
| [`AaveV3BalanceFuse`](AaveV3BalanceFuse.sol)                                                   | `balanceOf`                                                 | prices through Aave's own oracle (8 decimals)                                                               |

Field semantics:

- `asset` — the Aave reserve's underlying token; it must be a granted substrate of the fuse's `MARKET_ID`.
- Amounts are in the asset's smallest unit. Zero amounts are no-ops.
- `AaveV3SupplyFuse.enter` caps `amount` at the vault's balance; `userEModeCategoryId` above 255 leaves E-Mode
  untouched, otherwise `setUserEMode(uint8)` is called after the supply (0 disables E-Mode).
- `AaveV3SupplyFuse.exit` caps `amount` at the vault's aToken balance.
- `AaveV3BorrowFuse` uses `INTEREST_RATE_MODE = 2` (variable) only; `exit` approves exactly `amount` to the pool.
- `AaveV3RepayWithATokensFuse.enter` repays `min(amount, aTokenBalance)`; `type(uint256).max` is forwarded so
  Aave repays the whole debt; a repaid amount below `minAmount` reverts with
  `AaveV3RepayWithATokensFuseRepaidAmountBelowMinimum`. No approval is needed: the pool burns the caller's aTokens.

All action fuses also expose `enterTransient` / `exitTransient` reading the same fields from
`TransientStorageLib` inputs.

### Instant withdrawals

`AaveV3SupplyFuse` implements `IFuseInstantWithdraw.instantWithdraw` with `params[0] = amount`,
`params[1] = asset`; failures are caught and emitted as `AaveV3SupplyFuseExitFailed`.

## Balance Calculation

Both balance fuses iterate the granted reserves and, per reserve, compute
`aToken balance − stable debt − variable debt` of the vault (signed), convert it to USD and sum. The total is
clamped to `uint256`, so a net-negative sum reverts.

- `AaveV3WithPriceOracleMiddlewareBalanceFuse` — price and decimals from `PlasmaVaultLib.getPriceOracleMiddleware()`;
  a zero price reverts with `AaveV3WithPriceOracleMiddlewareBalanceFuseZeroPrice`.
- `AaveV3BalanceFuse` — price from `IPoolAddressesProvider.getPriceOracle()` at 8 decimals; a zero price reverts
  with `Errors.UnsupportedQuoteCurrencyFromOracle`.

Result: USD normalized to WAD (18 decimals).

## Substrate Configuration

Substrates are reserve (underlying asset) **addresses**, granted with
`PlasmaVaultGovernance.grantMarketSubstrates(marketId, bytes32[])` using
`PlasmaVaultConfigLib.addressToBytes32(asset)` and checked with `PlasmaVaultConfigLib.isSubstrateAsAssetGranted`.
Every action fuse checks its `asset`; the balance fuses iterate the same list. A reserve that is borrowed must be
granted too, otherwise the debt is invisible to valuation.

## Price Oracle Setup

With `AaveV3WithPriceOracleMiddlewareBalanceFuse` every granted reserve needs a price source in the vault's
`PriceOracleMiddleware` (or its manager). With `AaveV3BalanceFuse` no Fusion price source is needed; valuation trusts
Aave's oracle.

## Roles

- `ALPHA_ROLE` (200) executes the action fuses through `PlasmaVault.execute`.
- `FUSE_MANAGER_ROLE` (300) registers fuses and balance fuses and grants substrates.
- `ATOMIST_ROLE` (100) sets market limits.
- `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE` (1200) adds price sources.

## Tests

All Aave V3 tests fork:

- Ethereum: `test/fuses/aave_v3/AaveV3SupplyFuseTest.t.sol`, `AaveV3BalanceFuseTest.t.sol`,
  `AaveV3RepayWithATokensFuseTest.t.sol`, `test/integrationTest/aaveV3Ethereum/*.t.sol`,
  `test/looping/ethereum/LoopingBorrowSupplyAaveV3FlashLoanMorpho.t.sol` (market 1),
  `test/looping/ethereum/LoopingBorrowSupplyAaveV3LidoFlashLoanMorpho.t.sol` (market 20).
- Arbitrum: `test/fuses/aave_v3/AaveV3SupplyFuseArbitrumTest.t.sol`, `AaveV3BalanceFuseArbitrumTest.t.sol`,
  `test/integrationTest/aaveV3Arbitrum/AaveV3USDCArbitrum.t.sol`.
- Base: `test/fuses/aave_v3/AaveV3WithPriceOracleMiddlewareBalanceFuseTest.t.sol`.

## Security Notes

- The deployed `AaveV3WithPriceOracleMiddlewareBalanceFuse` for market 1 on Ethereum (`0xB12D9640…`) reverts on
  `VERSION()` and is older than this source; the market-20 deployment `0x366aDb1F…` answers `VERSION()`. See
  `catalog/fuses.json`, entries `ethereum-aave-v3-market-1` and `ethereum-aave-v3-lido-market-20`.
- `AaveV3RepayWithATokensFuse` has no Ethereum deployment in the ipor-abi registry (only
  `RepayWithATokensFuseAaveV3` on Base).
- `AaveV3CollateralFuse` takes a plain `address`, not a struct; `enter(address)` / `exit(address)`.
- Repaying is terminal: there is no inverse of `AaveV3RepayWithATokensFuse.enter`; open a new borrow with
  `AaveV3BorrowFuse.enter`.
