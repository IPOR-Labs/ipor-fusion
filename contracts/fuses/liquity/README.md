# Liquity Stability Pool Integration

## Overview

Liquity Stability Pool integration allows IPOR Fusion to interact with the Liquity Stability Pool contracts. This allows users to deposit BOLD into the Stability Pool and claim the BOLD yield and eventual collateral gained

**What Liquity Stability Pool does:**
The Stability Pool is a yield pool with BOLD asset, conceived to peg the BOLD value by collecting liquidations of the Troves and burning unpaid BOLD debt. A Trove is an ERC721 which contains the borrower's collateral and mints BOLD as a loan to them. If the BOLD loan is not repaid on a given Trove, the Stability Pool will liquidate the Trove by seizing the offender's collateral and burning a corresponding BOLD amount in order to maintain BOLD value stable.

Therefore, after a liquidation, each Stability Pool's LP will see their BOLD deposit decrease, and a quantity of collateral tokens available to be withdrawn. Since the maximum LTV for a Trove is lower than 100% (depending on the collateral, it is between 80% and 90%), Stability Pool LPs experience a net gain from liquidations.

Furthermore, the Stability Pool BOLD accrue value thanks to the borrowers' fees.

## Market Structure

The integration uses a single market for all operations:

-   **Market ID 29** (`LIQUITY_V2`) - provideToSP/claimAllCollGains/withdrawFromSP

## Architecture

### Troves and Stability Pool

**Liquity** has two main components: troves and the stability pool.
- The **Troves** are ERC721 which mint the native "BOLD" token in exchange of a deposit of some collateral (WETH, sUSDe, WBTC...)
- The **Stability Pool** gathers the collateral of the Troves and BOLD tokens deposited by LPs. This is responsible for the stability of BOLD price: every time a liquidation occurs, a quantity of BOLD corresponding to the liquidated trove is burnt from the stability pool and the collateral is handed over to the stability pool's LPs.

### Key Components

-   **`LiquityStabilityPoolFuse`**: Deposits BOLD into the stability pool, withdraws collateral and/or BOLD deposit from it.

## Balance Calculation

The balance corresponding to a Stability Pool deposit is composed of:

- `stashedColl` denominated in collateral token, the already-accumulated collateral the depositor chose not to claim in previous ops
- `depositorCollGain` denominated in collateral token, the not-yet-stashed collateral gain the depositor has earned since the last snapshot
- `compoundedBoldDeposit` denominated in BOLD, the BOLD amount initially deposited shrinked by eventual liquidations
- `getDepositorYieldGain` denominated in BOLD, the fees obtained by borrowers

## Substrate Configuration

### 1. LIQUITY_V2 Market (Market ID: 29) - provideToSP/claimAllCollGains/withdrawFromSP operations

Substrates are addresses corresponding to the address registries of each branch. From them, all the relevant addresses can be obtained via read functions.

#### Registries examples on Ethereum Mainnet:

| Branch Name    | Address Registry Address                     | Collateral Asset |
| -------------- | -------------------------------------------- | ---------------- |
| ETH Branch     | `0x20f7c9ad66983f6523a0881d0f82406541417526` | WETH             |
| wstETH Branch  | `0x8d733f7ea7c23cbea7c613b6ebd845d46d3aac54` | wstETH           |
| rETH Branch    | `0x6106046f031a22713697e04c08b330ddaf3e8789` | rETH             |

Notice that the BOLD token is the same for all branches: `0x6440f144b7e50D6a8439336510312d2F54beB01D` for Mainnet. This fact is crucial for the correct functioning of the BalanceFuse

## Price Oracle Setup

### Required Price Feeds

The integration requires price feeds for all collateral tokens and the BOLD token. Price feed configuration via `Price Oracle Middleware Manager` or `Price Oracle Middleware`
