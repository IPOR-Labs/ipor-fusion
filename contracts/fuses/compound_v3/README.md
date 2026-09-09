# Compound V3 (Comet) Integration

## Overview

The Compound V3 integration lets a Plasma Vault supply the base token or collateral assets of one
Compound V3 market (a **Comet**), withdraw them, value the position and claim COMP rewards.

**What Compound V3 does:** each Comet is a standalone lending market with one borrowable base
token (USDC, USDT, WETH, ...) and a set of collateral assets. Supplying the base token earns
interest; supplying collateral earns nothing but enables borrowing of the base token. Rewards are
paid by a separate `CometRewards` contract.

## Market Structure

One fuse pair is deployed **per Comet**, because the Comet address is a constructor argument, not a
substrate. Each Comet therefore has its own market ID:

- **Market ID 2** (`COMPOUND_V3_USDC`) – the cUSDCv3 Comet
- **Market ID 13** (`COMPOUND_V3_USDT`) – the cUSDTv3 Comet
- **Market ID 26** (`COMPOUND_V3_WETH`) – the cWETHv3 Comet

The constants live in `contracts/libraries/IporFusionMarkets.sol`. The fuses themselves take
`marketId_` and `cometAddress_` in the constructor; the tests deploy them with market ID `1` and
that value carries no meaning outside the test fixture.

## Architecture

### Key Components

- **`CompoundV3SupplyFuse`** – supplies to and withdraws from the bound Comet. Implements
  `IFuseInstantWithdraw`, so it can be listed as an instant-withdrawal fuse.
- **`CompoundV3BalanceFuse`** – values the vault's position in the bound Comet.
- **`CompoundV3ClaimFuse`** (`contracts/rewards_fuses/compound/CompoundV3ClaimFuse.sol`) – claims
  COMP for one Comet into the `RewardsClaimManager`. It has no `MARKET_ID`; one deployment serves
  every Comet on the chain and is bound to that chain's `CometRewards` at construction.

### CompoundV3SupplyFuse

```solidity
struct CompoundV3SupplyFuseEnterData {
    address asset; // base token or collateral asset of the Comet; must be a granted substrate
    uint256 amount; // amount to supply, in the token's smallest unit; 0 is a no-op
}

struct CompoundV3SupplyFuseExitData {
    address asset; // token to withdraw; must be a granted substrate
    uint256 amount; // amount to withdraw, smallest unit; capped at the vault's Comet balance
}
```

- `enter` approves the Comet and calls `Comet.supply(asset, amount)`.
- `exit` reads the vault's balance (`Comet.balanceOf` for the base token,
  `Comet.collateralBalanceOf` otherwise), withdraws `min(amount, balance)` and emits
  `CompoundV3SupplyFuseExit`.
- `instantWithdraw(bytes32[] params)` takes `params[0]` = amount, `params[1]` = asset and runs the
  same exit with exceptions caught: a failed withdrawal emits `CompoundV3SupplyFuseExitFailed`
  instead of reverting, so the instant-withdrawal sequence can continue with the next fuse.
- `enterTransient` / `exitTransient` read `asset` and `amount` from transient storage inputs
  `[0]` and `[1]` and write `(asset, comet, amount)` as outputs.
- An asset that is not a granted substrate reverts with
  `CompoundV3SupplyFuseUnsupportedAsset(action, asset)`.

Deployed signatures (`enter((address,uint256))` `0xd5ee7916`, `exit((address,uint256))`
`0x92876ac8`, `instantWithdraw(bytes32[])` `0xbe1946da`) match this source; see the catalog
entries for the blocks at which that was read.

### CompoundV3ClaimFuse

```solidity
function claim(address comet_) external;
```

Calls `CometRewards.claimTo(comet_, plasmaVault, rewardsClaimManager, true)`; the COMP lands in
the `RewardsClaimManager`, not in the vault. The fuse is registered on the `RewardsClaimManager`
by `FUSE_MANAGER_ROLE` (`addRewardFuses`) and executed by `CLAIM_REWARDS_ROLE` through
`RewardsClaimManager.claimRewards`, not through `PlasmaVault.execute`. It reverts with
`ClaimManagerZeroAddress` when the vault has no rewards claim manager configured.

