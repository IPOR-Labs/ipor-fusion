> where: `contracts/fuses/napier`
> what: Napier fuse overview mirroring Enso README structure
> why: Provide TODO #10 documentation for future Napier market operations

# Napier Integration

## Overview

Napier V2 is a permissionless yield-stripping protocol that mints Principal Tokens (PT) and Yield Tokens (YT) from yield-bearing vault deposits. PT represent discounted principal claims that redeem 1:1 for the underlying at or after maturity (fixed-rate exposure comes from buying PT below par). YT accrue the floating yield stream and any configured rewards. IPOR Fusion interacts with Napier through its universal router and the Uniswap V4-based TokiHook pools described in the official Napier documentation.

**What Napier does:**

-   Permissionless market deployment via a factory plus curator-owned AccessManager.
-   ERC4626-compatible vault support through VaultConnector commands.
-   PT/YT secondary liquidity powered by Uniswap V4 hooks, including paused swaps after expiry and optional rehypothecation.

## Market Structure

-   **Market ID:** `IporFusionMarkets.NAPIER`
-   **Substrates:** One market ID covers every Napier fuse. PT contracts expose `underlying()` (yield-bearing shares) and `i_asset()` (vault asset) to determine the valid token set.
-   **Lifecycle:** PT issuance, liquidity deposits, and swaps are restricted to pre-expiry, PT redemption is restricted to post-maturity, combine/collect flows are always available.

## Terminology

-   **Asset:** Base token that denominates vault value (e.g., USDC inside an ERC4626 vault).
-   **Underlying token / YBT:** Yield-bearing vault share token accepted by `principalToken.supply` and returned by `principalToken.underlying()`.
-   **Principal Token (PT):** Discounted claim that redeems for underlying token after maturity; issuance pauses post-expiry.
-   **Yield Token (YT):** Tracks floating yield/reward accrual tied to PT issuance.
-   **VaultConnector:** Router module that converts between asset and underlying tokens for ERC4626-compatible vaults.
-   **TokiHook pool:** Uniswap V4 hook pool that prices PT against the underlying with Pendle-style math and pauses swaps automatically after expiry.
-   **PoolKey:** A unique data structure that identifies a Uniswap V4 pool. TokiPool instances use constant fee and tick spacing since concentrated liquidity is not used.

### PoolKey Structure

Each TokiHook pool is identified by a `PoolKey`:

```solidity
PoolKey memory key = PoolKey({
    currency0: underlyingTokenAddress, // Underlying token (YBT)
    currency1: principalTokenAddress,  // PT
    fee: 0,
    tickSpacing: 1,
    hooks: hook
});
```

## Architecture

### Napier Architecture

```
PlasmaVault
├── Napier*Fuse contracts (supply/redeem/combine/collect/swap)
│   └── NapierUniversalRouterFuse (MARKET_ID + router helper)
├── Napier Universal Router
│   ├── VaultConnector (ERC4626 asset↔share conversions)
│   ├── PT/YT modules (supply/issue/redeem/combine commands)
│   └── TokiHook pools (Uniswap V4 hooks managing PT↔underlying swaps)
└── PrincipalToken + YieldToken pair (curator-owned market)
```

1. **Explicit substrates:** Every fuse checks `PlasmaVaultConfigLib.isSubstrateAsAssetGranted` for PT, YT, tokens, and pools before execution.
2. **Lifecycle restrictions:** actions like PT issuance, liquidity deposit, and swaps could be paused by the market curator. Fuses expect callers to gate actions accordingly.

### Key Components

