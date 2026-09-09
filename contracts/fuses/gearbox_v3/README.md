# Gearbox V3 Integration

## Overview

Gearbox V3 pools issue ERC4626 **dTokens** (e.g. dUSDCV3). IPOR Fusion holds dTokens through
the generic ERC4626 fuses and stakes them in Gearbox **farming pools** (farmdTokens) through the
fuses in this directory; farmed rewards are claimed by `GearboxV3FarmDTokenClaimFuse`.

## Market Structure

| Market ID | Constant                 | Fuses                                                                                                 |
| --------- | ------------------------ | ----------------------------------------------------------------------------------------------------- |
| 3         | `GEARBOX_POOL_V3`        | `Erc4626SupplyFuse`, `Erc4626BalanceFuse` ([`../erc4626/`](../erc4626/)) — deposit / withdraw dTokens |
| 4         | `GEARBOX_FARM_DTOKEN_V3` | `GearboxV3FarmSupplyFuse`, `GearboxV3FarmBalanceFuse`, `GearboxV3FarmDTokenClaimFuse` (rewards)       |

`IporFusionMarkets.sol` notes that a vault using market 4 must add a dependency-balance graph
to market 3 (`PlasmaVaultGovernance.updateDependencyBalanceGraphs`).

## Architecture

### `GearboxV3FarmSupplyFuse` (market 4)

| Operation                          | Data                                                          | Meaning                                                                                                       |
| ---------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `enter`                            | `GearboxV3FarmdSupplyFuseEnterData{dTokenAmount, farmdToken}` | Stake up to `dTokenAmount` of the farm's `stakingToken()` (the dToken), capped at the vault's dToken balance. |
| `exit`                             | `GearboxV3FarmdSupplyFuseExitData{dTokenAmount, farmdToken}`  | Withdraw up to `dTokenAmount` from the farm, capped at the vault's farm balance.                              |
| `instantWithdraw`                  | `params[0]` = underlying amount, `params[1]` = farmdToken     | Converts with the dToken's `previewWithdraw` and exits, catching failures.                                    |
| `enterTransient` / `exitTransient` | `inputs[0]` = amount, `inputs[1]` = farmdToken                | Transient-storage variants.                                                                                   |

`farmdToken` must be a granted substrate, otherwise
`GearboxV3FarmdSupplyFuseUnsupportedFarmdToken`. Amounts are dToken units; the farm token is
1:1 with the dToken.

### `GearboxV3FarmDTokenClaimFuse` (market 4, reward fuse)

`claim()` iterates the granted farms, calls `claim()` where `farmed(vault) > 0` and transfers
the farm's `rewardsToken` to the `RewardsClaimManager`. Registered in the `RewardsClaimManager`
and executed through `RewardsClaimManager.claimRewards`.

## Balance Calculation

- **Market 3** — `Erc4626BalanceFuse`: `convertToAssets(dToken.balanceOf(vault))` for every
  granted dToken, priced in the underlying asset, WAD.
- **Market 4** — `GearboxV3FarmBalanceFuse`: takes **only the first** granted farm,
  `dToken.convertToAssets(farm.balanceOf(vault))`, priced in the underlying asset, WAD. Farmed
  rewards are not counted. Several farms in one market under-report.

## Substrate Configuration

Address-shaped, granted with `PlasmaVaultGovernance.grantMarketSubstrates`:

- market 3: dToken addresses;
- market 4: farmdToken (farming pool) addresses.

## Price Oracle Setup

A price source for the underlying asset of each dToken.

## Roles

`ALPHA_ROLE` (200) executes; `CLAIM_REWARDS_ROLE` (600) executes the claim fuse through
`RewardsClaimManager.claimRewards`; `FUSE_MANAGER_ROLE` (300) registers fuses (the claim fuse
through `RewardsClaimManager.addRewardFuses`) and grants substrates; `ATOMIST_ROLE` (100) sets
market limits; `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE` (1200) adds price sources.

## Tests

Arbitrum forks under `test/integrationTest/gearboxV3Arbitrum/`: `GearboxV3USDCArbitrum.t.sol`
(market 3), `GearboxV3FarmdUSDCArbitrum.t.sol`, `GearboxV3FarmdUSDCBalanceArbitrum.t.sol`,
`GearboxV3FarmdUSDCClaimRewards.t.sol` (markets 3 + 4; dUSDCV3
`0x890A69EF363C9c7BdD5E36eb95Ceb569F63ACbF6`, farm `0xD0181a36B0566a8645B7eECFf2148adE7Ecf2BE9`
on Arbitrum).

## Deployed fuses

Read from IPOR-Labs/ipor-abi (`a0089cf`, 2026-09-02, `mainnet/mainnet-arbitrum/addresses.json`)
and on chain at Arbitrum block 503330505; code hashes in
[`catalog/fuses.json`](../../../catalog/fuses.json):

- `SupplyFuseGearboxV3DToken` `0x07cD27531ee9dF28292B26Eeba3f457609DeAe07` (market 3; **older
  ERC4626 ABI** — exposes `enter((address,uint256))` / `exit((address,uint256))`, not this
  checkout's three-field structs), `BalanceFuseGearboxV3DToken`
  `0xd347F4BB96531b01c8fAB953CF8E920419193a8c`;
- `SupplyFuseGearboxV3FarmDToken` `0xB0FBF6B7D0586C0a5Bc1C3b8a98773f4eD02c983` (market 4),
  `BalanceFuseGearboxV3FarmDToken` `0xAa6C8DB1DA40f685e02564dE92Bc2276C12729f6`,
  `ClaimRewardsFuseGearboxV3FarmDToken` `0xFa209140BBA92a64b1038649e7385fa860405099`.

Both balance fuses revert on `VERSION()` and the action fuses lack `enterTransient()`, so they
are older than this checkout. Ethereum deployments with the same registry names exist in
`mainnet/mainnet-ethereum/addresses.json` and were not read.

## Security notes

- The farm balance fuse reads only `substrates[0]`; grant one farm per market.
- The claim fuse transfers `farmed()` as read before `claim()`; a farm that pays less makes the
  transfer revert.
- The deployed market-3 supply fuse has no `minSharesOut` / `maxSharesBurned` protection
  (older ERC4626 fuse ABI).
