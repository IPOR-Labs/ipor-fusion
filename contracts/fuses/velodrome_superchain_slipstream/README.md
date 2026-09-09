# Velodrome Superchain Slipstream Integration

## Overview

Velodrome Superchain Slipstream is Velodrome's concentrated-liquidity AMM on OP Stack
Superchain networks. Liquidity is held as NFT positions (a token pair, a tick spacing and a
tick range) minted by a `NonfungiblePositionManager`, and positions can be staked in
`LeafCLGauge` contracts to earn emissions.

This integration lets a Plasma Vault open, resize, collect from, close and stake such
positions, and values them with a dedicated balance fuse. Emission rewards are **not** part
of the balance: they are claimed through the `RewardsClaimManager` with a reward fuse.

The sibling integration for Velodrome V2 (non-concentrated) pools lives in
[`../velodrome_superchain/`](../velodrome_superchain/README.md). Both share the same
substrate packing but use **different market IDs**.

## Market Structure

The integration uses a single market for all operations:

- **Market ID 32** (`IporFusionMarkets.VELODROME_SUPERCHAIN_SLIPSTREAM`) – mint / burn,
  increase / decrease liquidity, collect, gauge stake / unstake, reward claim, balance.

Every fuse takes the market ID as a constructor argument (`marketId_`) and stores it in
`MARKET_ID`.

## Architecture

### Key components

| Contract                                                                                                                                  | Purpose                                                                                                                            |
| ----------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| [`VelodromeSuperchainSlipstreamNewPositionFuse`](VelodromeSuperchainSlipstreamNewPositionFuse.sol)                                        | `enter`: mints a new position NFT; `exit`: burns position NFTs.                                                                    |
| [`VelodromeSuperchainSlipstreamModifyPositionFuse`](VelodromeSuperchainSlipstreamModifyPositionFuse.sol)                                  | `enter`: increases liquidity of an existing position; `exit`: decreases it.                                                        |
| [`VelodromeSuperchainSlipstreamCollectFuse`](VelodromeSuperchainSlipstreamCollectFuse.sol)                                                | `enter`: collects owed fees and decreased-liquidity amounts of positions to the vault.                                             |
| [`VelodromeSuperchainSlipstreamLeafCLGaugeFuse`](VelodromeSuperchainSlipstreamLeafCLGaugeFuse.sol)                                        | `enter`: stakes a position NFT in a `LeafCLGauge`; `exit`: unstakes it.                                                            |
| [`VelodromeSuperchainSlipstreamBalanceFuse`](VelodromeSuperchainSlipstreamBalanceFuse.sol)                                                | `balanceOf`: USD value of the vault's positions in pools and gauges.                                                               |
| [`VelodromeSuperchainSlipstreamSubstrateLib`](VelodromeSuperchainSlipstreamSubstrateLib.sol)                                              | Substrate packing and `getPoolAddress` (factory lookup by `token0`, `token1`, `tickSpacing`).                                      |
| [`VelodromeSuperchainSlipstreamGaugeClaimFuse`](../../rewards_fuses/velodrome_superchain/VelodromeSuperchainSlipstreamGaugeClaimFuse.sol) | Reward fuse: `claim(address[] gauges)` collects emissions of every staked position and forwards them to the `RewardsClaimManager`. |

External interfaces used: `INonfungiblePositionManager`, `ICLPool`, `ICLFactory`,
`ILeafCLGauge`, `ISlipstreamSugar` (all under `ext/`).

### Position lifecycle

```
NewPositionFuse.enter  ──► NFT minted to the vault, tokenId recorded in FuseStorageLib
        │
        ├── ModifyPositionFuse.enter / exit   (increase / decrease liquidity)
        ├── CollectFuse.enter                 (fees + freed tokens → vault)
        ├── LeafCLGaugeFuse.enter / exit      (stake / unstake NFT in a gauge)
        └── GaugeClaimFuse.claim              (emissions → RewardsClaimManager)
        │
NewPositionFuse.exit   ──► NFT burned (liquidity must be 0 and fees collected), tokenId removed
```

### Enter / exit data

**`VelodromeSuperchainSlipstreamNewPositionFuse`**

