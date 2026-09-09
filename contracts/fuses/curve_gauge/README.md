# Curve Child Liquidity Gauge Integration

## Overview

Stakes Curve LP tokens in a Curve **child liquidity gauge** (the gauge type deployed on
sidechains/L2s such as Arbitrum), unstakes them, values the stake and claims gauge rewards.
The LP token itself is obtained through another market: a StableSwap-NG pool
([`curve_stableswap_ng`](../curve_stableswap_ng/README.md), market 16) or an ERC4626 vault
(for example a Curve lending vault, market `ERC4626_0001`).

## Market Structure

Two markets share the same supply fuse and differ in how the stake is valued:

- **Market ID 17** (`CURVE_LP_GAUGE`) — gauges whose LP token is a StableSwap-NG pool that
  contains the vault's underlying asset; balance fuse `CurveChildLiquidityGaugeBalanceFuse`.
- **Market ID 25** (`CURVE_GAUGE_ERC4626`) — gauges whose LP token is an ERC4626 vault;
  balance fuse `CurveChildLiquidityGaugeErc4626BalanceFuse`.

The fuses take the market id as a constructor argument, so one instance per market is deployed.
In the tests market 17 declares market 16 as a balance dependency and market 25 declares
`ERC4626_0001`.

## Architecture

### Key Components

- **`CurveChildLiquidityGaugeSupplyFuse`** — `deposit` / `withdraw` on the gauge, plus
  `instantWithdraw` for market 25 (ERC4626 LP tokens only).
- **`CurveChildLiquidityGaugeBalanceFuse`** — market 17 valuation.
- **`CurveChildLiquidityGaugeErc4626BalanceFuse`** — market 25 valuation.
- **`CurveGaugeTokenClaimFuse`** (`contracts/rewards_fuses/curve_gauges/`) — reward claim
  fuse, executed through `RewardsClaimManager`.

### CurveChildLiquidityGaugeSupplyFuse

`enter(CurveChildLiquidityGaugeSupplyFuseEnterData)` — selector `0xd5ee7916`

| Field                 | Type      | Meaning                                                                                        |
| --------------------- | --------- | ---------------------------------------------------------------------------------------------- |
| `childLiquidityGauge` | `address` | Gauge to stake into; must be a granted substrate; the LP token is read from `gauge.lp_token()` |
| `lpTokenAmount`       | `uint256` | LP tokens to stake (18 decimals); capped at the vault's LP balance; `0` is a no-op             |

`exit(CurveChildLiquidityGaugeSupplyFuseExitData)` — selector `0x92876ac8`

| Field                 | Type      | Meaning                                                                                    |
| --------------------- | --------- | ------------------------------------------------------------------------------------------ |
| `childLiquidityGauge` | `address` | Gauge to unstake from; must be a granted substrate                                         |
| `lpTokenAmount`       | `uint256` | Staked LP tokens to withdraw (18 decimals); capped at the vault's gauge balance; `0` no-op |

`exit` reverts if the gauge withdraw fails. `instantWithdraw(bytes32[] params)` takes
`params[0]` = amount of the vault's underlying asset, `params[1]` = gauge address, converts
the amount with `previewWithdraw` on the ERC4626 LP token (rounds up), reverts with
`CurveChildLiquidityGaugeSupplyFuseInsufficientStakedBalance` when the stake is too small, and
catches a failing withdraw (event `CurveChildLiquidityGaugeSupplyFuseExitFailed`). It is only
meaningful for market 25.

`enterTransient()` / `exitTransient()` read the same fields from transient storage.

### CurveGaugeTokenClaimFuse

`claim()` — selector `0x4e71d92d`, no parameters. For every substrate gauge it reads
`reward_count()`, `reward_tokens(j)` and `claimable_reward(vault, token)`, calls
`claim_rewards(vault, vault)` when anything is claimable and transfers each claimed token to the
`RewardsClaimManager` (reverts with `Errors.WrongAddress` when no manager is configured). It is
registered in `RewardsClaimManager` and executed by `CLAIM_REWARDS_ROLE` (600) through
`RewardsClaimManager.claimRewards`, not through `PlasmaVault.execute`.

## Balance Calculation

Both balance fuses value only the **vault's underlying asset** and ignore rewards:

- Market 17: `stakedBalance = gauge.balanceOf(vault)`; converted with
  `pool.calc_withdraw_one_coin(stakedBalance, index of the vault asset)`; reverts with
  `AssetNotFoundInCurvePool` if the pool does not contain the vault asset.
- Market 25: `stakedBalance = gauge.balanceOf(vault)` (1:1 with LP tokens); converted with
  `ERC4626(lpToken).convertToAssets(stakedBalance)`.

The amount is then priced with the middleware's price for the vault asset and returned as USD
in 18 decimals.

## Substrate Configuration

Substrates are the **gauge addresses** (address-shaped, granted with
`PlasmaVaultGovernance.grantMarketSubstrates`). The supply fuse checks
`PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, gauge)` on enter, exit and
`instantWithdraw`; the balance fuses and the claim fuse iterate the same list.

## Price Oracle Setup

Only the vault's underlying asset needs a price source. Reward tokens are moved to the
`RewardsClaimManager` and are not valued by these fuses.

## Roles

- `ALPHA_ROLE` (200) executes `enter`/`exit`; `CLAIM_REWARDS_ROLE` (600) executes `claim`
  through the `RewardsClaimManager`.
- `FUSE_MANAGER_ROLE` (300) adds the fuses (in the vault and in the `RewardsClaimManager`) and
  grants substrates.
- `ATOMIST_ROLE` (100) sets the market limits; `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE` (1200)
  the price sources.

## Tests

- `test/integrationTest/curveGaugesArbitrum/CurveUSDMUSDCStakeLPGaugeArbitrum.t.sol` (market 17, Arbitrum fork)
- `test/integrationTest/curveGaugesArbitrum/CurveUSDMUSDCClaimLPGaugeArbitrum.t.sol` (market 17 + claim, Arbitrum fork)
- `test/strategies/curve_arbitrum/CurveIntegrationTest.t.sol` (market 25, Arbitrum fork)

## Deployments

No gauge fuse is listed in the IPOR address registry (`IPOR-Labs/ipor-abi`) on any chain as
of 2026-09-09; the catalog entries `arbitrum-curve-gauge-market-17` and
`arbitrum-curve-gauge-erc4626-market-25` record the deployments as `unknown`.

## Security Notes

- The gauge share is 1:1 with the LP token; `calc_withdraw_one_coin` and `convertToAssets`
  are spot views and are only as manipulation-resistant as the pool or vault behind them.
- `instantWithdraw` on a market-17 gauge (StableSwap-NG LP token) would call `previewWithdraw`
  on a contract that does not implement it; configure instant withdrawal only for market 25.
