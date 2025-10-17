# Ebisu Integration

## Overview

Ebisu integration allows IPOR Fusion to interact with the Ebisu Zapper contracts. This allows users to open leveraged troves on Liquity and to manage them via levering them up or down (increase/decrease debt and collateral)

**What Ebisu does:**
Ebisu is a wrapper on top of Liquity which allows to automatically open leveraged troves. A trove on Liquity is conceptually an overcollateralized loan where the user gets ebUSD, a stablecoin, against posting a collateral. The leverage is implemented in Ebisu's "Zapper" smart contract, which executes flash loans on Balancer. The flash loan gets collateral tokens which are used to mint more ebUSD, which are then swapped into a dex to re-obtain the collateral token to repay the flash loan. The same mechanism is used to perform leveraging down/up, where both the trove debt and collateral are respectively decreased/increased.

Troves can be closed either "to raw ETH", where the user pays directly the ebUSD debt with a transfer, or "from collateral", where the ebUSD is obtained by requesting a collateral flash loan and swapping it. In the latter case, the flash loan is repaid, if possible, by unlocking the collateral in the trove. This means that the latter case cannot be performed if the collateral price dropped too much.

Since Troves can be controlled by LeverageUp and LeverageDown, there's no point in having more than one Trove open at any time for any given Zapper. This is enforced at FuseStorageLib level, in which the mapping is simply zapper => id.

## Market Structure

The integration uses a single market for all operations:

-   **Market ID 37** (`EBISU`) - openLeveragedTroveWithRawETH/closeTroveFromCollateral/closeTroveToRawETH/leverUpTrove/leverDownTrove operations

## Architecture

### Troves and Stability Pool

**Liquity** has two main components: troves and the stability pool.
- The **Troves** are ERC721 which mint the native "BOLD" token (in Ebisu's case, this token is ebUSD) in exchange of a deposit of some collateral (WETH, sUSDe, WBTC...)
- The **Stability Pool** gathers the collateral of the Troves and BOLD (ebUSD) tokens deposited by LPs. This is responsible for the stability of BOLD price: every time a liquidation occurs, a quantity of BOLD corresponding to the liquidated trove is burnt from the stability pool and the collateral is handed over to the stability pool's LPs.

**Ebisu** is a wrapper on top of Liquity where you can open troves with automatic leverage, thanks to the "Zapper" contract which executes flash loans done on Balancer. 

### Key Components

-   **`EbisuZapperCreateFuse`**: Opens and closes a Leveraged Trove using Ebisu's Zapper contract.
-   **`EbisuZapperLeverModifyFuse`**: Handles levering up and down of open Troves.

## Balance Calculation

The balance corresponding to an open Trove is 
```
collateral * collTokenPrice - debt * ebUSDPrice
```
This ensures that the `totalAssets()` quantity is an invariant (approximate, modulo slippage due to swaps following flash loans and fees) for all the Fuse's operations. This balance is floored with zero in case the debt exceeds the collateral; however, this situation is unlikely, since Liquity liquidates such Troves much before this happens.

### Important Notes

The debt of the Trove is automatically updated by Liquity smart contract during its life, in order to account for the interest fees paid. Therefore, the `balanceOf()` of the Fuse is automatically updated as well.

## Substrate Configuration

### 1. EBISU Market (Market ID: 35) - openLeveragedTroveWithRawETH/closeTroveFromCollateral/closeTroveToRawETH/leverUpTrove/leverDownTrove operations

Substrates are configured as a pair `(type, address)` where "type" can be `UNDEFINED, ZAPPER, REGISTRY`. This is necessary because we need data from the stability pool during the validation of `enter`, and the pool's address is not exposed by the Zapper.

#### Zappers and Registries examples on Ethereum Mainnet:

| Branch Name     | Leverage Zapper Address                     | Registry Address                             | Collateral Asset |
| -------------- | -------------------------------------------- | -------------------------------------------- | ---------------- |
| weETH Branch   | `0x54965fd4dacbc5ab969c2f52e866c1a37ad66923` | `0x329a7baa50bb43a6149af8c9cf781876b6fd7b3a` | weETH            |
| sUSDe Branch   | `0x10C14374104f9FC2dAE4b38F945ff8a52f48151d` | `0x411ed8575a1e3822bbc763dc578dd9bfaf526c1f` | sUSDe            |
| WBTC Branch    | `0x175a17755ea596875CB3c996D007072C3f761F6B` | `0x0cac6a40ee0d35851fd6d9710c5180f30b494350` | WBTC             |
| LBTC Branch    | `0xe32e9ab36558e5341a4c05fd635db4ba1f3f51cf` | `0x7f034988af49248d3d5bd81a2ce76ed4a3006243` | LBTC             |

## Price Oracle Setup

### Required Price Feeds

The integration requires price feeds for all collateral tokens and the ebUSD token. Price feed configuration via `Price Oracle Middleware Manager` or `Price Oracle Middleware`