| Operation | Struct                                                  | Fields                                                                                                                                                                                                                                                                                  |
| --------- | ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `enter`   | `VelodromeSuperchainSlipstreamNewPositionFuseEnterData` | `token0`, `token1`, `tickSpacing` (identify the pool), `tickLower`, `tickUpper`, `amount0Desired`, `amount1Desired` (token smallest units), `amount0Min`, `amount1Min` (slippage floors), `deadline` (unix seconds), `sqrtPriceX96` (Q64.96, used only if the pool must be initialised) |
| `exit`    | `VelodromeSuperchainSlipstreamNewPositionFuseExitData`  | `tokenIds[]` – positions to burn; each must have zero liquidity and no uncollected fees                                                                                                                                                                                                 |

**`VelodromeSuperchainSlipstreamModifyPositionFuse`**

| Operation | Struct                                                     | Fields                                                                                                                            |
| --------- | ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `enter`   | `VelodromeSuperchainSlipstreamModifyPositionFuseEnterData` | `token0`, `token1`, `tokenId`, `amount0Desired`, `amount1Desired`, `amount0Min`, `amount1Min`, `deadline`                         |
| `exit`    | `VelodromeSuperchainSlipstreamModifyPositionFuseExitData`  | `tokenId`, `liquidity` (uint128 liquidity units), `amount0Min`, `amount1Min`, `deadline` – freed tokens stay owed until collected |

**`VelodromeSuperchainSlipstreamCollectFuse`** – `enter(VelodromeSuperchainSlipstreamCollectFuseEnterData{tokenIds[]})`
collects with `amount0Max = amount1Max = type(uint128).max`. No `exit`.

**`VelodromeSuperchainSlipstreamLeafCLGaugeFuse`** – `enter` / `exit` with
`{gaugeAddress, tokenId}`. `enter` approves the gauge on the position manager and deposits;
`exit` withdraws and revokes the approval. A `tokenId` of 0 on `enter` is a no-op.

**`VelodromeSuperchainSlipstreamGaugeClaimFuse`** – `claim(address[] gauges_)`; for every gauge
it reads `stakedValues(vault)` and calls `getReward(tokenId)` per position, then transfers
the `rewardToken()` delta to the `RewardsClaimManager`. An empty list reverts.

All action fuses also expose `enterTransient()` / `exitTransient()` reading their inputs from
`TransientStorageLib` (input layout documented in each fuse).

## Balance Calculation

`VelodromeSuperchainSlipstreamBalanceFuse.balanceOf()` iterates the market's substrates:

