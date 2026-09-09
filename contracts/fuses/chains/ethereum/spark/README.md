# Spark Integration

## Overview

Two unrelated Spark products are reachable from IPOR Fusion, under two market IDs:

- **Savings DAI (sDAI)** — the fuses in this directory deposit DAI into the sDAI ERC4626
  vault and withdraw it. This is the `SPARK` market.
- **SparkLend** — Spark's Aave V3 fork. It has **no fuse of its own**: the generic Aave V3
  fuses in [`../../../aave_v3/`](../../../aave_v3/) are deployed with SparkLend's
  `PoolAddressesProvider` as constructor argument and run under the `SPARK_LEND` market.

## Market Structure

| Market ID | Constant     | Fuses                                                                                                                     |
| --------- | ------------ | ------------------------------------------------------------------------------------------------------------------------- |
| 15        | `SPARK`      | `SparkSupplyFuse`, `SparkBalanceFuse` (this directory)                                                                    |
| 44        | `SPARK_LEND` | `AaveV3SupplyFuse`, `AaveV3BorrowFuse`, `AaveV3CollateralFuse`, `AaveV3WithPriceOracleMiddlewareBalanceFuse` (`aave_v3/`) |

Constants: [`contracts/libraries/IporFusionMarkets.sol`](../../../../libraries/IporFusionMarkets.sol).

## Architecture

### `SparkSupplyFuse` (market 15)

Ethereum-only: DAI (`0x6B175474E89094C44Da98b954EedeAC495271d0F`) and sDAI
(`0x83F20F44975D03b1b09e64809B757c47f942BEeA`) are hardcoded constants.

| Operation                          | Data                               | Meaning                                                                                                           |
| ---------------------------------- | ---------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `enter`                            | `SparkSupplyFuseEnterData{amount}` | DAI to deposit into sDAI, in DAI smallest units (18 decimals). `0` is a no-op. Approves sDAI and calls `deposit`. |
| `exit`                             | `SparkSupplyFuseExitData{amount}`  | DAI to withdraw from sDAI, capped at `ISavingsDai.maxWithdraw(vault)`. `0` is a no-op.                            |
| `instantWithdraw`                  | `params[0]` = amount               | Same as `exit`, but a failing `withdraw` is caught and `SparkSupplyFuseExitFailed` is emitted.                    |
| `enterTransient` / `exitTransient` | `inputs[0]` = amount               | Transient-storage variants; output `[0]` = sDAI shares minted / burned.                                           |

The fuse **does not check substrates**: neither `enter` nor `exit` calls
`PlasmaVaultConfigLib`. Granting sDAI as the market substrate (as the tests do) documents
intent but is not enforced by the code.

### SparkLend fuses (market 44)

See [`aave_v3/`](../../../aave_v3/) for the data structs. In short:

| Fuse                   | `enter`                                                               | `exit`                                     |
| ---------------------- | --------------------------------------------------------------------- | ------------------------------------------ |
| `AaveV3SupplyFuse`     | `(address asset, uint256 amount, uint256 userEModeCategoryId)` supply | `(address asset, uint256 amount)` withdraw |
| `AaveV3BorrowFuse`     | `(address asset, uint256 amount)` borrow (variable rate)              | `(address asset, uint256 amount)` repay    |
| `AaveV3CollateralFuse` | `enter(address asset)` enable as collateral                           | `exit(address asset)` disable              |

Every call requires `asset` to be a granted substrate of market 44
(`PlasmaVaultConfigLib.isSubstrateAsAssetGranted`). The pool is resolved at call time from
the fuse's immutable `AAVE_V3_POOL_ADDRESSES_PROVIDER`; for SparkLend that is
`0x02C3eA4e34C0cBd694D2adFa2c690EECbC1793eE` on Ethereum (registry name
`SparkLendPoolAddressesProvider` in IPOR-Labs/ipor-abi).

## Balance Calculation

