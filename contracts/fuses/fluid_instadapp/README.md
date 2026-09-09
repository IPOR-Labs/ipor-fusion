# Fluid (Instadapp) Integration

## Overview

Fluid lending exposes ERC4626 **fTokens** (e.g. fUSDC). IPOR Fusion holds fTokens through the
generic ERC4626 fuses, stakes them in Fluid's `LendingStakingRewards` pools through the fuses
in this directory, and claims two kinds of rewards: staking rewards from the pool and
Merkle-distributed rewards from Fluid's `MerkleDistributor`.

## Market Structure

| Market ID | Constant                  | Fuses                                                                                                      |
| --------- | ------------------------- | ---------------------------------------------------------------------------------------------------------- |
| 5         | `FLUID_INSTADAPP_POOL`    | `Erc4626SupplyFuse`, `Erc4626BalanceFuse` ([`../erc4626/`](../erc4626/)) — deposit / withdraw fTokens      |
| 6         | `FLUID_INSTADAPP_STAKING` | `FluidInstadappStakingSupplyFuse`, `FluidInstadappStakingBalanceFuse`, `FluidInstadappClaimFuse` (rewards) |
| 24        | `FLUID_REWARDS`           | `FluidProofClaimFuse` (rewards, no balance fuse)                                                           |

Market 6 values fTokens that left the vault's balance, so a vault using it needs a
dependency-balance graph `6 → 5` (`PlasmaVaultGovernance.updateDependencyBalanceGraphs`), as
the claim-rewards test does.

## Architecture

### `FluidInstadappStakingSupplyFuse` (market 6)

| Operation                          | Data                                                                      | Meaning                                                                                                    |
| ---------------------------------- | ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `enter`                            | `FluidInstadappStakingSupplyFuseEnterData{fluidTokenAmount, stakingPool}` | Stake up to `fluidTokenAmount` of the pool's `stakingToken()` (the fToken), capped at the vault's balance. |
| `exit`                             | `FluidInstadappStakingSupplyFuseExitData{fluidTokenAmount, stakingPool}`  | Withdraw up to `fluidTokenAmount` staked fTokens, capped at the vault's staked balance.                    |
| `instantWithdraw`                  | `params[0]` = underlying amount, `params[1]` = pool                       | Converts with the fToken's `previewWithdraw` (rounds up) and exits, catching failures.                     |
| `enterTransient` / `exitTransient` | `inputs[0]` = amount, `inputs[1]` = pool                                  | Transient-storage variants.                                                                                |

`stakingPool` must be a granted substrate, otherwise
`FluidInstadappStakingSupplyFuseUnsupportedStakingPool`. Amounts are fToken share units.

### `FluidInstadappClaimFuse` (market 6, reward fuse)

`claim()` iterates the granted pools, calls `getReward()` where `earned(vault) > 0` and
transfers the pool's `rewardsToken` to the `RewardsClaimManager`. Registered in the
`RewardsClaimManager` and executed through `RewardsClaimManager.claimRewards`.

### `FluidProofClaimFuse` (market 24, reward fuse)

`claim(distributor, cumulativeAmount, positionType, positionId, cycle, merkleProof, metadata)`
calls `MerkleDistributor.claim` for the vault and forwards the received `TOKEN()` delta to the
`RewardsClaimManager`. `distributor` must be a granted substrate of market 24.

## Balance Calculation

- **Market 5** — `Erc4626BalanceFuse`: `convertToAssets(fToken.balanceOf(vault))` for every
  granted fToken, priced in the underlying asset, WAD.
- **Market 6** — `FluidInstadappStakingBalanceFuse`: takes **only the first** granted pool,
  `stakingToken().convertToAssets(pool.balanceOf(vault))`, priced in the underlying asset,
  WAD. Pending rewards are not counted. Several pools in one market under-report.
- **Market 24** — no balance fuse; claimed rewards are accounted by the `RewardsClaimManager`.

## Substrate Configuration

All three markets use address-shaped substrates granted with
`PlasmaVaultGovernance.grantMarketSubstrates`:

- market 5: fToken addresses;
- market 6: `LendingStakingRewards` pool addresses;
- market 24: `MerkleDistributor` addresses.

## Price Oracle Setup

A price source for the underlying asset of each fToken (markets 5 and 6).

## Roles

`ALPHA_ROLE` (200) executes markets 5 and 6; `CLAIM_REWARDS_ROLE` (600) executes both claim
fuses through `RewardsClaimManager.claimRewards`; `FUSE_MANAGER_ROLE` (300) registers fuses
(claim fuses through `RewardsClaimManager.addRewardFuses`) and grants substrates;
`ATOMIST_ROLE` (100) sets market limits; `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE` (1200) adds
price sources.

## Tests

Arbitrum forks under `test/integrationTest/fluidInstadappArbitrum/`:
`FluidInstadappUSDCArbitrum.t.sol` (market 5), `FluidInstadappStakingUSDCArbitrum.t.sol`,
`FluidInstadappStakingUSDCBalanceArbitrum.t.sol`, `FluidInstadappStakingUSDCClaimRewards.t.sol`
(markets 5 + 6). `FluidProofClaimFuseTest.t.sol` lives in `test/fuses/moonwell/` (Ethereum
fork at block 21665786) and covers market 24.

## Deployed fuses

Read from IPOR-Labs/ipor-abi (`a0089cf`, 2026-09-02) and on chain; details and code hashes in
[`catalog/fuses.json`](../../../catalog/fuses.json):

- Base, block 51079414: `SupplyFuseFluidInstadappPoolFToken`
  `0x15A1e2950dA9Ec0DA69a704b8940F01BdDdE86Ab` (market 5; **older ABI** — exposes
  `enter((address,uint256))` / `exit((address,uint256))`, not this checkout's three-field
  structs), `BalanceFuseFluidInstadappPoolFToken` `0xC80e5a95540d6ebFE4970A0743E71C639DF8C25e`,
  `SupplyFuseFluidInstadappStakingRewardsFToken` `0x977e318676158A7695cCFeB00eC18a68c29BF0EF`
  (market 6), `BalanceFuseFluidInstadappStakingRewardsFToken`
  `0x29d294d3d8Bb422ddDc925Cb95a903d34eEB208A`, `ClaimRewardsFuseFluidInstadapp`
  `0x4E3139528EBA9B85addf1b7E5c36002b7bE8c9B2`, `ClaimRewardsFuseFluidProof`
  `0xB002337C59a4133e328D91ed82C5012472952c6f` (market 24).
- Ethereum, block 25939091: `ClaimRewardsFuseFluidProof`
  `0x30AdE01153CB697BB751cacb6392F49C22558fe0` (market 24).
- Arbitrum (`mainnet/mainnet-arbitrum/addresses.json`, not read on chain): the same five fuse
  names, e.g. `SupplyFuseFluidInstadappPoolFToken` `0x4Ae8640B3A6b71Fa1a05372A59946e66bEb05F9f`.

## Security notes

- The staking balance fuse reads only `substrates[0]`; grant one pool per market.
- `FluidInstadappClaimFuse` transfers `earned()` as read before `getReward()`; a pool that pays
  less than `earned()` makes the transfer revert.
- The deployed market-5 supply fuse on Base has no `minSharesOut` / `maxSharesBurned`
  protection (older ERC4626 fuse ABI).