## Balance Calculation

`CompoundV3BalanceFuse.balanceOf()` iterates the market's substrates and, for each asset, reads the
vault's Comet balance (base token: `balanceOf`; collateral: `collateralBalanceOf`) and multiplies
it by the Comet's own price (`Comet.getPrice(feed)`, 8 decimals, where the feed is
`baseTokenPriceFeed` for the base token and `getAssetInfoByAddress(asset).priceFeed` for
collateral). It then subtracts `Comet.borrowBalanceOf(vault)` priced with the base token feed and
returns the net value in **USD, WAD (18 decimals)**.

Two consequences:

- the vault's `PriceOracleMiddleware` is **not** used for this market; the Comet's feeds are the
  price source;
- the fuse casts the net `int256` to `uint256`, so a position whose debt exceeds its supplied
  value reverts rather than reporting a negative balance.

## Substrate Configuration

Substrates are **token addresses** accepted by the Comet: its base token and its collateral
assets. Grant them with `PlasmaVaultGovernance.grantMarketSubstrates(marketId, substrates)` where
each substrate is the address encoded as `bytes32` (`PlasmaVaultConfigLib.addressToBytes32`).

- the supply fuse checks `PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, asset)` on
  enter and exit;
- the balance fuse values every granted asset, whether or not the vault holds it.

The Comet is not a substrate. Granting an asset the Comet does not accept makes `enter` revert
inside the Comet and makes the balance fuse revert on `getAssetInfoByAddress`.

## Price Oracle Setup

No `PriceOracleMiddleware` source is needed for the valuation of this market. Any asset the vault
holds idle (for example the base token before supplying) still needs a source configured by
`PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE`, as for every other market.

## Roles

| Action                                 | Role                                               |
| -------------------------------------- | -------------------------------------------------- |
| `PlasmaVault.execute` with supply/exit | `ALPHA_ROLE` (200)                                 |
| add the supply and balance fuses       | `FUSE_MANAGER_ROLE` (300)                          |
| grant substrates                       | `FUSE_MANAGER_ROLE` (300)                          |
| set the market limit                   | `ATOMIST_ROLE` (100)                               |
| register the claim fuse                | `FUSE_MANAGER_ROLE` (300) on `RewardsClaimManager` |
| `RewardsClaimManager.claimRewards`     | `CLAIM_REWARDS_ROLE` (600)                         |

## Tests

- `test/fuses/compound_v3/CompoundUsdcV3SupplyFuseTest.t.sol` – Ethereum fork, cUSDCv3
- `test/fuses/compound_v3/CompoundUsdcV3BalanceFuseTest.t.sol` – Ethereum fork, cUSDCv3
- `test/fuses/compound_v3/CompoundWethV3SupplyFuseTest.t.sol` – Ethereum fork, cWETHv3
- `test/fuses/compound_v3/CompoundWethV3BalanceFuseTest.t.sol` – Ethereum fork, cWETHv3
- `test/fuses/compound_v3/CompoundUsdcV3SupplyArbitrumFuseTest.t.sol` – Arbitrum fork
- `test/fuses/compound_v3/CompoundUsdcV3BalanceArbitrumFuseTest.t.sol` – Arbitrum fork
- `test/fuses/compound_v3/CompoundV3ClaimFuseTest.t.sol` – Arbitrum fork, claim through a deployed
  `RewardsClaimManager`
- `test/integrationTest/compoundV3Arbitrum/CompoundV3Arbitrum.t.sol` – Arbitrum fork, full vault

All of them fork a network (`vm.createSelectFork` with `ETHEREUM_PROVIDER_URL` or
`ARBITRUM_PROVIDER_URL`); none runs without an RPC.

## Security Notes

- The Comet address is immutable per deployment. Reusing a fuse deployed for one Comet under
  another market ID does nothing useful: the fuse always talks to its own Comet.
- Prices come from Compound's feeds, so this market's valuation follows Compound's oracle choices,
  not the vault's price oracle middleware.
- `exit` silently caps the amount at the available balance and returns the amount actually
  withdrawn; callers that need the full amount must check the return value.
- The claim fuse sends COMP to the `RewardsClaimManager`; the vault's balance in this market does
  not include unclaimed or claimed rewards.
