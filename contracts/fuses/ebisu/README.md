# Ebisu Integration

## Overview

Ebisu integration allows IPOR Fusion to interact with the Ebisu Zapper contracts. This allows users to open leveraged troves on Liquity and to manage them via levering them up or down (increase/decrease debt and collateral) and by adjusting their annual interest rate.

**What Ebisu does:**
Ebisu is a wrapper on top of Liquity which allows to automatically open leveraged troves. A trove on Liquity is conceptually an overcollateralized loan where the user gets ebUSD, a stablecoin, against posting a collateral. The leverage is implemented in Ebisu's "Zapper" smart contract, which executes flash loans on Balancer. The flash loan gets collateral tokens which are used to mint more ebUSD, which are then swapped into a dex to re-obtain the collateral token to repay the flash loan. The same mechanism is used to perform leveraging down/up, where both the trove debt and collateral are respectively decreased/increased.
The functions leverageUp / leverageDown control the trove's debt and collateral by executing flashloans and swapping on external markets. In order to directly control the debt and collateral using the vault's funds, a separate fuse EbisuAdjustTroveFuse.sol is needed, to perform the BorrowerOperation's action "adjustTrove".

Troves can be closed either "to raw ETH", where the user pays directly the ebUSD debt with a transfer, or "from collateral", where the ebUSD is obtained by requesting a collateral flash loan and swapping it. In the latter case, the flash loan is repaid, if possible, by unlocking the collateral in the trove. This means that the latter case cannot be performed if the collateral price dropped too much.

Since Troves can be controlled by LeverageUp, LeverageDown, and AdjustTrove, there's no point in having more than one Trove open at any time for any given Zapper. This is enforced at FuseStorageLib level, in which the mapping is simply zapper => id.

The annual interest rate of an open Trove can be modified by the Trove owner during the life of the Trove. In our case, the Trove owner is the Plasma Vault, therefore a Fuse to adjust the interest rate is required. This is implemented in EbisuAdjustedInterestRateFuse.sol.

## Market Structure

The integration uses a single market for all operations:

-   **Market ID 39** (`EBISU`) - openLeveragedTroveWithRawETH/closeTroveFromCollateral/closeTroveToRawETH/leverUpTrove/leverDownTrove/adjustTroveInterestRate operations

## Architecture

### Troves and Stability Pool

**Liquity** has two main components: troves and the stability pool.