- **Pool substrate** – for every token id in the curated `FuseStorageLib` list whose position
  belongs to that pool (checked through `positions(tokenId)` and `ICLFactory.getPool`):
  principal (`ISlipstreamSugar.principal` at the pool's current `sqrtPriceX96`) **plus**
  uncollected fees (`ISlipstreamSugar.fees`).
- **Gauge substrate** – for every token id in `ILeafCLGauge.stakedValues(vault)`: principal
  only (fees of staked positions go to voters, not to the staker).
- Emissions are **not** counted.

Amounts of `token0` / `token1` are converted with the vault's `PriceOracleMiddleware`
(`getAssetPrice`) and normalised to **USD in WAD (18 decimals)**.

Only positions minted through `VelodromeSuperchainSlipstreamNewPositionFuse` are valued for
pool substrates: the fuse records each minted `tokenId` in
`FuseStorageLib.getVelodromeSuperchainSlipstreamTokenIds()` and removes it on burn. NFTs
transferred to the vault by third parties are ignored, which prevents gas-griefing through
unbounded NFT enumeration. If a substrate holds more than `MAX_POSITIONS_PER_SUBSTRATE`
(constructor argument, default 50) positions, `balanceOf` reverts with `TooManyPositions`
and positions must be consolidated first.

## Substrate Configuration

Substrates are `bytes32` values packed by `VelodromeSuperchainSlipstreamSubstrateLib`:

```solidity
enum VelodromeSuperchainSlipstreamSubstrateType { UNDEFINED, Gauge, Pool }

struct VelodromeSuperchainSlipstreamSubstrate {
    VelodromeSuperchainSlipstreamSubstrateType substrateType;
    address substrateAddress;
}

// bytes32 = address | (uint256(substrateType) << 160)
bytes32 substrate = VelodromeSuperchainSlipstreamSubstrateLib.substrateToBytes32(
    VelodromeSuperchainSlipstreamSubstrate({substrateType: ..., substrateAddress: ...})
);
```

- `Pool` – the CL pool address returned by `ICLFactory.getPool(token0, token1, tickSpacing)`.
  Checked by the new-position and modify-position fuses (`enter` and `exit`); a missing pool
  reverts with `PoolNotDeployed`.
- `Gauge` – a `LeafCLGauge` address. Checked by the gauge fuse and by the reward claim fuse.
- The collect fuse performs no substrate check: the position manager only pays out
  positions the vault owns.

Grant them with `PlasmaVaultGovernance.grantMarketSubstrates(marketId, bytes32[])`
(`FUSE_MANAGER_ROLE`); the fuses verify with `PlasmaVaultConfigLib.isMarketSubstrateGranted`.
The reward claim fuse encodes its check with the non-Slipstream `VelodromeSuperchainSubstrateLib`,
whose packing is bit-identical, so one grant serves both.

## Price Oracle Setup

Price feeds are required for `token0` and `token1` of every pool substrate
(`PriceOracleMiddlewareManager` or `PriceOracleMiddleware`). The emission token needs no
feed for the balance fuse, since emissions are not valued here.

## Roles

| Action                                                 | Role                                                               |
| ------------------------------------------------------ | ------------------------------------------------------------------ |
| `PlasmaVault.execute` with any action fuse             | `ALPHA_ROLE` (200)                                                 |
| Add action fuses and the balance fuse                  | `FUSE_MANAGER_ROLE` (300)                                          |
| Grant market substrates                                | `FUSE_MANAGER_ROLE` (300)                                          |
| Set the market limit                                   | `ATOMIST_ROLE` (100)                                               |
| Add price sources                                      | `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE` (1200)                      |
| Register the claim fuse in the `RewardsClaimManager`   | `FUSE_MANAGER_ROLE` (300) via `RewardsClaimManager.addRewardFuses` |
| `RewardsClaimManager.claimRewards` with the claim fuse | `CLAIM_REWARDS_ROLE` (600)                                         |

## Tests

- [`test/fuses/velodrome/VelodromeSuperchainSlipstreamTest.t.sol`](../../../test/fuses/velodrome/VelodromeSuperchainSlipstreamTest.t.sol)
  – fork of Ink (`INK_PROVIDER_URL`, block 20419547), covers mint, modify, collect, gauge
  stake / unstake, claim and balance. Note the test directory is `velodrome`, not
  `velodrome_superchain_slipstream`.

## Deployments

Fuses for this market are deployed on **Ink (chain 57073)** and listed in
`IPOR-Labs/ipor-abi` (`mainnet/mainnet-ink-fusion/addresses.json`) under two naming
generations (`VelodromeSuperchainSlipstream*Fuse` and `*FuseVelodromeSuperchainSlipstream`).
Their observed state, code hashes and how they differ from this checkout are recorded in
[`catalog/fuses.json`](../../../catalog/fuses.json) (entry
`ink-velodrome-superchain-slipstream-market-32`). In particular, the deployed balance fuses
read on 2026-09-09 do not expose `VERSION()` or `MAX_POSITIONS_PER_SUBSTRATE()`, so they
predate the curated token-id list described above.

## Security Notes

- Every action approves the position manager with `forceApprove` for the exact amount and
  resets the approval to 0 afterwards; the gauge fuse revokes the NFT approval on withdraw.
- Slippage is enforced by the position manager through `amount0Min` / `amount1Min` and the
  `deadline`; pass meaningful values, they are not defaulted by the fuse.
- `exit` of the new-position fuse burns NFTs; burn reverts while a position still has
  liquidity or uncollected fees, so decrease and collect first.
- The balance fuse's positions cap is a deliberate DoS guard: a revert of `balanceOf` blocks
  vault accounting until positions are consolidated.
- The Slipstream claim fuse reuses `VelodromeSuperchainSubstrateLib` from the V2 integration;
  keep the two libraries' packing in sync if either changes.
