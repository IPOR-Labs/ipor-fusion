# Plasma Vault (vault-in-vault) Request Fuses

## Overview

The fuses in `contracts/fuses/plasma_vault/` let one IPOR Fusion Plasma Vault hold shares of
**another** Plasma Vault and go through that vault's request-based withdrawal path:

1. the holding vault places a withdrawal request for some of its shares
   (`WithdrawManager.requestShares` on the target vault);
2. the target vault's `WithdrawManager` releases funds;
3. the holding vault redeems the released shares (`PlasmaVault.redeemFromRequest`).

Depositing into the target vault is not covered here: a target Plasma Vault is an ERC4626
vault, so the deposit and the instant withdrawal go through the generic
[`Erc4626SupplyFuse`](../erc4626/Erc4626SupplyFuse.sol), and the shares are valued by the
generic [`Erc4626BalanceFuse`](../erc4626/Erc4626BalanceFuse.sol) of the same market.

## Market Structure

Both fuses take their market id as a **constructor argument** (`MARKET_ID` is immutable);
there is no dedicated constant. The deployments listed in the IPOR ABI registry and the fork
test use the first generic ERC4626 market:

- **Market ID 100001** (`ERC4626_0001`) — request shares / redeem from request, sharing the
  substrate list and the balance fuse of the ERC4626 integration on that market.

A vault may deploy the fuses with any other `ERC4626_000x` id when the target vault is
catalogued there.

## Architecture

### Key Components

- **`PlasmaVaultRequestSharesFuse`** — requests a withdrawal of target-vault shares.
- **`PlasmaVaultRedeemFromRequestFuse`** — redeems shares of a released request.
- **`Erc4626BalanceFuse`** (from `../erc4626/`) — values the target-vault shares held.

Both action fuses execute inside the holding vault through `delegatecall`, so `address(this)`
is the holding vault: it is the share holder, the requester and the receiver.

### PlasmaVaultRequestSharesFuse

`enter(PlasmaVaultRequestSharesFuseEnterData)` — selector `0xa63e3c73`

