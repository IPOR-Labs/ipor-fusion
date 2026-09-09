# Lido stETH Wrapper Integration

## Overview

`StEthWrapperFuse` lets an IPOR Fusion Plasma Vault on Ethereum wrap stETH
into wstETH and unwrap wstETH back into stETH through Lido's wstETH contract.
It moves value between two ERC20 balances of the vault and opens no position
of its own, so it has no balance fuse: whichever of the two tokens the vault
holds is priced by the `Erc20BalanceFuse` of the same market.

Token addresses are constants of the fuse (Ethereum mainnet only):

- stETH `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84`
- wstETH `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0`

## Market Structure

The fuse has no market constant of its own; the market id is a constructor
argument (`0` reverts with `Errors.WrongValue`). The deployed fuse on Ethereum
and the test both use **Market ID 7** (`IporFusionMarkets.ERC20_VAULT_BALANCE`),
so that the stETH and wstETH balances stay on the market the ERC20 balance fuse
already values.

## Architecture

### StEthWrapperFuse

`enter(uint256 stEthAmount)` — selector `0xa59f3e0c` — wraps. The amount is
capped at the vault's stETH balance; `0` is a no-op. Returns
`(finalAmount, wstEthAmount)`. The approval to wstETH is reset to `0` after the
call.

`exit(uint256 wstEthAmount)` — selector `0x7f8661a1` — unwraps. Capped at the
vault's wstETH balance; `0` is a no-op. Returns `(finalAmount, stEthAmount)`.

`enterTransient()` / `exitTransient()` read the amount from
`TransientStorageLib` inputs (`inputs[0]`) and write both return values as
outputs, for chaining with the transient-storage fuses.

Both operations take plain `uint256` parameters, not a data struct.

## Balance Calculation

None in this directory. Register `contracts/fuses/erc20/Erc20BalanceFuse.sol`
on the same market with stETH and wstETH as substrates; it prices each
granted token's vault balance through the `PriceOracleMiddleware` in USD, WAD.

## Substrate Configuration

`_validateSubstrates` runs on every `enter` and `exit`: each of stETH and
wstETH that is **not** the vault's own underlying asset must be granted on the
market with `PlasmaVaultGovernance.grantMarketSubstrates` (address-shaped,
checked with `PlasmaVaultConfigLib.isSubstrateAsAssetGranted`), otherwise the
call reverts with `StEthWrapperFuseUnsupportedAsset(action, token)`. A vault
whose underlying is stETH therefore needs only wstETH granted, and vice versa.

## Price Oracle Setup

Price sources for stETH and wstETH on the vault's `PriceOracleMiddleware` (or
its manager), so the ERC20 balance fuse can value both sides of the wrap.

## Roles

- `ALPHA_ROLE` (200) executes `enter`/`exit` through `PlasmaVault.execute`.
- `FUSE_MANAGER_ROLE` (300) registers the fuse and the ERC20 balance fuse and
  grants the substrates.
- `ATOMIST_ROLE` (100) sets the market limit.
- `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE` (1200) adds the two price sources.

## Deployments

Registry `IPOR-Labs/ipor-abi`, `mainnet/mainnet-ethereum-fusion/addresses.json`
(commit `a0089cf`), read on Ethereum at block 25939091:

| Name               | Address                                      | Observed                                                                                                                        |
| ------------------ | -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `StEthWrapperFuse` | `0x176F645b837663F4aF2579f37059bdC22EE69584` | `MARKET_ID()` = 7; `enter(uint256)`/`exit(uint256)` present; **no** `enterTransient`/`exitTransient` — older than this checkout |
| `BalanceFuseErc20` | `0x6cEBf3e3392D0860Ed174402884b941DCBB30654` | `MARKET_ID()` = 7; `VERSION()` reverts, so older than this checkout's `Erc20BalanceFuse`                                        |

## Tests

- `test/fuses/chains/ethereum/lido/StEthWrapperFuseTest.t.sol` — forks
  Ethereum at block 23041700, 13 tests, market `ERC20_VAULT_BALANCE`.

Other files matching "lido" under `test/` (`test/looping/ethereum/*Lido*`,
`test/fuses/euler/IWstETH.sol`, `test/fuses/morpho/IstETH.sol`, Aave V3 Lido
tests) exercise Aave V3 Lido markets or only import token interfaces; they do
not call this fuse.

## Security Notes

- The fuse does not check that the vault's underlying is stETH or wstETH; it
  only checks substrates. A vault with another underlying can still wrap
  stETH it holds if both tokens are granted.
- Wrapping changes the token the vault holds but not its value; the ERC20
  balance fuse must have price sources for **both** tokens or the market's
  balance drops after a wrap or unwrap.
