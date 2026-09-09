# Harvest doHardWork Integration

## Overview

The Harvest integration lets a Plasma Vault trigger `doHardWork` on Harvest Finance vaults it
holds shares of. `doHardWork` harvests the strategy's rewards and rebalances it, which updates
the Harvest vault's share price. The fuse does not move any assets of the Plasma Vault itself;
the Harvest shares are typically held and valued through an ERC4626 market.

## Market Structure

- **Market ID 27** (`HARVEST_HARD_WORK`) — `doHardWork` only. The market has no position, so
  it is registered with a `ZeroBalanceFuse` (`contracts/fuses/ZeroBalanceFuse.sol`).

## Architecture

### HarvestDoHardWorkFuse

`enter(HarvestDoHardWorkFuseEnterData)` — selector `0x5e047043`

| Field    | Type        | Meaning                                                                                                   |
| -------- | ----------- | --------------------------------------------------------------------------------------------------------- |
| `vaults` | `address[]` | Harvest vaults to call `controller().doHardWork(vault)` on; each must be a granted substrate of market 27 |

Errors: `UnsupportedVault(address)` when a vault is not a substrate, `UnsupportedComptroller(address)`
when `vault.controller()` is zero. There is no `exit`. `enterTransient()` reads the array from
transient storage (`input[0]` = length, then the addresses) for fuse chaining.

## Balance Calculation

None. The market's balance fuse is a `ZeroBalanceFuse` and always returns `0`. The effect of
`doHardWork` shows up in the market that values the Harvest shares.

## Substrate Configuration

Substrates are the **Harvest vault addresses** (address-shaped, granted with
`PlasmaVaultGovernance.grantMarketSubstrates`). The fuse checks
`PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, vault)` for every entry of
`data.vaults`.

## Price Oracle Setup

No price source is needed for this market.

## Roles

- `ALPHA_ROLE` (200) executes the fuse through `PlasmaVault.execute`.
- `FUSE_MANAGER_ROLE` (300) adds the fuse and the `ZeroBalanceFuse` and grants substrates.
- `ATOMIST_ROLE` (100) sets the market limit (irrelevant for a zero balance, but the market must exist).

## Tests

- `test/fuses/harvest/HarvestDoHardWorkFuseTest.t.sol` (Base fork, on an existing vault with
  a fresh fuse and `ZeroBalanceFuse` added by the test)

## Deployments

See `catalog/fuses.json`, entry `ethereum-harvest-market-27`, for the addresses observed on
Ethereum (`FuseHarvestDoHardWork` and `BalanceFuseHarvestDoHardWork`).

## Security Notes

- `doHardWork` is permissionless on many Harvest controllers but may be gated to hard workers;
  whether the Plasma Vault is allowed to call it is a property of the Harvest deployment, not
  of the fuse.
- The fuse calls an external controller chosen by the Harvest vault; only grant vaults you trust.
