# Morpho Blue Integration

## Overview

The Morpho fuses connect an IPOR Fusion PlasmaVault to **Morpho Blue** lending markets: supplying the loan
token, supplying collateral, borrowing and repaying, flash loans with an in-transaction callback, and claiming
rewards from Morpho's `UniversalRewardsDistributor`.

**What Morpho Blue does:** each Morpho market is an isolated pair `(loanToken, collateralToken, oracle, irm, lltv)`
identified by a `bytes32` id (`MarketParamsLib.id`). Suppliers earn interest on the loan token, borrowers post the
collateral token and draw the loan token up to the market's LLTV. The core contract is a single
`Morpho` singleton (`0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` on Ethereum, from the ipor-abi registry) that
every fuse takes as an immutable constructor argument.

MetaMorpho vaults are ERC4626 and are **not** covered here: the `META_MORPHO_0001…0010` market IDs are served by
the generic [`erc4626`](../erc4626/) fuses.

## Market Structure

Four IPOR Fusion markets exist for Morpho, each with its own fuse deployments:

| Market ID | Constant                      | Fuses                                                                                                                   | Substrates                              |
| --------- | ----------------------------- | ----------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| 14        | `MORPHO`                      | `MorphoSupplyFuse`, `MorphoBorrowFuse`, `MorphoCollateralFuse`, `MorphoSupplyWithCallBackDataFuse`, `MorphoBalanceFuse` | Morpho market ids (`bytes32`)           |
| 19        | `MORPHO_FLASH_LOAN`           | `MorphoFlashLoanFuse`, `ZeroBalanceFuse`                                                                                | token addresses                         |
| 41        | `MORPHO_LIQUIDITY_IN_MARKETS` | `MorphoSupplyFuse` (deployed with id 41), `MorphoOnlyLiquidityBalanceFuse`                                              | Morpho market ids (`bytes32`)           |
| 22        | `MORPHO_REWARDS`              | `rewards_fuses/morpho/MorphoClaimFuse`                                                                                  | `UniversalRewardsDistributor` addresses |

Market 14 and market 41 use the same `MorphoSupplyFuse` source; what differs is the balance fuse. Market 14 nets
collateral and debt, market 41 values supplied liquidity only and must not be combined with borrowing on the same
Morpho ids.

## Architecture

### Key Components

| Contract                                                                   | Operation                                            | Data struct                                                                                                                                                                                              |
| -------------------------------------------------------------------------- | ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`MorphoSupplyFuse`](MorphoSupplyFuse.sol)                                 | `enter` supply, `exit` withdraw                      | `MorphoSupplyFuseEnterData{morphoMarketId, amount}` / `MorphoSupplyFuseExitData{morphoMarketId, amount}`                                                                                                 |
| [`MorphoBorrowFuse`](MorphoBorrowFuse.sol)                                 | `enter` borrow, `exit` repay                         | `MorphoBorrowFuseEnterData{morphoMarketId, amountToBorrow, sharesToBorrow}` / `MorphoBorrowFuseExitData{morphoMarketId, amountToRepay, sharesToRepay}`                                                   |
| [`MorphoCollateralFuse`](MorphoCollateralFuse.sol)                         | `enter` supplyCollateral, `exit` withdrawCollateral  | `MorphoCollateralFuseEnterData{morphoMarketId, collateralAmount}` / `MorphoCollateralFuseExitData{morphoMarketId, collateralAmount}`                                                                     |
| [`MorphoSupplyWithCallBackDataFuse`](MorphoSupplyWithCallBackDataFuse.sol) | `enter` supply with callback, `exit` withdraw        | `MorphoSupplyFuseEnterData{morphoMarketId, maxTokenAmount, callbackFuseActionsData}` / `MorphoSupplyFuseExitData{morphoMarketId, amount}` (same struct names as the plain supply fuse, different layout) |
| [`MorphoFlashLoanFuse`](MorphoFlashLoanFuse.sol)                           | `enter` flash loan (no `exit`)                       | `MorphoFlashLoanFuseEnterData{token, tokenAmount, callbackFuseActionsData}`                                                                                                                              |
| [`MorphoBalanceFuse`](MorphoBalanceFuse.sol)                               | `balanceOf`                                          | –                                                                                                                                                                                                        |
| [`MorphoOnlyLiquidityBalanceFuse`](MorphoOnlyLiquidityBalanceFuse.sol)     | `balanceOf`                                          | –                                                                                                                                                                                                        |
| [`MorphoClaimFuse`](../../rewards_fuses/morpho/MorphoClaimFuse.sol)        | `claim(distributor, rewardsToken, claimable, proof)` | plain parameters                                                                                                                                                                                         |

Field semantics:

- `morphoMarketId` — the Morpho `Id` (bytes32). Must be granted as a substrate of the fuse's `MARKET_ID`.
- Amounts are in the token's smallest unit. `sharesToBorrow` / `sharesToRepay` are Morpho share units; Morpho
  requires exactly one of the amount/shares pair to be non-zero.
- `MorphoSupplyFuse.enter` approves exactly `amount` and supplies with `shares = 0`. `exit` accrues interest first;
  an `amount` at least equal to the vault's whole position withdraws **by shares**, which clears the position
  including dust. Zero amounts are no-ops.
- `MorphoCollateralFuse.enter` caps the amount at the vault's collateral token balance; `exit` withdraws the exact
  amount and reverts inside Morpho if the position would become unhealthy.
- `MorphoBorrowFuse.exit` approves the loan token to Morpho for `type(uint256).max` during the call and resets the
  approval to 0 afterwards.