-   **`NapierUniversalRouterFuse`:** Immutable `VERSION`, `MARKET_ID`, and router reference, plus `_getPoolKey` for `ITokiPoolToken`.
-   **`NapierSupplyFuse`:** Issues PT+YT via underlying or vault asset, chaining `VAULT_CONNECTOR_DEPOSIT` + `PT_SUPPLY` when needed.
-   **`NapierRedeemFuse`:** Post-expiry PT redemption for underlying or vault asset using `PT_REDEEM` and optional `VAULT_CONNECTOR_REDEEM`.
-   **`NapierCombineFuse`:** Burns equal PT and YT balances before/after expiry to exit into the underlying or vault asset, enforcing a minimum tokenOut amount.
-   **`NapierCollectFuse`:** Calls `IPrincipalToken.collect` to realize accrued yield and reward tokens.
-   **`NapierDepositFuse`:** Adds/removes liquidity proportionally using both currency0 (underlying) and currency1 (PT) tokens.
-   **`NapierZapDepositFuse`:** Zaps single-sided liquidity using only currency0 (underlying) tokens, automatically splitting and keeping YT. Maturity-aware exit logic uses swap (pre-maturity) or redeem (post-maturity).
-   **`NapierSwapPtFuse`:** Executes Uniswap V4 swaps between underlying and PT via TokiHook pools with `SWAP_EXACT_IN_SINGLE` + slippage-enforced `TAKE_ALL`.
-   **`NapierSwapYtFuse`:** Trades YT ↔ underlying using Napier router commands and Permit2 approvals.

### Substrate Configuration

-   Tokens specified by fuse parameters must be validated against the market substrates.

Substrate checks revert with:

-   `NapierFuseIInvalidToken` for missing PT/YT or input/output tokens.
-   `NapierFuseIInvalidMarketId` for missing pool substrates in swap fuses.

## Router & Pool Lifecycle

### Universal Router Flow

1. **Asset intake:** Vault pre-transfers tokens (or approves Permit2) so the router can operate on contract balances.
2. **Command stream:** Router executes a byte-packed program—VaultConnector calls, PT/YT commands, or V4 swap actions.
3. **Settlement:** Tokens flow back to the fuse where balance differences are measured and events emitted.
4. **Cleanup:** Permit2 approvals reset and min-out checks enforce vault-defined slippage.

### PT/YT Phases

-   **Pre-expiry:** `supply`, `issue`, `unite`, `combine`, and `collect` available. PT supply only works here.
-   **Post-expiry (pre-settlement):** First interaction settles the market and charges pre-settlement performance fees.
-   **Post-settlement:** Issuance locked. `redeem`, `withdraw`, `combine`, and `collect` remain active; TokiHook pools prevent new swaps automatically.

Vault automation should track `principalToken.maturity()` and settlement status before scheduling fuse calls.

## Balance & Yield Tracking

-   **Yield accrual:** YT balances accrue yield via Napier’s snapshot indices. `collect()` transfers the yield-bearing token to the receiver and resets the accrued amount.
-   **Reward handling:** Optional reward proxies credit ERC20 rewards. `NapierCollectFuse` validates reward tokens as substrates and emits the returned array for accounting.
-   **PT valuation:** PT redeem 1:1 for underlying post-maturity. Fixed-rate exposure stems from purchasing PT at a discount, not from embedded interest.
-   **YT exposure:** YT holds the floating yield stream and can be monetized via swaps or by combining with PT for redemption.

## Operations

### NapierSupplyFuse – Issue PT/YT

1. Validate PT and tokenIn substrates.
2. Encode `PT_SUPPLY` plus optional `VAULT_CONNECTOR_DEPOSIT`.
3. Transfer `amountIn` to the router, run `execute`, measure PT delta.
4. Revert if minted principals are below `minPrincipalsAmount`.
5. Emit `NapierSupplyFuseEnter`.

### NapierRedeemFuse – Redeem PT post-maturity

1. Validate PT and tokenOut.
2. Encode `PT_REDEEM` (and `VAULT_CONNECTOR_REDEEM` if needed).
3. Transfer PT to router, execute, compute tokenOut delta.
4. Revert if `amountOut` is below `minTokenOutAmount`.
5. Emit `NapierRedeemFuseEnter`.

### NapierCombineFuse – Burn PT+YT

