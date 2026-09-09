# Ramses V2 Fuses

## Overview

Fuses in `contracts/fuses/ramses/` let a PlasmaVault hold concentrated-liquidity positions on
**Ramses V2** (a Uniswap V3 fork on Arbitrum): mint and burn position NFTs, add and remove
liquidity, collect fees, and value the positions. Gauge rewards attached to those NFTs are
claimed by a separate reward fuse, `contracts/rewards_fuses/ramses/RamsesClaimFuse.sol`.

All fuses are stateless contracts executed by the vault through `delegatecall`, so
`address(this)` inside a fuse is the vault. Position tokenIds are tracked in
`FuseStorageLib.getRamsesV2TokenIds()`.

## Market Structure

One market for every operation:

- **Market ID 18** (`IporFusionMarkets.RAMSES_V2_POSITIONS`) — new position, modify position,
  collect, balance and reward claim.

The market id is a constructor argument of every fuse (`marketId_`); the constant is the value
the tests use.

## Architecture

| Contract                     | Type    | Data                                                                   | Purpose                                                             |
| ---------------------------- | ------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `RamsesV2NewPositionFuse`    | action  | `RamsesV2NewPositionFuseEnterData` / `RamsesV2NewPositionFuseExitData` | mint a position NFT (enter), burn empty positions (exit)            |
| `RamsesV2ModifyPositionFuse` | action  | `RamsesV2ModifyPositionFuseEnterData` / `...ExitData`                  | increase (enter) or decrease (exit) liquidity of a tracked position |
| `RamsesV2CollectFuse`        | action  | `RamsesV2CollectFuseEnterData`                                         | transfer owed tokens (fees, decreased principal) to the vault       |
| `RamsesV2Balance`            | balance | —                                                                      | USD (WAD) value of every tracked position                           |
| `RamsesClaimFuse`            | reward  | `claim(uint256[] tokenIds, address[][] tokenRewards)`                  | claim gauge rewards of position NFTs into the `RewardsClaimManager` |

Constructors: the action fuses take `(marketId, nonfungiblePositionManager)`; `RamsesV2Balance`
takes `(marketId, nonfungiblePositionManager, ramsesFactory)`; `RamsesClaimFuse` takes
`(nonfungiblePositionManager)` only.

### `RamsesV2NewPositionFuse`

`enter(RamsesV2NewPositionFuseEnterData)`:

| Field                              | Meaning                                                                   |
| ---------------------------------- | ------------------------------------------------------------------------- |
| `token0`, `token1`                 | pool tokens; both must be granted substrates of market 18                 |
| `fee`                              | pool fee tier, hundredths of a bip                                        |
| `tickLower`, `tickUpper`           | position range                                                            |
| `amount0Desired`, `amount1Desired` | amounts to spend, in each token's smallest unit                           |
| `amount0Min`, `amount1Min`         | slippage floors on the amounts actually spent                             |
| `deadline`                         | unix timestamp (seconds)                                                  |
| `veRamTokenId`                     | veRAM NFT id attached to the position for boosted emissions; `0` for none |

The minted tokenId is registered in fuse storage. `exit(RamsesV2NewPositionFuseExitData)` burns
the listed tokenIds and unregisters them; a position must have zero liquidity and nothing left to
collect, and ids that are not tracked are skipped.

### `RamsesV2ModifyPositionFuse`

`enter` increases liquidity of `tokenId` (`token0`/`token1` checked as substrates, desired/min
amounts, deadline). `exit` decreases `liquidity` units with `amount0Min`/`amount1Min` floors.
**A decrease only accrues owed tokens on the NFT**; `RamsesV2CollectFuse` moves them to the vault.

### `RamsesV2CollectFuse`

`enter(RamsesV2CollectFuseEnterData{ uint256[] tokenIds })` calls `collect` with
`amount0Max = amount1Max = type(uint128).max` and the vault as recipient. Enter only.

A full close is one `FuseAction` batch: `Modify.exit` (to 0) → `Collect.enter` →
`NewPosition.exit` (burn).

### `RamsesClaimFuse` (reward fuse)