- `callbackFuseActionsData` is an abi-encoded `FuseAction[]` executed inside the Morpho callback
  (`onMorphoSupply` / `onMorphoFlashLoan`) through the vault's callback handler
  (`CallbackHandlerLib`; the registry deploys it as `CallbackHandlerMorpho`). The handler must be registered on the
  vault for the Morpho singleton and the callback selector, otherwise the callback reverts.
- Morpho flash loans carry no fee; the full `tokenAmount` must be back on the vault when the callback returns. The
  handler approves it to Morpho and the fuse resets the approval to 0.

All action fuses also expose `enterTransient` / `exitTransient` that read the same fields from
`TransientStorageLib` inputs.

### Instant withdrawals

`MorphoSupplyFuse` and `MorphoSupplyWithCallBackDataFuse` implement `IFuseInstantWithdraw.instantWithdraw` with
`params[0] = amount`, `params[1] = morphoMarketId`; failures are caught and emitted as `MorphoSupplyFuseExitFailed`.

## Balance Calculation

- **`MorphoBalanceFuse` (market 14)** — for every granted Morpho id: collateral (read from Morpho storage with
  `extSloads`) valued in the collateral token, plus `expectedSupplyAssets − expectedBorrowAssets` in the loan token,
  signed. The sum over markets is converted with `IporMath.convertToWad(amount * price, tokenDecimals + priceDecimals)`
  and clamped to `uint256`; a net-negative total reverts.
- **`MorphoOnlyLiquidityBalanceFuse` (market 41)** — `expectedSupplyAssets` of the loan token only; ids with
  `loanToken == address(0)` are skipped.
- **Market 19** — `ZeroBalanceFuse`: a flash loan leaves no position. `IporFusionMarkets.sol` notes that this market
  needs a dependency-graph link to `ERC20_VAULT_BALANCE` so idle token balances are refreshed after the loan.
- **Market 22** — no balance fuse; claimed rewards go to the `RewardsClaimManager` and vest into the vault.

Prices come from `PlasmaVaultLib.getPriceOracleMiddleware()` (`getAssetPrice`), result in USD normalized to WAD.

## Substrate Configuration

| Market | Shape               | Granted with                                                                | Checked with                                     |
| ------ | ------------------- | --------------------------------------------------------------------------- | ------------------------------------------------ |
| 14, 41 | `bytes32` Morpho id | `PlasmaVaultGovernance.grantMarketSubstrates(marketId, bytes32[] ids)`      | `PlasmaVaultConfigLib.isMarketSubstrateGranted`  |
| 19, 22 | address             | `grantMarketSubstrates` with `PlasmaVaultConfigLib.addressToBytes32(token)` | `PlasmaVaultConfigLib.isSubstrateAsAssetGranted` |

Market 14/41 substrates are raw Morpho ids, not addresses. Market 19 substrates are the tokens that may be
flash-borrowed; market 22 substrates are the `UniversalRewardsDistributor` contracts the claim fuse may call.

## Price Oracle Setup

Every loan token and every collateral token of a granted Morpho id must have a price source in the vault's
`PriceOracleMiddleware` (or its manager), otherwise `balanceOf` reverts. For collateral tokens priced only inside a
Morpho market, `CollateralTokenOnMorphoMarketPriceFeed` under `contracts/price_oracle/price_feed/` derives a price
from the market's own oracle.

## Roles

- `ALPHA_ROLE` (200) executes the action fuses through `PlasmaVault.execute`.
- `FUSE_MANAGER_ROLE` (300) registers fuses and balance fuses and grants substrates.
- `ATOMIST_ROLE` (100) sets market limits.
- `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE` (1200) adds price sources.
- `CLAIM_REWARDS_ROLE` (600) calls `RewardsClaimManager.claimRewards` for `MorphoClaimFuse`; the fuse is registered
  there by `FUSE_MANAGER_ROLE` through `addRewardFuses`.

## Tests

- `test/fuses/morpho/MorphoSupplyFuseTest.t.sol`, `MorphoCreditMarketTest.t.sol` — market 14, Ethereum fork.
- `test/fuses/morpho/MorphoFlashLoanFuseTest.t.sol` — market 19, Ethereum fork.
- `test/fuses/morpho/MorphoLiquidityInMarketsTest.t.sol` — market 41, Ethereum fork.
- `test/fuses/morpho/MorphoClaimFuseTest.t.sol` — market 22, Base fork.
- `test/looping/ethereum/LoopingBorrowSupply*FlashLoanMorpho.t.sol`, `test/looping/base/…` — borrow/collateral/flash
  loan loops.

All of them fork (`vm.createSelectFork` with `ETHEREUM_PROVIDER_URL` / `BASE_PROVIDER_URL`).

## Security Notes

- The deployed `BalanceFuseMorpho` on Ethereum (`0x0aD1776B…`, ipor-abi registry) is an older version than this
  source: it reverts on `VERSION()`. See `catalog/fuses.json`, entry `ethereum-morpho-market-14`.
- `MorphoSupplyWithCallBackDataFuse` reuses the struct names `MorphoSupplyFuseEnterData` / `MorphoSupplyFuseExitData`
  of `MorphoSupplyFuse` with a different enter layout (`maxTokenAmount`, `callbackFuseActionsData`); encode against
  the fuse you call. No registry deployment of this fuse was found on Ethereum.
- Callback data is executed inside a Morpho callback with the vault's storage; the callback handler must be
  configured for the exact Morpho address the fuses were deployed with.
- Market 14 valuation reverts when debt exceeds supply plus collateral in USD terms (net-negative position).