1. Ensure PT, YT, and tokenOut are granted.
2. Transfer equal PT/YT to router, run `PT_COMBINE`, optionally unwrap to asset.
3. Revert if `amountOut` is below `minTokenOutAmount`.
4. Emit `NapierCombineFuseEnter` with returned amount.

### NapierCollectFuse – Harvest yield + rewards

1. Validate PT.
2. Call `principalToken.collect(address(this), address(this))`.
3. Post-validate each returned reward token is an approved substrate; revert otherwise.
4. Emit `NapierCollectFuseEnter` with collected yield and reward list.

### NapierDepositFuse – Proportional liquidity deposit/withdrawal

**Enter (Add Liquidity):**

1. Validate pool, currency0 (underlying), and currency1 (PT).
2. Encode `TP_ADD_LIQUIDITY` command.
3. Transfer both currency0 and currency1 to router in proportional amounts, execute, measure liquidity delta.
4. Emit `NapierDepositFuseEnter` with liquidity minted.

**Exit (Remove Liquidity):**

1. Validate pool, currency0 (underlying), and currency1 (PT).
2. Encode `TP_REMOVE_LIQUIDITY` command.
3. Transfer pool tokens to router, execute, receive proportional currency0 and currency1 back.
4. Emit `NapierDepositFuseExit` with liquidity burned.

### NapierZapDepositFuse – Single-sided liquidity operations

**Enter (Zap In):**

1. Validate pool, yield token (YT), and currency0 (underlying). The pool grant check is performed before calling into the pool, so passing a non-contract/unknown pool address reverts with `NapierFuseIInvalidMarketId`.
2. Encode 2-command sequence:
    - `TP_SPLIT_UNDERLYING_TOKEN_LIQUIDITY_KEEP_YT`: Split currency0 into PT, keep YT in vault.
    - `TP_ADD_LIQUIDITY`: Add minted PT + remaining currency0 as liquidity.
3. Transfer currency0 to router, execute, measure liquidity and YT deltas (YT stay with the vault).
4. Emit `NapierZapDepositFuseEnter` with liquidity and YT minted.

**Exit (Zap Out):**

1. Validate pool and currency0.
2. Check PT maturity to determine path:

    **Post-maturity path** (3 commands):

    - `TP_REMOVE_LIQUIDITY`: Remove liquidity, receive PT + currency0.
    - `PT_REDEEM`: Redeem PT 1:1 for currency0 (no swap, no slippage).
    - `SWEEP`: Sweep all currency0 to vault with min-out check.

    **Pre-maturity path** (3 commands):

    - `TP_REMOVE_LIQUIDITY`: Remove liquidity, receive PT + currency0.
    - `V4_SWAP`: Swap PT to currency0 via Uniswap V4 (`SWAP_EXACT_IN_SINGLE` → `SETTLE` → `TAKE`).
    - `SWEEP`: Sweep all currency0 to vault with min-out check.

3. Transfer pool tokens to router, execute, measure liquidity and currency0 deltas.
4. Emit `NapierZapDepositFuseExit` with liquidity burned and underlyings received.

**Note:** Zap operations are gas-efficient single-transaction alternatives to multi-step supply+deposit flows, and automatically handle PT/YT minting while keeping YT in the vault.

### NapierSwapPtFuse – Uniswap V4 PT swaps

1. Validate pool + currencies.
2. Revert if `amountIn` is zero.
3. Build V4 action bundle (`SWAP_EXACT_IN_SINGLE`, `SETTLE`, `TAKE_ALL`), passing `minimumAmount` to TAKE_ALL.
4. Transfer tokenIn to router, execute, verify output, emit swap event.

### NapierSwapYtFuse – YT swaps via universal router

1. Validate pool, underlying, and YT.
2. Revert if `amountIn` is zero.
3. Encode `YT_SWAP_UNDERLYING_FOR_YT` or `YT_SWAP_YT_FOR_UNDERLYING` with approximation + min-out params (default binary search config applies when `eps` is zero).
4. Force-approve Permit2 for the token before execution, run the router call, then reset the Permit2 approval; emit swap event.