`claim(tokenIds, tokenRewards)` calls `NonfungiblePositionManager.getReward(tokenId, tokens)`
for each position and transfers whatever balance increased to the `RewardsClaimManager`. It
reverts with `RamsesClaimFuseRewardsClaimManagerNotSet` when the vault has no manager, and with
`RamsesClaimFuseTokenIdsAndTokenRewardsLengthMismatch` when the arrays differ in length. It does
not check substrates. It is executed through `RewardsClaimManager.claimRewards` (CLAIM_REWARDS_ROLE, 600) after being registered there with `addRewardFuses` (FUSE_MANAGER_ROLE, 300) — not through
`PlasmaVault.execute`.

## Balance Calculation

`RamsesV2Balance.balanceOf()` iterates the tracked tokenIds and, for each, reads the position from
the position manager, gets the pool from the Ramses factory, computes principal at the current
pool price and uncollected fees from fee growth, then converts `amount0` and `amount1` to USD with
`IPriceOracleMiddleware.getAssetPrice` and the tokens' decimals. Result in WAD (18 decimals).
Unclaimed gauge rewards are **not** part of the balance.

## Substrate Configuration

Substrates are token addresses granted as assets:

```solidity
bytes32[] memory substrates = new bytes32[](2);
substrates[0] = PlasmaVaultConfigLib.substrateAsAssetToBytes32(token0);
substrates[1] = PlasmaVaultConfigLib.substrateAsAssetToBytes32(token1);
governance.grantMarketSubstrates(IporFusionMarkets.RAMSES_V2_POSITIONS, substrates);
```

`RamsesV2NewPositionFuse.enter` and `RamsesV2ModifyPositionFuse.enter` check `token0` and
`token1` with `PlasmaVaultConfigLib.isSubstrateAsAssetGranted`. The pool and its fee tier are not
substrates: any Ramses V2 pool of two granted tokens is allowed. Exit, collect, claim and the
balance fuse do not check substrates; they act on tracked tokenIds only.

## Price Oracle Setup

Every pool token needs a price feed in the vault's price oracle middleware
(`PriceOracleMiddlewareManager`, falling back to `PriceOracleMiddleware`); `balanceOf` reverts
otherwise. The tests also register the tokens under `ERC20_VAULT_BALANCE` (market 7) so that
collected tokens and claimed rewards held by the vault are valued.

## Roles

| Action                                  | Role                                                            |
| --------------------------------------- | --------------------------------------------------------------- |
| execute the action fuses                | ALPHA_ROLE (200) via `PlasmaVault.execute`                      |
| register action and balance fuses       | FUSE_MANAGER_ROLE (300)                                         |
| grant substrates                        | FUSE_MANAGER_ROLE (300)                                         |
| set the market limit                    | ATOMIST_ROLE (100)                                              |
| add price sources                       | PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE (1200)                     |
| register the reward fuse in the manager | FUSE_MANAGER_ROLE (300)                                         |
| run `claim`                             | CLAIM_REWARDS_ROLE (600) via `RewardsClaimManager.claimRewards` |

## Tests

Fork tests on Arbitrum at block 254261635 (`ARBITRUM_PROVIDER_URL`):

- `test/fuses/ramses/RamsesV2PositionFuseTest.t.sol`
- `test/fuses/ramses/RamsesClaimFuseTest.t.sol`

## Deployments and notes

- The fuses are listed in the IPOR address registry under the Clearstar client directory
  (`IPOR-Labs/ipor-abi`, `mainnet/mainnet-arbitrum-clearstar/addresses.json`, commit `a0089cf`
  of 2026-09-02), not in the generic Arbitrum fusion set. The catalog entry
  `arbitrum-ramses-market-18` in `catalog/fuses.json` records the observed addresses, block and
  code hashes; check it before encoding calls against a deployment.
- `RamsesV2ModifyPositionFuse` and `RamsesV2CollectFuse` share their `enter`/`exit` selectors
  with the Uniswap V3 counterparts (same struct layouts); only `RamsesV2NewPositionFuse.enter`
  differs, by the extra `veRamTokenId` field.
- The struct comments of `RamsesV2NewPositionFuseExitData` still say "Uniswap V3"; the code
  targets the Ramses position manager.