| Field          | Type      | Meaning                                                                                                                                                                |
| -------------- | --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sharesAmount` | `uint256` | Shares of the target vault to request, in the target vault's share units. Clamped to the holding vault's balance; `0` or an empty balance is a no-op.                  |
| `plasmaVault`  | `address` | The target Plasma Vault. Must be a granted substrate of the market; must have a `WithdrawManager` set, otherwise `PlasmaVaultRequestSharesFuseInvalidWithdrawManager`. |

The fuse finds the target's `WithdrawManager` by calling the target vault's `UniversalReader.read`
with its own `getWithdrawManager()` selector: that function runs by `delegatecall` in the
**target** vault's storage and returns `PlasmaVaultStorageLib.getWithdrawManager().manager`
(the slot corrected in IL-6952). It then calls `WithdrawManager.requestShares(amount)` on the
target. The shares stay on the holding vault's balance; only the request is recorded.

`enterTransient()` reads `[sharesAmount, plasmaVault]` from transient inputs and writes
`[plasmaVault, sharesAmount]` as outputs (see [`../transient_storage/`](../transient_storage/README.md)).

### PlasmaVaultRedeemFromRequestFuse

`enter(PlasmaVaultRedeemFromRequestFuseEnterData)` — selector `0xa63e3c73` (same tuple shape)

| Field          | Type      | Meaning                                                                             |
| -------------- | --------- | ----------------------------------------------------------------------------------- |
| `sharesAmount` | `uint256` | Shares to redeem from the released request, clamped to the holding vault's balance. |
| `plasmaVault`  | `address` | The target Plasma Vault; must be a granted substrate of the market.                 |

Calls `IPlasmaVault(plasmaVault).redeemFromRequest(shares, holdingVault, holdingVault)`. The
target's `WithdrawManager` must have released funds for the request first, otherwise the
target vault reverts. Has `enterTransient()` with the same inputs/outputs as the request fuse.

There is no `exit` on either fuse.

## Balance Calculation

The market's balance fuse is the generic `Erc4626BalanceFuse`: for every target vault in the
substrate list it converts the holding vault's shares with `convertToAssets` and prices the
target vault's underlying asset through the price oracle middleware, in USD normalized to
WAD (18 decimals). Shares locked in a pending request are still on the holding vault's balance
and remain valued until `redeemFromRequest` burns them.

## Substrate Configuration

Substrates are **addresses of target Plasma Vaults**, granted with
`PlasmaVaultGovernance.grantMarketSubstrates(marketId, [...])` (address-shaped) and checked by
both fuses with `PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, plasmaVault)`.
Because the fuses share the market with the ERC4626 integration, the same list also drives the
ERC4626 supply fuse and the balance fuse.

## Price Oracle Setup

The balance fuse needs a price source for the **underlying asset of every target vault**
(`PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE`, 1200). Nothing else is priced.

## Roles

| Action                          | Role                                          |
| ------------------------------- | --------------------------------------------- |
| `PlasmaVault.execute` with fuse | `ALPHA_ROLE` (200)                            |
| register fuses / balance fuse   | `FUSE_MANAGER_ROLE` (300)                     |
| grant substrates                | `FUSE_MANAGER_ROLE` (300)                     |
| market limits                   | `ATOMIST_ROLE` (100)                          |
| price sources                   | `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE` (1200) |

On the **target** vault the holding vault is an ordinary share holder: no role is needed to
request or redeem, but the target must be configured with a `WithdrawManager`, and its
`ALPHA_ROLE` releases funds.

## Deployed Contracts

Read from the IPOR ABI registry (`IPOR-Labs/ipor-abi`, `mainnet/mainnet-ethereum-fusion/addresses.json`
at commit `a0089cf`) and on Ethereum at block 25939091; details in
[`catalog/fuses.json`](../../../catalog/fuses.json), entry `ethereum-plasma-vault-market-100001`:

| Registry name                             | Address                                      | Note                                             |
| ----------------------------------------- | -------------------------------------------- | ------------------------------------------------ |
| `FuseRequestSharesPlasmaVaultV2`          | `0xD966e091Fd435b82D20952A0F4243B2786b5E379` | `MARKET_ID` 100001, has `enterTransient()`       |
| `FuseRequestSharesPlasmaVaultMarket1`     | `0x7130383298822097531Cf5cc5e3414dda1e09542` | `MARKET_ID` 100001, older: no `enterTransient()` |
| `FuseRedeemFromRequestPlasmaVaultMarket1` | `0x906Af6A42079AdAF1aBD92F924a5d4263653AF0d` | `MARKET_ID` 100001, older: no `enterTransient()` |

The same three names exist on Arbitrum, Base and other chains in the registry; those were not read.

## Tests

- [`test/fuses/plasma_vault/PlasmaVaultRequestSharesTest.t.sol`](../../../test/fuses/plasma_vault/PlasmaVaultRequestSharesTest.t.sol)
  — Ethereum fork at block 22075985: a TAU vault holds shares of the FortunaFi vault, requests,
  releases (as the target's alpha) and redeems, in plain and transient form. The test writes the
  target's `WithdrawManager` into the corrected storage slot with `vm.store` because the forked
  target predates IL-6952.

## Security Notes

- **Storage slot coupling.** `getWithdrawManager()` reads the `WITHDRAW_MANAGER` slot of the
  target vault. A target vault deployed before IL-6952 keeps its manager at the old slot, so the
  fuse reads `address(0)` and reverts; upgrade the target or expect the revert.
- **No exit.** Cancelling a request is not supported by the fuses.
- **Request fees.** The target's `WithdrawManager` may charge a request fee; it is deducted on
  the target side and shows up as a smaller redeemable amount.
- **Older deployments** do not implement `enterTransient()`; chaining through transient storage
  requires the V2 request fuse and a redeem fuse with that entry point.
