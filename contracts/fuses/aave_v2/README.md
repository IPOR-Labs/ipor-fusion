# Aave V2 Integration (Ethereum mainnet only)

## Overview

The Aave V2 integration lets a Plasma Vault deposit reserve assets into the Aave V2
`LendingPool`, withdraw them, and value the resulting aToken position net of any debt.

**What Aave V2 does:** depositing a reserve asset mints a rebasing aToken 1:1; the aToken balance
grows with interest. Debt is tracked by separate stable- and variable-debt tokens.

## Market Structure

There is **no Aave V2 constant** in `contracts/libraries/IporFusionMarkets.sol`. Both fuses take
`marketId_` in the constructor. The in-repo tests (`test/fuses/aave_v2/*.t.sol`) deploy them with
market ID `1`, which collides with `AAVE_V3 = 1`; a vault using both needs a dedicated id. No
deployment of these fuses was found in the IPOR address registry.

## Architecture

### Key Components

- **`AaveV2SupplyFuse`** – deposits to and withdraws from the LendingPool. Implements
  `IFuseInstantWithdraw`.
- **`AaveV2BalanceFuse`** – values aToken balances minus debt.
- **`AaveConstantsEthereum`** – hard-coded mainnet addresses of the LendingPool
  (`0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9`) and the Aave price oracle
  (`0x54586bE62E3c3580375aE3723C145253060Ca0C2`).

### AaveV2SupplyFuse

```solidity
struct AaveV2SupplyFuseEnterData {
    address asset; // reserve asset to deposit; must be a granted substrate
    uint256 amount; // amount to deposit, smallest unit; 0 is a no-op
}

struct AaveV2SupplyFuseExitData {
    address asset; // reserve asset to withdraw; must be a granted substrate
    uint256 amount; // amount to withdraw, smallest unit; capped at the vault's aToken balance
}
```

- `enter` approves the pool given to the constructor and calls
  `LendingPool.deposit(asset, amount, vault, 0)`.
- `exit` reads the vault's aToken balance from the **hard-coded mainnet** LendingPool
  (`AaveConstantsEthereum.AAVE_LENDING_POOL_V2`), not from the constructor pool, caps the amount
  at it and calls `withdraw` on the constructor pool. When the balance is zero it returns the
  requested amount unchanged without withdrawing.
- `instantWithdraw(bytes32[] params)` takes `params[0]` = amount, `params[1]` = asset and runs the
  same exit with reverts caught (`AaveV2SupplyFuseExitFailed` is emitted instead).
- `enterTransient` / `exitTransient` read `asset` and `amount` from transient storage inputs
  `[0]` and `[1]` and write `(asset, amount)` as outputs.
- An asset that is not a granted substrate reverts with `AaveV2SupplyFuseUnsupportedAsset`.

## Balance Calculation

`AaveV2BalanceFuse.balanceOf()` iterates the market's substrates (reserve assets); for each it
reads `getReserveData` from the mainnet LendingPool and sums `aToken balance − stable debt −
variable debt`, priced with the Aave V2 oracle (`getAssetPrice`, USD, 8 decimals). The result is
**USD in WAD (18 decimals)**. The vault's `PriceOracleMiddleware` is not consulted. A net negative
position reverts on the cast to `uint256`.

Because both the pool and the oracle are hard-coded mainnet addresses, **the fuses only work on
Ethereum mainnet**, whatever pool address is passed to the constructor.

## Substrate Configuration

Substrates are **reserve asset addresses** (the underlying tokens, not aTokens). Grant them with
`PlasmaVaultGovernance.grantMarketSubstrates(marketId, substrates)` (addresses encoded as
`bytes32`). The supply fuse checks `PlasmaVaultConfigLib.isSubstrateAsAssetGranted` on enter and
exit; the balance fuse values every granted reserve.

## Price Oracle Setup

No `PriceOracleMiddleware` source is needed for this market's valuation: prices come from the
Aave V2 oracle. Assets the vault holds idle still need a middleware source, as for every market.

## Roles

| Action                                | Role                      |
| ------------------------------------- | ------------------------- |
| `PlasmaVault.execute` with enter/exit | `ALPHA_ROLE` (200)        |
| add the supply and balance fuses      | `FUSE_MANAGER_ROLE` (300) |
| grant substrates                      | `FUSE_MANAGER_ROLE` (300) |
| set the market limit                  | `ATOMIST_ROLE` (100)      |

## Tests

- `test/fuses/aave_v2/AaveV2SupplyFuseTest.t.sol` – Ethereum fork (`ETHEREUM_PROVIDER_URL`,
  block 19591360), DAI and USDT.
- `test/fuses/aave_v2/AaveV2BalanceFuseTest.t.sol` – Ethereum fork (block 19508857).

## Security Notes

- Aave V2 on Ethereum is in wind-down; reserves may be frozen or have their supply caps set to
  zero, which makes `enter` revert inside the pool.
- The exit path mixes two pool references (constructor pool for `withdraw`, hard-coded pool for the
  balance cap). On mainnet they are the same contract; anywhere else the fuse is unusable.
- No deployment exists in the IPOR address registry as of 2026-09-02; treat the fuses as
  source-only until one is recorded.
