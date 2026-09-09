# Compound V2 Integration

## Overview

The Compound V2 integration lets a Plasma Vault mint cTokens by supplying their underlying asset,
redeem them, and value the resulting position.

**What Compound V2 does:** every listed asset has a `cToken` (cDAI, cUSDC, ...). Supplying the
underlying mints cTokens whose exchange rate grows with accrued interest; `balanceOfUnderlying`
returns the supplied value plus interest.

## Market Structure

There is **no Compound V2 constant** in `contracts/libraries/IporFusionMarkets.sol`. Both fuses
take `marketId_` in the constructor. The only in-repo usage is
`test/fuses/compound_v2/CompoundV2FuseTest.t.sol`, which deploys them with market ID `1` — a value
that collides with `AAVE_V3 = 1`, so a vault that uses both would need a dedicated id. No
deployment of these fuses was found in the IPOR address registry.

## Architecture

### Key Components

- **`CompoundV2SupplyFuse`** – mints and redeems cTokens. Implements `IFuseInstantWithdraw`.
- **`CompoundV2BalanceFuse`** – values the vault's cToken positions.

### CompoundV2SupplyFuse

```solidity
struct CompoundV2SupplyFuseEnterData {
    address asset; // underlying token; resolved to a cToken through the substrate list
    uint256 amount; // amount of underlying to supply, smallest unit; 0 is a no-op
}

struct CompoundV2SupplyFuseExitData {
    address asset; // underlying token to withdraw
    uint256 amount; // amount of underlying to redeem, smallest unit; capped at balanceOfUnderlying
}
```

- `enter` finds the cToken whose `underlying()` equals `asset` among the market's substrates,
  approves it and calls `cToken.mint(amount)`. No matching cToken reverts with
  `CompoundV2SupplyFuseUnsupportedAsset(asset)`.
- `exit` calls `cToken.redeemUnderlying(min(amount, balanceOfUnderlying))`. Compound V2 reports
  failures as a non-zero return code, not a revert: the fuse then emits
  `CompoundV2SupplyExitFailed` and returns normally. Callers must not assume that a completed
  `exit` withdrew anything.
- `instantWithdraw(bytes32[] params)` takes `params[0]` = amount, `params[1]` = asset and runs the
  same exit with reverts caught.
- `enterTransient` / `exitTransient` read `asset` and `amount` from transient storage inputs
  `[0]` and `[1]` and write `(asset, cToken, amount)` as outputs.

## Balance Calculation

`CompoundV2BalanceFuse.balanceOf()` iterates the market's substrates (cTokens); for each it reads
`balanceOfUnderlying(vault)` minus `borrowBalanceCurrent(vault)` and prices the underlying through
the vault's `PriceOracleMiddleware` (`getAssetPrice(underlying)`, using the decimals the middleware
reports). The result is **USD in WAD (18 decimals)**. Both Compound calls accrue interest, so
`balanceOf` is **not** a view function.

## Substrate Configuration

Substrates are **cToken addresses**, not underlying tokens. Grant them with
`PlasmaVaultGovernance.grantMarketSubstrates(marketId, substrates)` (addresses encoded as
`bytes32`). The supply fuse does not check the asset address directly; it scans the granted
cTokens for one whose `underlying()` matches.

## Price Oracle Setup

A price source for **every underlying token** of the granted cTokens must be configured on the
vault's `PriceOracleMiddleware` (or its manager) by `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE`;
without it the balance fuse reverts.

## Roles

| Action                                | Role                                          |
| ------------------------------------- | --------------------------------------------- |
| `PlasmaVault.execute` with enter/exit | `ALPHA_ROLE` (200)                            |
| add the supply and balance fuses      | `FUSE_MANAGER_ROLE` (300)                     |
| grant substrates                      | `FUSE_MANAGER_ROLE` (300)                     |
| set the market limit                  | `ATOMIST_ROLE` (100)                          |
| add price sources                     | `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE` (1200) |

## Tests

- `test/fuses/compound_v2/CompoundV2FuseTest.t.sol` – Ethereum fork (`ETHEREUM_PROVIDER_URL`,
  block 19538857), cDAI.

## Security Notes

- A failed `redeemUnderlying` does not revert; it is only signalled by the
  `CompoundV2SupplyExitFailed` event.
- Substrates are cTokens: granting an underlying token address makes `enter` revert with
  `CompoundV2SupplyFuseUnsupportedAsset`, and makes the balance fuse revert on `underlying()`.
- The fuses have no deployment in the IPOR address registry as of 2026-09-02; treat them as
  source-only until one is recorded.
