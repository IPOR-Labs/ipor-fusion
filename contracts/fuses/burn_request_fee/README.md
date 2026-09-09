# Burn Request Fee Fuses

## Overview

Infrastructure fuses without an external protocol that operate on the vault shares the
`WithdrawManager` collects as request fees:

- **`BurnRequestFeeFuse`** burns `amount` shares from the WithdrawManager's balance.
- **`RequestFeeRefundFuse`** transfers `amount` shares from the WithdrawManager to a recipient
  whose withdraw request expired (counterpart of the burn).

Both route the share movement through `PlasmaVaultBase.updateInternal` by a nested
`delegatecall`, so the vault's `_update` pipeline runs: ERC20Votes checkpoints and supply-cap
validation are applied (IL-6952, audit R4H7; `BurnRequestFeeVotingRegressionTest`). Both resolve
their targets with backward-compatible shims (IL-7407): the WithdrawManager from the corrected
slot with a fallback to the legacy slot, and `PlasmaVaultBase` from the vault's own
`PLASMA_VAULT_BASE()` getter, which new vaults serve from storage and legacy vaults from an
immutable.

`FusionFactory` registers `BurnRequestFeeFuse` and a `ZeroBalanceFuse` on `ZERO_BALANCE_MARKET`
for every vault it creates.

## Market Structure

- **Market ID `type(uint256).max`** (`ZERO_BALANCE_MARKET`); `MARKET_ID` is a constructor
  argument in both fuses, and every deployment read reports that value. Balance fuse:
  `ZeroBalanceFuse` (`contracts/fuses/ZeroBalanceFuse.sol`).

## Architecture

### BurnRequestFeeFuse

`enter(BurnRequestFeeDataEnter)` — selector `0x9988a9ca`

| Field    | Type      | Meaning                                                                                                                                                                               |
| -------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `amount` | `uint256` | shares to burn from the WithdrawManager, in share units; 0 is a no-op; reverts `BurnRequestFeeWithdrawManagerNotSet` / `BurnRequestFeePlasmaVaultBaseNotSet` when a target is missing |

`enterTransient()` — selector `0xadea8fa0` — reads `amount` from transient storage inputs of `VERSION`.
`exit()` / `exitTransient()` — selectors `0xe9fad8ee` / `0x1db205df` — always revert with `BurnRequestFeeExitNotImplemented`.

### RequestFeeRefundFuse

`enter(RequestFeeRefundDataEnter)` — selector `0xd5ee7916`

| Field       | Type      | Meaning                                                                                       |
| ----------- | --------- | --------------------------------------------------------------------------------------------- |
| `recipient` | `address` | receiver of the refunded shares; `address(0)` reverts with `RequestFeeRefundInvalidRecipient` |
| `amount`    | `uint256` | shares to transfer from the WithdrawManager, in share units; 0 is a no-op                     |

`exit()` — selector `0xe9fad8ee` — always reverts with `RequestFeeRefundExitNotImplemented`.

## Balance Calculation

Nothing is valued: burning or refunding shares changes total supply or share ownership, not
assets. The market's `ZeroBalanceFuse` always returns 0.

## Substrate Configuration

None. Neither fuse reads substrates.

## Price Oracle Setup

None.

## Roles

| Action              | Role                                                                                                            |
| ------------------- | --------------------------------------------------------------------------------------------------------------- |
| execute either fuse | `ALPHA_ROLE` (200) via `PlasmaVault.execute`                                                                    |
| register the fuses  | `FUSE_MANAGER_ROLE` (300) via `PlasmaVaultGovernance.addFuses` / `addBalanceFuse` (factory does it at creation) |

## Tests

- `test/fuses/burn_request_fee/RequestFeeRefundFuseTest.t.sol` — fork.
- `test/fuses/burn_request_fee/RequestFeeRefundFuseLegacySlotTest.t.sol` — fork; legacy-slot fallback.
- `test/vaults/BurnRequestFeeVotingRegressionTest.t.sol` — local, no fork (12 tests); voting checkpoints.
- `test/vaults/PlasmaVaultScheduledWithdraw.t.sol` — fork.
- `test/factory/FusionFactory.t.sol` — local; the factory registers the fuse on new vaults.

## Deployments and notes

Ethereum, read at block 25939091 from the `IPOR-Labs/ipor-abi` registry (commit `a0089cf`,
`mainnet/mainnet-ethereum-fusion/addresses.json`):

| Registry name               | Address                                      | MARKET_ID           | Notes                                                                                         |
| --------------------------- | -------------------------------------------- | ------------------- | --------------------------------------------------------------------------------------------- |
| `BurnRequestFeeFuseV2`      | `0x6DebD98329d826bA79b6Fd9B14cC718D1720D0bE` | `type(uint256).max` | `enter`, `exit`, `enterTransient`, `exitTransient` present — same signatures as this checkout |
| `BurnRequestFeeFuse`        | `0x79e8B115Bd41baee318c1940F42F1a2d94D29ab4` | `type(uint256).max` | `enter`, `exit` present, transient entry points **absent** — older than this checkout         |
| `RequestFeeRefundFuse`      | `0xcbB5cA86dB1E237bfA364A817F31F0812D88BF34` | `type(uint256).max` | `enter`, `exit` present                                                                       |
| `BalanceFuseBurnRequestFee` | `0xbc2907d76964510a4232878e7aC6E2B18c474EFb` | `type(uint256).max` | 167-byte contract with `balanceOf()`, consistent with a `ZeroBalanceFuse`                     |

Bytecode equivalence with this checkout was not established for any of them. The older
`BurnRequestFeeFuse` is what the registry lists for most client directories; whether it carries
the IL-7407 legacy-slot fallback was not established. The catalog entry is
`ethereum-burn-request-fee-zero-balance-market` in
[`catalog/fuses.json`](../../../catalog/fuses.json).
