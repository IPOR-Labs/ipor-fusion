# TAC Staking Integration

> **Status:** every contract in this directory carries the comment
> `This contract is deprecated and should not be used`. The integration is
> documented here so that its market, substrates and deployments can be read
> and audited; do not add it to new vaults without confirming with the team
> that the deprecation has been lifted.

## Overview

The TAC staking integration lets an IPOR Fusion Plasma Vault delegate native
TAC to validators of the TAC chain (chain id 239) through the staking
precompile, undelegate, redelegate between validators and recover the tokens
in an emergency. The vault holds wTAC (wrapped TAC, ERC20); staking happens
from a per-vault helper contract, the **TacStakingDelegator**, which the
delegate fuse deploys on first use and whose address is kept in the vault's
storage (`TacStakingStorageLib`).

**Why a delegator:** the staking precompile credits delegations to
`msg.sender`. A fuse runs by `delegatecall` inside the vault, so the vault
itself would become the delegator, but the vault cannot hold native TAC nor
receive unbonded coins through a `receive()`. The delegator can (`receive()
external payable`), and every entry point of it is `onlyPlasmaVault`.

## Market Structure

- **Market ID 28** (`IporFusionMarkets.TAC_STAKING`) — delegate / undelegate /
  redelegate / emergency exit / balance.

`IporFusionMarkets.sol` also declares `SPOL_UNSTAKE = 424_243` with a long
comment about a `SPOLUnstakeFuse`; no such fuse exists in this checkout and
no other file references the constant.

## Architecture

### Key Components

| Contract                           | Role                                                                                                         |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `TacStakingDelegateFuse`           | `enter`: transfer wTAC to the delegator and delegate; `exit`: undelegate; `instantWithdraw`: pull liquid TAC |
| `TacStakingRedelegateFuse`         | `enter`: move an existing delegation from one validator to another                                           |
| `TacStakingEmergencyFuse`          | `exit()`: sweep all wTAC and native TAC from the delegator back to the vault                                 |
| `TacStakingBalanceFuse`            | values bonded, unbonding and idle TAC held by the delegator                                                  |
| `TacStakingDelegator`              | per-vault helper that owns the delegations; deployed by the delegate fuse                                    |
| `lib/TacStakingStorageLib`         | ERC-7201 slot holding the delegator address                                                                  |
| `lib/TacValidatorAddressConverter` | packs a validator address string into two `bytes32` substrates and back                                      |
| `ext/IStaking`, `ext/IwTAC`        | staking precompile (`0x0000000000000000000000000000000000000800` in the registry) and wTAC interfaces        |

### TacStakingDelegateFuse

`enter(TacStakingDelegateFuseEnterData)` — selector `0xf3edb63d`

| Field                | Type        | Meaning                                                                                                 |
| -------------------- | ----------- | ------------------------------------------------------------------------------------------------------- |
| `validatorAddresses` | `string[]`  | validator operator addresses (bech32 strings); each must be a granted substrate                         |
| `wTacAmounts`        | `uint256[]` | wTAC to delegate per validator, in wei; the sum moves from the vault to the delegator, which unwraps it |

A zero sum is a no-op; a sum above the vault's wTAC balance reverts with
`TacStakingFuseInsufficientBalance`. The delegator is created on the first
call and its address stored.

`exit(TacStakingDelegateFuseExitData)` — selector `0x1ef7018c`

| Field                | Type        | Meaning                                                                                  |
| -------------------- | ----------- | ---------------------------------------------------------------------------------------- |
| `validatorAddresses` | `string[]`  | validators to undelegate from; each must be a granted substrate                          |
| `tacAmounts`         | `uint256[]` | native TAC to undelegate per validator, in wei; tokens return after the unbonding period |

`instantWithdraw(bytes32[] params)` — `params[0]` = wTAC amount. The delegator
returns what it holds liquid (wTAC first, then native TAC wrapped on the fly);
it never undelegates.

### TacStakingRedelegateFuse

`enter(TacStakingRedelegateFuseEnterData)` — selector `0x9012597e`

| Field                   | Type        | Meaning                                                              |
| ----------------------- | ----------- | -------------------------------------------------------------------- |
| `validatorSrcAddresses` | `string[]`  | validators to move stake from; each must be a granted substrate      |
| `validatorDstAddresses` | `string[]`  | validators to move stake to, one per source; each must be granted    |
| `wTacAmounts`           | `uint256[]` | amount per pair in wei (native TAC already bonded, despite the name) |