-   The **Troves** are ERC721 which mint the native "BOLD" token (in Ebisu's case, this token is ebUSD) in exchange of a deposit of some collateral (WETH, sUSDe, WBTC...)
-   The **Stability Pool** gathers the collateral of the Troves and BOLD (ebUSD) tokens deposited by LPs. This is responsible for the stability of BOLD price: every time a liquidation occurs, a quantity of BOLD corresponding to the liquidated trove is burnt from the stability pool and the collateral is handed over to the stability pool's LPs.

**Ebisu** is a wrapper on top of Liquity where you can open troves with automatic leverage, thanks to the "Zapper" contract which executes flash loans done on Balancer.

### Key Components

-   **`EbisuZapperCreateFuse`**: Opens and closes a Leveraged Trove using Ebisu's Zapper contract.
-   **`EbisuZapperLeverModifyFuse`**: Handles levering up and down of open Troves.
-   **`EbisuAdjustInterestRateFuse`**: Adjusts the annual interest rate of an open Trove.
-   **`EbisuAdjustTroveFuse`**: Adjusts the debt and collateral of an open Trove using the Vault's funds.
-   **`EbisuClaimCollateralFuse`**: Claims the collateral surplus that a liquidation credited to the Vault.

## Balance Calculation

The balance corresponding to an open Trove is

```
collateral * collTokenPrice - debt * ebUSDPrice
```

This ensures that the `totalAssets()` quantity is an invariant (approximate, modulo slippage due to swaps following flash loans and fees) for all the Fuse's operations. This balance is floored with zero in case the debt exceeds the collateral; however, this situation is unlikely, since Liquity liquidates such Troves much before this happens.

### Liquidation

When a Trove is liquidated, Liquity burns the Trove NFT and marks the Trove `closedByLiquidation`, so the zapper can no longer close it. `EbisuZapperCreateFuse` checks the Trove status in the Liquity `TroveManager` before relying on its stored Trove id: `enter` and `exit` drop a stored id whose Trove is no longer `active` or `zombie` and emit `EbisuZapperCreateFuseStaleTroveCleared`. The branch is therefore unblocked automatically (a new `enter` can open a fresh Trove; `exit` on a liquidated Trove only clears the id and moves no ebUSD).

### Collateral surplus after liquidation

A liquidation can leave a collateral surplus to the Trove owner, i.e. the Plasma Vault. Liquity v2 credits it to the vault in the branch's `CollSurplusPool`, from where only the owner can take it with `BorrowerOperations.claimCollateral()`.

-   **Valuation:** `EbisuZapperBalanceFuse.balanceOf()` adds, for every `REGISTRY` substrate, `CollSurplusPool.getCollateral(vault)` valued with the collateral token price (same oracle path as the Trove collateral). NAV is therefore not understated between the liquidation and the claim. The collateral price is only requested when there is a surplus.
-   **Claim:** `EbisuClaimCollateralFuse.enter({registry})` resolves `BorrowerOperations` from the granted `REGISTRY` substrate and calls `claimCollateral()` in the vault context (the vault is `msg.sender`). It emits `EbisuClaimCollateralFuseEnter(registry, collToken, amount)` with the balance delta. Liquity reverts (`CollSurplusPool: No collateral available to claim`) when there is nothing to claim; the fuse does not swallow that. There is no `exit`.
-   **After the claim** the pool balance is 0 and the collateral token sits in the vault. To keep it in NAV the collateral token must be a granted substrate of the ERC20 balance market (`ERC20_VAULT_BALANCE`), and the Ebisu market must list that market in its dependency balance graph so that both are refreshed together.
-   **Price requirement (every `REGISTRY` branch):** the collateral token of every granted `REGISTRY` branch needs an oracle price. Anyone can open a Trove naming the vault as owner (`openTrove(_owner, ...)`) and get it liquidated, which gifts a surplus to the vault on any granted branch (it costs them more than the gift). If that collateral has no price, every refresh of market 39 reverts until the surplus is claimed: `updateMarketsBalances`, every `execute` with an Ebisu fuse and, through `UpdateBalancesPreHook` (it refreshes all markets), every hooked deposit/mint/withdraw/redeem/execute. Recovery: ALPHA runs `EbisuClaimCollateralFuse` once. This does not work when `UpdateBalancesPreHook` guards `execute` or when the collateral is an unpriced `ERC20_VAULT_BALANCE` substrate; then add a price source for the collateral first (or the PRE_HOOKS_MANAGER removes the hook from `execute`).
-   **No new substrate type:** the existing `REGISTRY` substrate is enough; the claim fuse needs no `ZAPPER` substrate.

### Important Notes

The debt of the Trove is automatically updated by Liquity smart contract during its life, in order to account for the interest fees paid. Therefore, the `balanceOf()` of the Fuse is automatically updated as well.

## Substrate Configuration

### 1. EBISU Market (Market ID: 39) - openLeveragedTroveWithRawETH/closeTroveFromCollateral/closeTroveToRawETH/leverUpTrove/leverDownTrove/adjustTrove operations

Substrates are configured as a pair `(type, address)` where "type" can be `UNDEFINED, ZAPPER, REGISTRY`. This is necessary because we need data from the stability pool during the validation of `enter`, and the pool's address is not exposed by the Zapper. `REGISTRY` substrates are also read by `EbisuZapperBalanceFuse.balanceOf()` (collateral surplus valuation) and by `EbisuClaimCollateralFuse`.

Grant every `ZAPPER` together with the `REGISTRY` of the same branch (see the table). `EbisuZapperCreateFuse` checks the two grants independently, so a Trove can be opened on a branch whose `REGISTRY` is not granted. After a liquidation its collateral surplus is then neither valued nor claimable until that `REGISTRY` is granted (NAV understated by the surplus). Do not revoke a branch's `REGISTRY` while a Trove or a surplus exists on it.

#### Zappers and Registries examples on Ethereum Mainnet:

| Branch Name  | Leverage Zapper Address                      | Registry Address                             | Collateral Asset |
| ------------ | -------------------------------------------- | -------------------------------------------- | ---------------- |
| weETH Branch | `0x54965fd4dacbc5ab969c2f52e866c1a37ad66923` | `0x329a7baa50bb43a6149af8c9cf781876b6fd7b3a` | weETH            |
| sUSDe Branch | `0x10C14374104f9FC2dAE4b38F945ff8a52f48151d` | `0x411ed8575a1e3822bbc763dc578dd9bfaf526c1f` | sUSDe            |
| WBTC Branch  | `0x175a17755ea596875CB3c996D007072C3f761F6B` | `0x0cac6a40ee0d35851fd6d9710c5180f30b494350` | WBTC             |
| LBTC Branch  | `0xe32e9ab36558e5341a4c05fd635db4ba1f3f51cf` | `0x7f034988af49248d3d5bd81a2ce76ed4a3006243` | LBTC             |
| stcUSD Branch| `0x6a883bfa534754E3B31AA810d6E546F9D0Be2f20` | `0x0C774f22e4b782167EF9635d9ecfBA61dd4e94Ea` | stcUSD           |

## Price Oracle Setup

### Required Price Feeds

The integration requires price feeds for all collateral tokens and the ebUSD token. Price feed configuration via `Price Oracle Middleware Manager` or `Price Oracle Middleware`

## Deployment Notes

Before swapping the new `EbisuZapperBalanceFuse` into live vaults, check the Ebisu market substrate lists: `balanceOf()` now calls every `REGISTRY` substrate, so a wrong registry address breaks NAV, and a duplicated registry counts its surplus twice (a duplicated `ZAPPER` substrate has the same duplicate problem).

Mandatory check before the swap: every `REGISTRY` collateral token of the Ebisu market has a price in the vault's price oracle, and if it is also a substrate of the `ERC20_VAULT_BALANCE` market (m7) it is priced there too. Otherwise a gifted collateral surplus can block the refresh of market 39 (see "Price requirement" above).

Grant every `ZAPPER` together with the `REGISTRY` of the same branch (see the table). `EbisuZapperCreateFuse` checks the two grants independently, so a Trove can be opened on a branch whose `REGISTRY` is not granted. After a liquidation its collateral surplus is then neither valued nor claimable until that `REGISTRY` is granted (NAV understated by the surplus). Do not revoke a branch's `REGISTRY` while a Trove or a surplus exists on it.
