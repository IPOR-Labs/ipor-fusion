# Aerodrome Slipstream Integration

## Overview

This module integrates IPOR Fusion Plasma Vaults with [Aerodrome Slipstream](https://aerodrome.finance/) on Base:
the concentrated-liquidity (Uniswap V3 style) pools of Aerodrome. A vault can mint NFT liquidity positions in a
Slipstream pool, grow or shrink them, collect the fees they earn, stake the NFTs in a CL gauge for AERO emissions,
and claim those emissions through the rewards path.

The contract names and the market constant carry a historical typo: contracts are named `AreodromeSlipstream*`
and the constant is `IporFusionMarkets.AREODROME_SLIPSTREAM`. The source directories use the correct spelling,
as do the registry names of the deployed contracts (`...FuseAerodromeSlipstream`).

## Market Structure

The integration uses a single market for all operations:

- **Market ID 33** (`AREODROME_SLIPSTREAM`) — new position / modify position / collect / CL gauge / balance /
  gauge rewards claim.

## Architecture

### Key Components

| Contract                                | Purpose                                                                                         |
| --------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `AreodromeSlipstreamNewPositionFuse`    | `enter`: mints a new NFT position; `exit`: burns emptied positions. Tracks the vault's NFT ids. |
| `AreodromeSlipstreamModifyPositionFuse` | `enter`: increases liquidity of a position; `exit`: decreases it.                               |
| `AreodromeSlipstreamCollectFuse`        | `enter`: collects tokens owed to positions (fees and amounts freed by a decrease). No exit.     |
| `AreodromeSlipstreamCLGaugeFuse`        | `enter`: stakes an NFT into a CL gauge; `exit`: withdraws it.                                   |
| `AreodromeSlipstreamBalanceFuse`        | Values the vault's positions (unstaked and staked) in USD.                                      |
| `AreodromeSlipstreamGaugeClaimFuse`     | Reward fuse: claims AERO from CL gauges into the `RewardsClaimManager`.                         |
| `AreodromeSlipstreamSubstrateLib`       | Packs / unpacks substrates and resolves a pool address from `(token0, token1, tickSpacing)`.    |

All action fuses are executed by the vault through `delegatecall` (`PlasmaVault.execute`), so `address(this)` is
the vault, the NFTs are owned by the vault, and the token-id list is written to the vault's storage
(`FuseStorageLib.getAerodromeSlipstreamTokenIds()`, ERC-7201 namespace `io.ipor.AerodromeSlipstreamTokenIds`).

### AreodromeSlipstreamNewPositionFuse

`enter(AreodromeSlipstreamNewPositionFuseEnterData)`:

| Field            | Type      | Meaning                                                                                                     |
| ---------------- | --------- | ----------------------------------------------------------------------------------------------------------- |
| `token0`         | `address` | First pool token. The pool is `CLFactory.getPool(sorted(token0, token1), tickSpacing)` and must be granted. |
| `token1`         | `address` | Second pool token.                                                                                          |
| `tickSpacing`    | `int24`   | Tick spacing of the Slipstream pool (part of the pool identity).                                            |
| `tickLower`      | `int24`   | Lower tick of the range.                                                                                    |
| `tickUpper`      | `int24`   | Upper tick of the range.                                                                                    |
| `amount0Desired` | `uint256` | token0 to add, in token0's smallest unit. Approved to the position manager for this call only.              |
| `amount1Desired` | `uint256` | token1 to add, in token1's smallest unit.                                                                   |
| `amount0Min`     | `uint256` | Slippage floor on token0 actually added (enforced by the position manager).                                 |
| `amount1Min`     | `uint256` | Slippage floor on token1 actually added.                                                                    |
| `deadline`       | `uint256` | Unix timestamp (seconds) after which the mint reverts.                                                      |
| `sqrtPriceX96`   | `uint160` | Initial sqrt price (Q64.96), used only if the mint creates the pool; `0` for an existing pool.              |

The minted `tokenId` is appended to the vault's tracked list. Approvals are reset to zero after the mint.

`exit(AreodromeSlipstreamNewPositionFuseExitData)`: `tokenIds` — positions to burn. A position must have zero
liquidity and no uncollected tokens (decrease with the modify fuse and collect first). Each burned id is removed
from the tracked list (swap-and-pop).

### AreodromeSlipstreamModifyPositionFuse

`enter(AreodromeSlipstreamModifyPositionFuseEnterData)`: `tokenId`, `amount0Desired`, `amount1Desired`,
`amount0Min`, `amount1Min`, `deadline` (a past deadline reverts `DeadlineExpired`; both amounts zero reverts
`InvalidAmount`). `token0` / `token1` are informational: the fuse reads the position's tokens from the position
manager, checks that the position's pool is a granted Pool substrate, and approves those tokens.

`exit(AreodromeSlipstreamModifyPositionFuseExitData)`: `tokenId`, `liquidity` (liquidity units, non-zero),
`amount0Min`, `amount1Min`, `deadline`. Decreasing liquidity only makes the tokens _owed_ to the position; collect
them with the collect fuse.

### AreodromeSlipstreamCollectFuse

`enter(AreodromeSlipstreamCollectFuseEnterData)`: `tokenIds` — positions to collect from, with
`amount0Max = amount1Max = type(uint128).max`, recipient = the vault. This fuse performs **no substrate check**: any
position the vault owns can be collected. An empty list returns without acting.

### AreodromeSlipstreamCLGaugeFuse

`enter(AreodromeSlipstreamCLGaugeFuseEnterData)`: `gaugeAddress` (must be a granted Gauge substrate), `tokenId`
(zero returns without acting). The fuse approves the gauge on `gauge.nft()` for the token and calls
`gauge.deposit(tokenId)`. `exit(AreodromeSlipstreamCLGaugeFuseExitData)`: same fields, calls
`gauge.withdraw(tokenId)`.

While an NFT is staked, the gauge owns it; fees of a staked position accrue to the gauge's voters, not to the vault.

### AreodromeSlipstreamGaugeClaimFuse (reward fuse)

`claim(address[] gauges_)`: for every gauge (granted Gauge substrate, empty list reverts) reads the NFT ids the
gauge reports as staked by the vault, calls `getReward(tokenId)` for each, and transfers the whole claimed
`rewardToken` balance delta to the `RewardsClaimManager`. It is registered in the `RewardsClaimManager` with
`addRewardFuses` (FUSE_MANAGER_ROLE) and executed with `RewardsClaimManager.claimRewards` (CLAIM_REWARDS_ROLE),
not through `PlasmaVault.execute`.

## Balance Calculation

`AreodromeSlipstreamBalanceFuse.balanceOf()` iterates the market's substrates:

- **Pool substrate**: walks the NFT ids recorded by the new-position fuse (not the vault's whole ERC-721 balance —
  arbitrary NFTs sent to the vault are ignored), keeps those whose `(token0, token1, tickSpacing)` resolve to that
  pool, and adds the principal at the pool's current `sqrtPriceX96` plus the uncollected fees. Both are read through
  the Slipstream Sugar helper (`principal`, `fees`).
- **Gauge substrate**: values the principal of the NFTs the gauge reports as staked by the vault
  (`gauge.stakedValues(vault)`); fees of staked positions are not counted.

A position is therefore counted once: under its pool while unstaked, under its gauge while staked. AERO emissions
are not part of the balance; they are handled by the rewards path.

Amounts of `token0` / `token1` are converted with `PriceOracleMiddleware.getAssetPrice` and summed in USD normalized
to WAD (18 decimals).

## Substrate Configuration

Substrates are `bytes32` values packed by `AreodromeSlipstreamSubstrateLib.substrateToBytes32`:

- low 160 bits: the address,
- bits 160 and up: `AreodromeSlipstreamSubstrateType` (`1 = Gauge`, `2 = Pool`).

| Type    | Address             | Read by                                                                                    |
| ------- | ------------------- | ------------------------------------------------------------------------------------------ |
| `Pool`  | Slipstream CL pool  | new-position fuse (derived from tokens + tick spacing), modify-position fuse, balance fuse |
| `Gauge` | Slipstream CL gauge | CL gauge fuse, gauge claim fuse, balance fuse                                              |

Grant with `PlasmaVaultGovernance.grantMarketSubstrates(IporFusionMarkets.AREODROME_SLIPSTREAM, substrates)`;
the fuses check with `PlasmaVaultConfigLib.isMarketSubstrateGranted`. Both the pool and its gauge must be granted
for a stake / unstake / claim cycle.

## Price Oracle Setup

Every `token0` and `token1` of a granted pool or gauge needs a price source in the vault's
`PriceOracleMiddleware` (added by PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE). Without it `balanceOf()` reverts and the
vault cannot update the market balance.

## Roles

| Action                                              | Role                                          |
| --------------------------------------------------- | --------------------------------------------- |
| `PlasmaVault.execute` with the action fuses         | `ALPHA_ROLE` (200)                            |
| add fuses and the balance fuse, add the reward fuse | `FUSE_MANAGER_ROLE` (300)                     |
| grant substrates                                    | `FUSE_MANAGER_ROLE` (300)                     |
| set the market limit                                | `ATOMIST_ROLE` (100)                          |
| add price sources                                   | `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE` (1200) |
| `RewardsClaimManager.claimRewards`                  | `CLAIM_REWARDS_ROLE` (600)                    |

## Tests

- `test/fuses/aerodrome_slipstream/AreodromeSlipstreamTest.t.sol` — Base fork (`BASE_PROVIDER_URL`, block
  33796435): mint, increase, decrease, collect, burn, stake, unstake, claim, transient-storage variants and revert
  paths.

## Security Notes

- The balance fuse values only the NFT ids the vault minted through the new-position fuse. Positions transferred
  to the vault by other means are not valued and cannot be burned through `exit` (they are not in the list), but
  they can be collected from and modified, because those fuses look positions up by id.
- Fees of staked positions are forfeited to the gauge's voters; the balance fuse reflects that by not counting
  them.
- The collect fuse has no substrate gate; restrict which vault roles may execute it as for any action fuse.
- Deployed Base addresses for this market are recorded with on-chain evidence in
  [`catalog/fuses.json`](../../../catalog/fuses.json) (entry `base-aerodrome-slipstream-market-33`).
