# Update Markets Balances Fuse

## Overview

`UpdateMarketsBalancesFuse` is an infrastructure fuse without an external protocol. It lets an
`ALPHA_ROLE` caller refresh the recorded balances of chosen markets from inside a
`PlasmaVault.execute` batch, in the same transaction as the fuse actions that changed those
balances. Without it, the same refresh is available to `UPDATE_MARKETS_BALANCES_ROLE` (1000)
through `PlasmaVault.updateMarketsBalances`, but only as a separate call.

The fuse runs via `delegatecall`, so `address(this)` is the Plasma Vault: it reads the vault's
`asset()` and `decimals()` and calls `PlasmaVaultMarketsLib.updateMarketsBalances`, which filters
zero market ids, adds balance-fuse dependencies, calls each market's balance fuse, converts the
USD (WAD) result to the vault asset and writes it to total assets in markets.

## Market Structure

- **Market ID `type(uint256).max`** (`ZERO_BALANCE_MARKET`) — the fuse is not tied to a market;
  `MARKET_ID` is a constant. The market's balance fuse is a `ZeroBalanceFuse`, which always
  returns 0.

## Architecture

### Key Components

- **`UpdateMarketsBalancesFuse`** — `enter` refreshes balances; `exit` always reverts.
- **`IUpdateMarketsBalancesFuse`** — the `UpdateMarketsBalancesEnterData` struct, the
  `UpdateMarketsBalancesEnter` event and the errors.

### UpdateMarketsBalancesFuse

`enter(UpdateMarketsBalancesEnterData)` — selector `0xdd15f123`

| Field       | Type        | Meaning                                                                                                          |
| ----------- | ----------- | ---------------------------------------------------------------------------------------------------------------- |
| `marketIds` | `uint256[]` | market IDs to refresh; an empty array reverts with `UpdateMarketsBalancesFuseEmptyMarkets`, zero ids are skipped |

`exit(bytes)` — selector `0x3805550f` — always reverts with `UpdateMarketsBalancesFuseExitNotSupported`.

## Balance Calculation

Nothing is valued for this market. The fuse triggers the balance fuses of the markets it is given;
their results are priced by the vault's `PriceOracleMiddleware` as usual.

## Substrate Configuration

None. The fuse reads no substrate list; the market ids come from the enter data and are checked
against the vault's own market and balance-fuse configuration inside `PlasmaVaultMarketsLib`.

## Price Oracle Setup

None for this market.

## Roles

| Action                        | Role                                                                          |
| ----------------------------- | ----------------------------------------------------------------------------- |
| execute the fuse              | `ALPHA_ROLE` (200) via `PlasmaVault.execute`                                  |
| the same refresh without fuse | `UPDATE_MARKETS_BALANCES_ROLE` (1000) via `PlasmaVault.updateMarketsBalances` |
| register the fuse             | `FUSE_MANAGER_ROLE` (300) via `PlasmaVaultGovernance.addFuses`                |

## Tests

- `test/fuses/update_balances/UpdateMarketsBalancesFuseTest.t.sol` — local, no fork (5 tests).
- `test/integrationTest/update_balances/UpdateMarketsBalancesFuseIntegrationTest.t.sol` — fork.

## Deployments and notes

- No deployment of this fuse is listed in the `IPOR-Labs/ipor-abi` registry (commit `a0089cf`)
  for Ethereum, Arbitrum, Base or Ink. The name exists for Avalanche, Botanix, Flare, HyperEVM,
  Katana, Monad and Robinhood; none was read on chain.
- The catalog entry is `ethereum-update-balances-zero-balance-market` in
  [`catalog/fuses.json`](../../../catalog/fuses.json).