An empty array is a no-op. No `exit`.

### TacStakingEmergencyFuse

`exit()` — selector `0xe9fad8ee`, no parameters. Wraps the delegator's native
balance and transfers all wTAC to the vault. Bonded or unbonding stake is not
touched.

## Balance Calculation

`TacStakingBalanceFuse.balanceOf()` reads the granted substrates two slots at
a time, rebuilds each validator string and sums, in wei:

- `IStaking.delegation(delegator, validator).balance.amount` — bonded TAC,
- every `entry.balance` of `IStaking.unbondingDelegation(delegator, validator)`,
- the delegator's native TAC balance.

wTAC left on the delegator is **not** counted. The total is priced with the
vault's `PriceOracleMiddleware` using the wTAC address (1:1 with native TAC)
and returned in USD, WAD. A vault without a delegator yet reports 0. A
substrate list of odd length reverts with
`TacStakingBalanceFuseInvalidSubstrateLength`.

## Substrate Configuration

Substrates are validator address strings, packed by
`TacValidatorAddressConverter.validatorAddressToBytes32` into **two**
consecutive `bytes32` values: the first byte of the first slot holds the
string length, followed by up to 63 bytes of the string. Grant both slots, in
order, with `PlasmaVaultGovernance.grantMarketSubstrates(TAC_STAKING, slots)`;
the address-shaped helpers do not apply. The delegate and redelegate fuses
check both slots with `PlasmaVaultConfigLib.isMarketSubstrateGranted` and
revert with `...SubstrateNotGranted(validator)` otherwise.

## Price Oracle Setup

One price source is needed: wTAC (registry `wTAC`
`0xB63B9f0eb4A6E6f191529D71d4D88cc8900Df2C9` on TAC). The balance fuse reverts
if the vault has no price oracle middleware.

## Roles

- `ALPHA_ROLE` (200) executes the fuses through `PlasmaVault.execute`.
- `FUSE_MANAGER_ROLE` (300) registers the fuses and grants substrates.
- `ATOMIST_ROLE` (100) sets the market limit.
- `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE` (1200) adds the wTAC price source.
- `CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE` (900) may list the delegate fuse as an
  instant-withdrawal fuse (`params[0]` = wTAC amount).

## Deployments

Registry `IPOR-Labs/ipor-abi`, `mainnet/mainnet-tac-fusion/addresses.json`
(commit `a0089cf`, 2026-09-02). Not read on chain: this checkout's tooling has
no TAC RPC configured (`TAC_PROVIDER_URL` is empty in `.env.example`).

| Name                       | Address                                      |
| -------------------------- | -------------------------------------------- |
| `TacStakingDelegateFuse`   | `0x457C6981b48C60099B2218C196071Cc2c60d0638` |
| `TacStakingRedelegateFuse` | `0x7b499CE3B1babc150bdbc6F31E52200D6Cdb02E9` |
| `TacStakingEmergencyFuse`  | `0xaBdFC4f716227946ACbCB6d9089Ab8c4BDEDB7C7` |
| `TacStakingBalanceFuse`    | `0x839C0475fd43690B61D935F0255C4f9B4a9e13f1` |
| `TacStakingContract`       | `0x0000000000000000000000000000000000000800` |
| `wTAC`                     | `0xB63B9f0eb4A6E6f191529D71d4D88cc8900Df2C9` |

## Tests

- `test/fuses/tac/TacStakingFuseTest.sol` — forks `TAC_PROVIDER_URL`; every
  test function is prefixed `stest` and `setUp` is named `setUp1`, so Forge
  runs nothing from it.
- `test/fuses/tac/TacValidatorAddressConverterTest.sol` — local, also
  `stest`-prefixed (disabled).
- `test/zaps/TacToWTacZapWithNativeTokenTest.sol` — wTAC zap, not these fuses.

## Security Notes

- The delegator's `executeBatch` performs `delegatecall`s into arbitrary
  targets on behalf of the delegator; it is `onlyPlasmaVault`, so only a fuse
  executed by the vault can reach it.
- `redelegate` and `undelegate` amounts are in native TAC; the field named
  `wTacAmounts` in the redelegate struct is not wrapped TAC.
- Unbonded TAC lands on the delegator as native balance and is only counted by
  the balance fuse and only recoverable through `instantWithdraw` or the
  emergency fuse.