- **Market 15** — `SparkBalanceFuse.balanceOf()` = `sDAI.balanceOf(vault)` × price of
  **sDAI** from the price oracle middleware, normalized to WAD. There is no
  `convertToAssets`, so the middleware must have a price source for the sDAI token itself.
  The fuse's NatSpec says it validates that sDAI is granted as a substrate; the code does not.
- **Market 44** — `AaveV3WithPriceOracleMiddlewareBalanceFuse.balanceOf()` iterates the
  granted assets and sums `aToken − stableDebt − variableDebt` per asset, priced through
  the middleware, in WAD. A zero price reverts; a net negative total reverts on the
  `int256 → uint256` cast.

## Substrate Configuration

- **Market 15**: address-shaped; the tests grant sDAI. Not read by the fuses (see above).
- **Market 44**: address-shaped; the underlying reserve assets listed on SparkLend that the
  vault may supply, borrow or use as collateral (e.g. DAI, USDC, USDS, WETH, wstETH). Granted
  with `PlasmaVaultGovernance.grantMarketSubstrates`.

## Price Oracle Setup

- Market 15: a price source for **sDAI**.
- Market 44: a price source for every granted reserve asset.

Configured through `PriceOracleMiddlewareManager` (or the `PriceOracleMiddleware` it falls
back to) by `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE` (1200).

## Roles

`ALPHA_ROLE` (200) executes, `FUSE_MANAGER_ROLE` (300) registers fuses and grants
substrates, `ATOMIST_ROLE` (100) sets market limits.

## Tests

- Market 15: [`test/fuses/spark/SparkSupplyFuseTest.t.sol`](../../../../../test/fuses/spark/SparkSupplyFuseTest.t.sol)
  (Ethereum fork at block 19538857; note that the fixture instantiates the fuses with market
  id `1`, not `SPARK`).
- Market 44: no SparkLend-specific test exists in this checkout. The Aave V3 suites under
  `test/fuses/aave_v3/` exercise the same source against Aave's provider.

## Deployed fuses

Read from IPOR-Labs/ipor-abi (`a0089cf`, 2026-09-02) and on chain at Ethereum block
25939091, see [`catalog/fuses.json`](../../../../../catalog/fuses.json):

- Market 44: `SparkLendSupplyFuse` `0x81DD10690E5690177F052b1b74c3070734831106`,
  `SparkLendBorrowFuse` `0xE3aBaE104B259c523f022a880AD4a73ea8DE4c5e`,
  `SparkLendCollateralFuse` `0xACba93fAFc6886694583D20752D20Fb312d1cE46`,
  `SparkLendWithPriceOracleMiddlewareBalanceFuse` `0x05397aDb7A0B596DF88BCa2b06c0cbfB28e5222d`
  (all answer `MARKET_ID() == 44`; the action fuses lack `enterTransient()` and the balance fuse
  lacks `VERSION()`, so they are older than this checkout).
- Market 15 (`mainnet/mainnet-ethereum/addresses.json`): `SupplyFuseSpark`
  `0xB48CF802C2D648c46ac7f752C81e29Fa2C955E9B` (`MARKET_ID() == 15`, `enter((uint256))` /
  `exit((uint256))` present, no `enterTransient()`), `BalanceFuseSpark`
  `0xb3ca07c9c10374D51046F94e5547a2C501DA0ab4` (`MARKET_ID() == 15`, no `VERSION()`).

## Security notes

- `SparkSupplyFuse` has no slippage guard and no substrate check; the only cap is
  `maxWithdraw` on exit.
- `SparkBalanceFuse` prices sDAI directly; a missing or wrong sDAI price source silently
  changes the vault's NAV.
- SparkLend fuses share code with Aave V3: the market a fuse belongs to is decided by the
  provider it was constructed with, which is not visible from the fuse's ABI. Verify
  `AAVE_V3_POOL_ADDRESSES_PROVIDER()` on the deployed fuse before registering it.
