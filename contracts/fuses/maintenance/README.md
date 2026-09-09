# Maintenance Fuses

## Overview

Two infrastructure fuses without an external protocol. Both run via `delegatecall` from
`PlasmaVault.execute`, so they write the Plasma Vault's own storage:

- **`ConfigureInstantWithdrawalFuse`** writes the ordered list of instant-withdrawal paths
  (`PlasmaVaultLib.configureInstantWithdrawalFuses`), the same configuration that
  `CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE` (900) can set directly through
  `PlasmaVaultGovernance.configureInstantWithdrawalFuses`.
- **`UpdateWithdrawManagerMaintenanceFuse`** sets the vault's `WithdrawManager` address in the
  corrected `WITHDRAW_MANAGER` storage slot (IL-6952, audit R4H7). Outside this fuse the
  manager is only set at initialization.

Registering either fuse on a vault hands that setting to whoever holds `ALPHA_ROLE`.

## Market Structure

- **Market ID `type(uint256).max`** (`ZERO_BALANCE_MARKET`) on the Ethereum deployments;
  `MARKET_ID` is a constructor argument in both fuses. The market's balance fuse is a
  `ZeroBalanceFuse`.

## Architecture

### ConfigureInstantWithdrawalFuse

`enter(ConfigureInstantWithdrawalFuseEnterData)` — selector `0x273e3894`

| Field   | Type                                   | Meaning                                                                                                                                                                                                                                                                                                           |
| ------- | -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fuses` | `InstantWithdrawalFusesParamsStruct[]` | ordered withdrawal paths; each `{fuse, params}` names a registered fuse and its parameters, where `params[0]` is a placeholder for the withdrawal amount (filled by the vault at withdrawal time, in the vault asset's smallest unit) and `params[1+]` are fuse-specific values; a fuse may appear more than once |

`exit(bytes)` — selector `0x3805550f` — always reverts with `ExitNotSupported`.

### UpdateWithdrawManagerMaintenanceFuse

`enter(UpdateWithdrawManagerMaintenanceFuseEnterData)` — selector `0x7e890317`

| Field        | Type      | Meaning                                                                                            |
| ------------ | --------- | -------------------------------------------------------------------------------------------------- |
| `newManager` | `address` | the WithdrawManager to store; `address(0)` returns without writing; emits `WithdrawManagerUpdated` |

`exit(bytes)` — selector `0x3805550f` — returns without doing anything.
`getWithdrawManager()` — selector `0x42022932` — reads the slot back (only meaningful through the vault's storage, i.e. via delegatecall or a universal reader).

## Balance Calculation

Nothing is valued: the market's balance fuse is a `ZeroBalanceFuse`.

## Substrate Configuration

None. Neither fuse reads substrates.

## Price Oracle Setup

None.

## Roles

| Action                                 | Role                                                                     |
| -------------------------------------- | ------------------------------------------------------------------------ |
| execute either fuse                    | `ALPHA_ROLE` (200) via `PlasmaVault.execute`                             |
| instant-withdrawal config without fuse | `CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE` (900) via `PlasmaVaultGovernance` |
| register the fuses                     | `FUSE_MANAGER_ROLE` (300) via `PlasmaVaultGovernance.addFuses`           |

## Tests

- `test/fuses/maintenance/InstantWithdrawalFuseTest.t.sol` — fork.
- `test/vaults/PlasmaVaultMaintenance.t.sol` — fork; `ConfigureInstantWithdrawalFuse` paths.
- `test/vaults/PlasmaVaultScheduledWithdraw.t.sol` — fork; uses `UpdateWithdrawManagerMaintenanceFuse`.

## Deployments and notes

Ethereum, read at block 25939091 from the `IPOR-Labs/ipor-abi` registry (commit `a0089cf`,
`mainnet/mainnet-ethereum-fusion/addresses.json`):

| Registry name                          | Address                                      | MARKET_ID           | Selectors present                                  |
| -------------------------------------- | -------------------------------------------- | ------------------- | -------------------------------------------------- |
| `ConfigureInstantWithdrawalFuse`       | `0xd58F0EF796618F09f7fc6e63c25fae25CEB33799` | `type(uint256).max` | `enter` `0x273e3894`, `exit` `0x3805550f`          |
| `MaintenanceFuseUpdateWithdrawManager` | `0x74CA34C2C47d0865856A54060246AB736a0Bb0D0` | `type(uint256).max` | `enter` `0x7e890317`, `exit`, `getWithdrawManager` |

Bytecode equivalence with this checkout was not established. Whether the deployed
`MaintenanceFuseUpdateWithdrawManager` writes the corrected or the legacy `WITHDRAW_MANAGER`
slot was not read; the source in this checkout writes the corrected one. Coordinate any change
to that slot with `BurnRequestFeeFuse`, `RequestFeeRefundFuse` and `PlasmaVaultRequestSharesFuse`,
which read it with a legacy fallback (IL-7407).

The catalog entry is `ethereum-maintenance-zero-balance-market` in
[`catalog/fuses.json`](../../../catalog/fuses.json).
