# Euler V2 & EulerSwap Fuses

Fuses in `contracts/fuses/euler/` integrate IPOR Fusion PlasmaVaults with the **Euler V2**
lending protocol (supply / borrow / collateral) and with **EulerSwap v2** automated LP pools
(deploy / reconfigure / register). All of them operate under a single market —
`IporFusionMarkets.EULER_V2` (`marketId == 11`) — and share one substrate model and one
sub-account scheme.

> Reward claiming (`rEUL` → `EUL`) lives in a separate fuse,
> [`contracts/rewards_fuses/euler/RewardEulerTokenClaimFuse`](../../rewards_fuses/euler/README.md),
> and is not covered here.

---

## Table of contents

1. [Core concepts](#core-concepts)
2. [Fuse catalogue](#fuse-catalogue)
3. [Substrate configuration](#substrate-configuration)
4. [EulerV2SupplyFuse](#eulerv2supplyfuse)
5. [EulerV2BorrowFuse](#eulerv2borrowfuse)
6. [EulerV2CollateralFuse](#eulerv2collateralfuse)
7. [EulerV2ControllerFuse](#eulerv2controllerfuse)
8. [EulerV2BatchFuse](#eulerv2batchfuse)
9. [EulerV2BalanceFuse](#eulerv2balancefuse)
10. [EulerV2SwapDeployFuse](#eulerswapdeployfuse)
11. [EulerV2SwapReconfigureFuse](#eulerswapreconfigurefuse)
12. [EulerV2SwapRegistryFuse](#eulerswapregistryfuse)
13. [End-to-end example: LP a pool](#end-to-end-example-deploy-an-lp-pool)
14. [Live EulerSwap pools and user-triggered refreshes](#live-eulerswap-pools-and-user-triggered-refreshes)
15. [Security notes](#security-notes)

---

## Core concepts

### The EVC and `EVC.call` routing

Euler V2 and EulerSwap contracts are gated by the **Ethereum Vault Connector (EVC)** and are
`EVCUtil` contracts. They authorize the caller by resolving `_msgSender()` through the EVC,
**not** by `msg.sender`. Every state-changing fuse call that operates on behalf of a
sub-account is therefore routed through `EVC.call(target, onBehalfOfAccount, value, data)`.

A direct call would resolve `_msgSender()` to the PlasmaVault address (≠ the sub-account for
any non-zero sub-account id) and revert `Unauthorized`. This is the single most important
gotcha when working with these fuses.

### Sub-accounts

Euler/EVC accounts that share the same upper 19 bytes are owned by the same EVC owner. Fusion
exploits this: a PlasmaVault sub-account address is derived by XOR-ing the low byte of the
vault address with a 1-byte sub-account id.

```solidity
// EulerFuseLib.generateSubAccountAddress
subAccount = address(uint160(plasmaVault) ^ uint160(uint8(subAccountId)));
```

- `subAccount == 0x00` → the PlasmaVault itself.
- `subAccount == 0x01..0xFF` → up to 255 distinct isolated positions, all owned by the vault.

Each EulerSwap LP position should get its **own dedicated sub-account** so its collateral and
debt are isolated from other strategies.

### Markets & substrates

Every fuse reads its allow-list from the `EULER_V2` market substrates. A substrate is an
`EulerSubstrate` packed into a `bytes32` (see [Substrate configuration](#substrate-configuration)).
The substrate encodes, per `(eulerVault, subAccount)` pair, whether it may be used as
**collateral** and whether it may be **borrowed** from. A vault/sub-account that is not granted
is rejected by `enter()`.

**Borrowing an asset other than the vault's underlying.** The Euler market only holds the
collateral shares and the debt; a borrowed token lands in the PlasmaVault's own balance. When
that token is not the vault's underlying, NAV needs two more pieces of configuration, otherwise
the debt is subtracted while the token it financed is not counted:

- the borrowed token is granted as a substrate of the `ERC20_VAULT_BALANCE` market
  (`IporFusionMarkets.ERC20_VAULT_BALANCE`, market 7), so that its vault balance is priced into NAV;
- a dependency edge `EULER_V2` (11) → `ERC20_VAULT_BALANCE` (7), set with
  `PlasmaVaultGovernance.updateDependencyBalanceGraphs`, so that every refresh of market 11
  refreshes market 7 in the same step.

This applies to every path that moves such a token or refreshes the markets: borrowing,
withdrawing, and instant withdraw. The fork tests wire the edge the same way. A borrow of the
underlying needs neither, because the underlying is part of `totalAssets()` directly.

**Exits work on any pair.** `EulerV2SupplyFuse.exit` and `EulerV2CollateralFuse.exit` do not check the
substrate list, so ALPHA can withdraw eVault shares from any `(eulerVault, subAccount)` pair of the
vault, whether or not it is granted. When another market of the same PlasmaVault also holds shares of the
same eVault (for example an ERC-4626 market with that eVault as a substrate), an exit through market 11
changes that market's balance too. Set a dependency edge `EULER_V2` (11) → that market with
`PlasmaVaultGovernance.updateDependencyBalanceGraphs`, so that every refresh of market 11 refreshes the
other market in the same step.

### Stateless fuses

All fuses are stateless (no storage variables) and run via `delegatecall` from
`PlasmaVault.execute(FuseAction[])`, so inside a fuse `address(this) == PlasmaVault`.
Reentrancy protection is inherited from `PlasmaVault.execute`.

### Transient-storage variants

Every fuse exposes both a typed entrypoint (`enter`/`exit` taking a struct) and a
`enterTransient`/`exitTransient` variant that reads its parameters from transient storage
(used by the batched-execution path). This document shows the typed entrypoints; the transient
ones take the same parameters, but the input words are laid out differently per fuse group, and
the sub-account byte is the part that is easy to get wrong:

| Group                                                                                                              | Transient inputs                                                                                 | Where the sub-account id sits                                                                   |
| ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| Simple fuses: `EulerV2SupplyFuse`, `EulerV2BorrowFuse`, `EulerV2CollateralFuse`, `EulerV2ControllerFuse`           | one word per field, in struct order (`eulerVault` as an address word, the amount as a `uint256`) | the **lowest** byte of the word (`uint8` of the `uint256`), e.g. `0x…01` for sub-account `0x01` |
| Struct fuses: `EulerV2BatchFuse`, `EulerV2SwapDeployFuse`, `EulerV2SwapReconfigureFuse`, `EulerV2SwapRegistryFuse` | the ABI encoding of the whole `…EnterData` / `…ExitData` struct, split into 32-byte words        | inside the ABI encoding, `bytes1` is **left-aligned** in its word (`0x01 00…00`)                |
| `instantWithdraw(bytes32[])`                                                                                       | `params[0]` amount, `params[1]` eVault, `params[2]` sub-account                                  | the **highest** byte (`bytes32(bytes1(0x01))`)                                                  |

Passing a left-aligned sub-account word to a simple fuse selects sub-account `0x00` (the lowest
byte is zero). `enter` then reverts unless `(vault, 0x00)` is granted, and the Borrow and Controller
exits check the entry too; only the exits without a substrate check (Supply, Collateral) act on
`0x00` silently. Check the layout of the group you call.

---

## Fuse catalogue

| Fuse                         | Purpose                                                                                                | `enter`                 | `exit`                                                     |
| ---------------------------- | ------------------------------------------------------------------------------------------------------ | ----------------------- | ---------------------------------------------------------- |
| `EulerV2SupplyFuse`          | Deposit / withdraw collateral in an eVault                                                             | deposit assets → shares | withdraw assets (also `instantWithdraw`)                   |
| `EulerV2BorrowFuse`          | Borrow / repay against a sub-account                                                                   | borrow assets           | repay assets                                               |
| `EulerV2CollateralFuse`      | Enable / disable an eVault as collateral                                                               | `enableCollateral`      | `disableCollateral`                                        |
| `EulerV2ControllerFuse`      | Enable / disable a borrow controller                                                                   | `enableController`      | `disableController`                                        |
| `EulerV2BatchFuse`           | Atomic multi-op batch via `EVC.batch`                                                                  | validated batch         | reverts (`EulerV2BatchFuseUnsupportedOperation`)           |
| `EulerV2BalanceFuse`         | NAV: sum over sub-accounts of what each keeps once its debt is settled, never below zero, in USD (WAD) | — (balance fuse)        | —                                                          |
| `EulerV2SwapDeployFuse`      | Deploy / decommission an EulerSwap LP pool                                                             | deploy pool             | remove operator auth                                       |
| `EulerV2SwapReconfigureFuse` | Update a pool's curve / fee params                                                                     | reconfigure             | reverts (`EulerV2SwapReconfigureFuseUnsupportedOperation`) |
| `EulerV2SwapRegistryFuse`    | Register / unregister a pool in the public registry                                                    | register (zero bond)    | unregister                                                 |

Constructor parameters (all immutable):

| Fuse                                                        | Constructor args                                                                         |
| ----------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Supply / Borrow / Collateral / Controller / Batch / Balance | `(uint256 marketId, address evc)`                                                        |
| `EulerV2SwapDeployFuse` / `EulerV2SwapReconfigureFuse`      | `(uint256 marketId, address evc, address eulerV2SwapFactory, uint256 priceDeviationWad)` |
| `EulerV2SwapRegistryFuse`                                   | `(uint256 marketId, address evc, address eulerV2SwapRegistry)`                           |

> **`address(0)` validation is not uniform.** Only `EulerV2SupplyFuse`, `EulerV2BorrowFuse`,
> `EulerV2BalanceFuse` and all three EulerSwap fuses revert `Errors.WrongAddress()` on a zero
> EVC (and the EulerSwap fuses also on a zero factory/registry). `EulerV2CollateralFuse`,
> `EulerV2ControllerFuse` and `EulerV2BatchFuse` perform **no** zero-address check in their
> constructors — pass a valid EVC at deploy time.

---

## Substrate configuration

`EulerSubstrate` (in `EulerFuseLib.sol`):

```solidity
struct EulerSubstrate {
    address eulerVault; // the Euler eVault (ERC-4626)
    bool isCollateral; // may be enabled as collateral
    bool canBorrow; // may be borrowed from
    bytes1 subAccounts; // sub-account id this rule applies to
}
```

Capability checks performed by the fuses:

| Helper               | True when the granted substrate has…                                                                            |
| -------------------- | --------------------------------------------------------------------------------------------------------------- |
| `canSupply`          | matching `(vault, subAccount)`                                                                                  |
| `canCollateral`      | matching `(vault, subAccount)` **and** `isCollateral`                                                           |
| `canBorrow`          | matching `(vault, subAccount)` **and** `canBorrow`                                                              |
| `canInstantWithdraw` | at least one matching `(vault, subAccount)` entry, and **no** matching entry with `isCollateral` or `canBorrow` |

> Note: a `(vault, subAccount)` pair that is collateral or borrowable is **not** instant-withdrawable
> — instant withdrawal is only allowed for "plain" supply substrates that are neither used as
> collateral nor borrowed against, since withdrawing collateral could leave a position unhealthy.
>
> Every matching entry is inspected, not only the first one. If the list contains the same pair twice
> (for example a pair re-granted with a flag), a single flagged entry disables the instant withdraw for
> that pair, whatever the order. Re-granting a pair without flags does **not** change what the EVC
> already knows: collateral enabled earlier through a flagged entry stays enabled in the EVC, and the
> instant withdraw skips such a position (see [Instant withdraw](#instant-withdraw)). Disable the
> collateral with `EulerV2CollateralFuse.exit` before relying on instant withdraw for that pair.

### Granting substrates (atomist / governance)

```solidity
bytes32[] memory substrates = new bytes32[](2);

// cbETH eVault: usable as collateral and borrowable on sub-account 0x01
substrates[0] = EulerFuseLib.substrateToBytes32(
    EulerSubstrate({
        eulerVault:   EVAULT_CBETH,
        isCollateral: true,
        canBorrow:    true,
        subAccounts:  bytes1(0x01)
    })
);
substrates[1] = EulerFuseLib.substrateToBytes32(
    EulerSubstrate({
        eulerVault:   EVAULT_WETH,
        isCollateral: true,
        canBorrow:    true,
        subAccounts:  bytes1(0x01)
    })
);

PlasmaVaultGovernance(plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);
```

Bit layout of the packed `bytes32` (from `substrateToBytes32`):

```
[ 160-bit eulerVault ][ isCollateral ][ canBorrow ][ subAccounts ][ padding ]
   shifted << 96          << 88           << 80         << 72
```

### Pool entry (EulerSwap pool on market 11, IL-9706)

Besides eVault rows, market 11 can list a **pool entry**: a pool address and the sub-account it manages. It tells
`EulerV2BalanceFuse` which EulerSwap pools to value by their fair point (see
[Pool entries and the fair point](#pool-entries-and-the-fair-point-il-9706)); it grants nothing else.

```
[ 160-bit pool ][ 0x00 ][ 0x00 ][ subAccount ][ kind ][ 64-bit padding ]
   shifted << 96   << 88   << 80     << 72        << 64
```

- Encode it with `EulerFuseLib.swapPoolSubstrateToBytes32(pool, subAccount)` (`kind = 1`, flag bytes zero).
  `isSwapPoolSubstrate(data)` is true when bit 64 is set; the other bits of the kind byte and the flag bytes are not
  inspected. Existing encoders write zeros in bits 0 to 71, so no live entry is a pool entry.
- `bytes32ToSwapPoolSubstrate(data)` returns `(pool, subAccount)` without checking the kind: call `isSwapPoolSubstrate`
  first. `isSwapPoolGranted(marketId, pool, subAccount)` is true only for a pool entry with exactly that pair (an
  eVault row with the same address does not count).
- A pool entry never grants an eVault, supply, collateral, borrow or instant withdraw: `canSupply`, `canCollateral`,
  `canBorrow`, `canInstantWithdraw` and `isEulerVaultGranted` skip it. `bytes32ToSubstrate` still decodes it as an
  `EulerSubstrate` with `eulerVault = pool`, so a reader of the raw list must test `isSwapPoolSubstrate` first.
- Grant the entry for the pool address predicted off-chain **before** `EulerV2SwapDeployFuse.enter`, together with the
  eVault rows, and keep it in every later `grantMarketSubstrates` call: a grant replaces the whole list, so a grant
  without the entry silently turns the fair-point valuation off for that pool.
- **Compatibility warning.** A vault with a pool entry must use only the Euler fuses of this release. An earlier
  `EulerV2BalanceFuse` reads the entry as an eVault row and reverts every refresh of market 11, and the earlier Euler
  action fuses read it as an eVault row too. Pools without an entry, and vaults with an earlier balance fuse, stay on
  the [IL-9331 rule](#live-eulerswap-pools-and-user-triggered-refreshes); only new deployments get the new valuation.

### Exit requirements

Exits are deliberately more permissive than entries, but not all of them ignore the grant. If
the atomist revokes a `(vault, subAccount)` entry while a position is open, these exits stop
working until an entry for that pair is granted again (its flags can all be `false`):

| Exit                                             | Needs                                                                                                                                                                                       |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `EulerV2SupplyFuse.exit`                         | nothing (no substrate check)                                                                                                                                                                |
| `EulerV2SupplyFuse.instantWithdraw`              | `canInstantWithdraw` (no matching entry that is collateral or borrowable) and the eVault not enabled as collateral of the sub-account in the EVC (otherwise it skips: returns 0, no revert) |
| `EulerV2CollateralFuse.exit`                     | nothing (no substrate check)                                                                                                                                                                |
| `EulerV2BorrowFuse.exit`                         | the granted entry (`canSupply`); **not** `canBorrow`                                                                                                                                        |
| `EulerV2ControllerFuse.exit`                     | the granted entry (`canSupply`), and zero outstanding debt                                                                                                                                  |
| Batch `repay`, `repayWithShares`                 | the granted entry (`canSupply`); **not** `canBorrow`                                                                                                                                        |
| Batch `withdraw`, `deposit`, `disableController` | the granted entry (`canSupply`)                                                                                                                                                             |

Entries that _open_ risk keep their stricter flags: `borrow` and `enableController` (fuse and
batch) need `canBorrow`, and enabling collateral needs `canCollateral`. Unwind (repay, disable
the controller, disable collateral, withdraw) **before** removing an entry.

---

## EulerV2SupplyFuse

Deposits the vault's underlying asset into an Euler eVault (ERC-4626 `deposit`) under a
sub-account, and withdraws it back. Implements `IFuseInstantWithdraw`.

```solidity
struct EulerV2SupplyFuseEnterData {
    address eulerVault;
    uint256 maxAmount;
    bytes1 subAccount;
}
struct EulerV2SupplyFuseExitData {
    address eulerVault;
    uint256 maxAmount;
    bytes1 subAccount;
}
```

- `enter` returns **minted shares** (ERC-4626 semantics); deposits `min(maxAmount, vault balance)`.
- `exit` returns **withdrawn assets**; withdraws `min(maxAmount, convertToAssets(balanceOf(subAccount)))`
  (the smaller of the request and the value of the sub-account's shares). A normal exit is **not**
  capped by the eVault's free cash: when the amount exceeds it, the call reverts with the eVault's
  `E_InsufficientCash` — ALPHA sizes normal exits itself.
  **No substrate validation on exit by design** — an existing position must always be exitable
  even if its substrate was later revoked.
- `enter` requires `canSupply`. A `maxAmount` of 0, or no balance, is a no-op returning 0.

### Example — supply collateral

```solidity
FuseAction[] memory actions = new FuseAction[](1);
actions[0] = FuseAction({
    fuse: eulerSupplyFuse,
    data: abi.encodeWithSignature(
        "enter((address,uint256,bytes1))",
        EulerV2SupplyFuseEnterData({
            eulerVault: EVAULT_WETH,
            maxAmount:  10e18,
            subAccount: bytes1(0x01)
        })
    )
});
PlasmaVault(plasmaVault).execute(actions); // called by ALPHA
```

### Example — withdraw

```solidity
actions[0] = FuseAction({
    fuse: eulerSupplyFuse,
    data: abi.encodeWithSignature(
        "exit((address,uint256,bytes1))",
        EulerV2SupplyFuseExitData({eulerVault: EVAULT_WETH, maxAmount: 5e18, subAccount: bytes1(0x01)})
    )
});
```

### Instant withdraw

`instantWithdraw(bytes32[] params)` is invoked by the vault's withdraw flow. It only succeeds
when no matching substrate entry is **collateral or borrowable** (`canInstantWithdraw`). A pair that
does not satisfy it (not granted, or any matching entry flagged) is **skipped**: the fuse returns 0
without an `EVC.call`, an event or a revert, and the vault's withdraw flow takes the remainder from the
next fuse in the instant-withdraw list. A `PlasmaVault` built before IL-9659 has no try/catch around the instant-withdraw
fuses, so on such a vault a revert here would block every user withdrawal that reaches the entry until the atomist
fixes the configuration (since IL-9659 an entry that reverts with error data is skipped and the loop goes on). The fuse does not police the consequences of a grant: a flagged entry in the
instant-withdraw list silently takes that venue out of the withdrawal path, so keep the substrate
flags and the instant-withdraw list consistent. The call also **catches** failures (emits
`EulerV2SupplyFuseExitFailed` and returns 0 instead of reverting).

When the EVC reports the eVault as enabled collateral of the sub-account (`EVC.isCollateralEnabled`),
the position backs other exposure and the instant path skips it in the same way (returns 0, no
`EVC.call`, event or revert). The normal ALPHA `exit` is unaffected. Fuse builds without this check do not skip: a position whose
substrate was re-granted without flags is withdrawn even though its collateral is still enabled.

The amount is additionally capped to the eVault's `cash()` (the liquid part of the market) after
the position cap. A partial withdrawal is fine: the vault's withdraw flow takes the remainder from
the next fuse in the instant-withdraw list. When `cash()` is 0 no withdraw is attempted — no `EVC.call` to the eVault
and no `EulerV2SupplyFuseExitFailed` event (the fuse still reads `balanceOf`, `convertToAssets` and `cash()`; monitoring of illiquid markets should read
`cash()`). Errors from `EVC.call` are still caught as before.

**Why not `maxWithdraw`?** The fuse does not use `maxWithdraw`: EVK returns 0 for an account with
a controller enabled, and a supply substrate can share its sub-account id with a borrow substrate
or an EulerSwap pool, so `maxWithdraw` would wrongly report nothing to withdraw (the same trap as
IL-8505). The position cap uses `convertToAssets(balanceOf(subAccount))` and the liquidity cap uses
`cash()`.

Param packing:

```solidity
bytes32[] memory params = new bytes32[](3);
params[0] = bytes32(amount);                          // uint256 amount
params[1] = bytes32(uint256(uint160(eulerVault)));    // vault, left-padded
params[2] = bytes32(subAccount);                      // bytes1, right-padded
```

---

## EulerV2BorrowFuse

Borrows the eVault's underlying asset to the PlasmaVault and repays it. The sub-account must
have a controller enabled (see [`EulerV2ControllerFuse`](#eulerv2controllerfuse)) and sufficient
enabled collateral first.

```solidity
struct EulerV2BorrowFuseEnterData {
    address eulerVault;
    uint256 assetAmount;
    bytes1 subAccount;
}
struct EulerV2BorrowFuseExitData {
    address eulerVault;
    uint256 maxAssetAmount;
    bytes1 subAccount;
}
```

- `enter` borrows `assetAmount` (routed via `EVC.call(... onBehalfOf = subAccount)`); requires `canBorrow`.
- `exit` repays up to `maxAssetAmount` (`forceApprove(max)` → `repay` → `forceApprove(0)`); requires the granted
  `(eulerVault, subAccount)` entry only, **not** `canBorrow`, so a position stays repayable after the borrow
  right was revoked. The entry check is never removed, because `exit` approves the eVault for `max`.
  Without the entry it reverts `EulerV2BorrowFuseUnsupportedExitAction(eulerVault, subAccount)`
  (`enter` keeps `EulerV2BorrowFuseUnsupportedEnterAction`). A zero `maxAssetAmount` is a no-op.
- Both return `(eulerVault, amount, subAccount)`. Zero amount is a no-op that still emits the event.
- Borrowing an asset other than the vault's underlying needs a market 7 substrate for that token and the
  `EULER_V2` → `ERC20_VAULT_BALANCE` dependency edge; see [Markets & substrates](#markets--substrates).

```solidity
actions[0] = FuseAction({
    fuse: eulerBorrowFuse,
    data: abi.encodeWithSignature(
        "enter((address,uint256,bytes1))",
        EulerV2BorrowFuseEnterData({eulerVault: EVAULT_WETH, assetAmount: 2e18, subAccount: bytes1(0x01)})
    )
});
```

---

## EulerV2CollateralFuse

Toggles whether an eVault counts as collateral for a sub-account via
`EVC.enableCollateral` / `EVC.disableCollateral`.

```solidity
struct EulerV2CollateralFuseEnterData {
    address eulerVault;
    bytes1 subAccount;
}
struct EulerV2CollateralFuseExitData {
    address eulerVault;
    bytes1 subAccount;
}
```

- `enter` requires `canCollateral` (substrate `isCollateral == true`) and calls `enableCollateral`.
- `exit` calls `disableCollateral` (no substrate check — always possible to drop collateral).

```solidity
actions[0] = FuseAction({
    fuse: eulerCollateralFuse,
    data: abi.encodeWithSignature(
        "enter((address,bytes1))",
        EulerV2CollateralFuseEnterData({eulerVault: EVAULT_CBETH, subAccount: bytes1(0x01)})
    )
});
```

---

## EulerV2ControllerFuse

Enables/disables a **borrow controller** for the sub-account. A controller must be enabled
before the sub-account can borrow from that vault, and it gates the EVC account-health checks.

```solidity
struct EulerV2ControllerFuseEnterData {
    address eulerVault;
    bytes1 subAccount;
}
struct EulerV2ControllerFuseExitData {
    address eulerVault;
    bytes1 subAccount;
}
```

- `enter` requires `canBorrow`, then `EVC.enableController(subAccount, eulerVault)` (direct call).
- `exit` requires `canSupply` (safety check that the vault is configured), then routes
  `disableController()` through `EVC.call` on behalf of the sub-account. Only succeeds when the
  outstanding debt is zero.

```solidity
actions[0] = FuseAction({
    fuse: eulerControllerFuse,
    data: abi.encodeWithSignature(
        "enter((address,bytes1))",
        EulerV2ControllerFuseEnterData({eulerVault: EVAULT_WETH, subAccount: bytes1(0x01)})
    )
});
```

**Typical leverage ordering**: enable collateral → enable controller → borrow.
Unwind in reverse: repay → disable controller → disable collateral.

---

## EulerV2BatchFuse

Executes several Euler V2 operations atomically through `EVC.batch`, with per-item validation.
Useful for leverage loops in a single transaction (supply + enable + borrow, etc.).

```solidity
struct EulerV2BatchItem {
    address targetContract; // an eVault, the EVC, or the PlasmaVault (callback)
    bytes1 onBehalfOfAccount; // sub-account id
    bytes data; // ABI-encoded call
}
struct EulerV2BatchFuseData {
    EulerV2BatchItem[] batchItems;
    address[] assetsForApprovals; // assetsForApprovals[i] must be asset() of eulerVaultsForApprovals[i]
    address[] eulerVaultsForApprovals; // granted eVaults that may pull it (reset to 0 afterwards)
}
```

Supported per-item selectors (everything else reverts `EulerV2BatchFuseUnsupportedOperation`):

| Target      | Allowed selectors                                                                | Validation                                                                                        |
| ----------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| eVault      | `deposit`, `withdraw`, `borrow`, `repay`, `repayWithShares`, `disableController` | per-selector entry check, receiver and EVC roles (see below)                                      |
| EVC         | `enableController`                                                               | `canBorrow` + account match                                                                       |
| PlasmaVault | `onEulerFlashLoan` (callback only)                                               | `CallbackData` is decoded; `(asset, addressToApprove)` must be one of the declared approval pairs |

**EVC roles per selector.** On a non-zero sub-account the EVC `onBehalfOfAccount` of an eVault item
is not always the sub-account. EVK pulls tokens from the account it authenticates (`deposit`,
`repay`), refuses to push tokens to a sub-account (the `borrow` and `withdraw` receiver), and
needs a share allowance to burn the shares of an account other than the caller. The fuse
therefore derives the role from the selector (the item's `onBehalfOfAccount` field is only the
sub-account id used for the checks) and validates the arguments like `EulerV2SupplyFuse` and
`EulerV2BorrowFuse` do. "Sub-account" below is `PlasmaVault XOR id`; for id `0x00` it is the
PlasmaVault itself, so all roles coincide.

| Selector                            | Runs on behalf of             | Required arguments                              | Entry check                 |
| ----------------------------------- | ----------------------------- | ----------------------------------------------- | --------------------------- |
| `deposit(assets, receiver)`         | PlasmaVault (pays the assets) | `receiver` = sub-account                        | `canSupply`                 |
| `withdraw(assets, receiver, owner)` | sub-account                   | `receiver` = PlasmaVault, `owner` = sub-account | `canSupply`                 |
| `borrow(amount, receiver)`          | sub-account                   | `receiver` = PlasmaVault                        | `canBorrow`                 |
| `repay(amount, receiver)`           | PlasmaVault (pays the debt)   | `receiver` (debt holder) = sub-account          | granted entry (`canSupply`) |
| `repayWithShares(amount, receiver)` | sub-account (owns the shares) | `receiver` = sub-account                        | granted entry (`canSupply`) |
| `disableController()`               | sub-account                   | —                                               | `canSupply`                 |

EVC items run with `onBehalfOfAccount = address(0)`; PlasmaVault callback items run on behalf of
the sub-account. Any other combination of arguments reverts `EulerV2BatchFuseInvalidVaultPermissions`.

`enableController(account, eulerVault)` needs the controller vault to be granted with
`canBorrow` for the item's sub-account (as in `EulerV2ControllerFuse.enter`), because a
controller can take control of the sub-account's position and borrow against it; `canCollateral`
is not enough. `account` must be the sub-account. A missing `canBorrow` or a wrong account
reverts `EulerV2BatchFuseInvalidController(account, eulerVault)`.

> The EVK `flashLoan` selector is **not** supported. Flash liquidity is composed inside one `EVC.batch`
> (see [Flash liquidity](#flash-liquidity-and-the-callback-handler)); the only PlasmaVault selector
> allowed is the callback `onEulerFlashLoan`.
> `exit()` always reverts — batches are one-shot atomic operations.

```solidity
EulerV2BatchItem[] memory items = new EulerV2BatchItem[](2);
items[0] = EulerV2BatchItem({
    targetContract: EVAULT_WETH,
    onBehalfOfAccount: bytes1(0x01),
    // borrow(amount, receiver): the borrowed tokens go to the PlasmaVault, not to the sub-account
    data: abi.encodeWithSelector(IBorrowing.borrow.selector, 2e18, plasmaVault)
});
items[1] = EulerV2BatchItem({ /* … another op … */ });

address[] memory assets = new address[](1);  assets[0] = WETH;
address[] memory vaults = new address[](1);  vaults[0] = EVAULT_WETH;

actions[0] = FuseAction({
    fuse: eulerBatchFuse,
    data: abi.encodeWithSignature(
        "enter(((address,bytes1,bytes)[],address[],address[]))",
        EulerV2BatchFuseData({batchItems: items, assetsForApprovals: assets, eulerVaultsForApprovals: vaults})
    )
});
```

### Approvals

Before the batch the fuse approves every pair `(assetsForApprovals[i], eulerVaultsForApprovals[i])`
for `type(uint256).max`, and after `EVC.batch` returns it resets every pair to `0`, so no
allowance outlives the transaction. Every pair is validated first, before any approval or EVC call
(validation only makes `asset()` view calls on granted Euler vaults; this includes `enterTransient`, which calls `enter`):

- `eulerVaultsForApprovals[i]` must be granted in at least one `EULER_V2` substrate of the
  vault (any flags, any sub-account);
- `assetsForApprovals[i]` must be exactly `eulerVaultsForApprovals[i].asset()`.

Otherwise the call reverts `EulerV2BatchFuseInvalidApprovalPair(asset, eulerVault)`. So an
approval can only ever let a granted eVault pull its own underlying token; it cannot name an
arbitrary spender, or an arbitrary token held by the PlasmaVault. The two arrays must have the
same length (`EulerV2BatchFuseArrayLengthMismatch`). The pair list is independent of the batch items: an item may
target any granted eVault, but an item can only spend what the declared pairs allow.

Other batch errors carry the same fuse prefix: an empty `batchItems` reverts
`EulerV2BatchFuseEmptyBatchItems`, an item with a zero `targetContract` reverts
`EulerV2BatchFuseZeroAddress`. A successful batch emits
`EulerV2BatchFuseExecuted(version, batchSize, assets, vaults)`.

### Flash liquidity and the callback handler

Flash liquidity runs as `borrow` → PlasmaVault callback → `repay` inside one `EVC.batch`; the
account health check is deferred to the end of the batch, so the borrow needs no collateral at
the moment it is made. Layout of the items (sub-account `0x00` shown, as in the fork tests):

1. EVC `enableController(subAccount, eVault)`;
2. eVault `borrow(amount, plasmaVault)`;
3. callback item: `targetContract` = the PlasmaVault, `data` = `onEulerFlashLoan(bytes)` with
   `abi.encode(CallbackData{asset, addressToApprove, amountToApprove, actionData})`. The vault
   runs `actionData` (fuse `FuseAction[]`) through `executeInternal`, then
   `forceApprove(asset, addressToApprove, amountToApprove)`;
4. eVault `repay(amount, subAccount)`;
5. eVault `disableController()` (optional clean-up).

The callback payload is **untrusted** — the EVC forwards whatever a batch item or any
`EVC.call` names — so there are two layers, and they ship together:

1. **Batch fuse.** In the callback item `(asset, addressToApprove)` must equal one declared
   approval pair, i.e. an `(asset(), granted eVault)` pair that passed the checks above; otherwise
   `EulerV2BatchFuseInvalidCallbackApproval(asset, spender)`. `amountToApprove` is free because
   the reset after the batch clears the callback approval too. `actionData` is not validated
   here: it runs through `executeInternal`, which only executes the fuses the vault has
   installed. A malformed payload reverts while decoding.
2. **`CallbackHandlerEuler(evc)`** (the handler the vault runs for the callback). It reads the
   authenticated EVC account with `EVC.getCurrentOnBehalfOfAccount(address(0))` and accepts the
   callback only if that account shares the calling PlasmaVault's 19-byte address prefix
   (`account XOR vault < 0x100`: the vault or one of its sub-accounts); otherwise it reverts
   `CallbackHandlerEulerUnauthorizedOrigin(account)`. Outside an EVC call or batch the EVC call
   itself reverts, so the handler fails closed. Items a vault sends to itself in `EVC.batch` run
   as such an account; any other contract must be the owner or an operator of the vault's
   accounts, so a foreign contract that gets control while the vault executes cannot trigger the
   callback by calling `EVC.call(vault, …, onEulerFlashLoan(...))`. As defense in depth the
   handler also reverts `CallbackHandlerEulerUnauthorizedOrigin(account)` when
   `EVC.isOperatorAuthenticated()` or `EVC.isControlCollateralInProgress()` is true: in the
   vault's own batch the vault is caller and target, so the EVC clears the operator flag, and
   `EVC.batch` cannot start during `controlCollateral`; an operator or a controller of a vault
   sub-account therefore cannot trigger the callback either.

The handler layer is needed in addition to the fuse check because the callback can be
triggered from outside the batch fuse, on every vault that registered the handler (for example
one that has only `EulerV2SupplyFuse` installed).

**Deployment and registration.**

- Deploy **one** `CallbackHandlerEuler(evc)` per chain with that chain's EVC (zero address
  reverts `WrongAddress()`); it is stateless and shared by all vaults.
- The atomist registers it **on every vault** that registered the previous handler, including
  vaults that have only `EulerV2SupplyFuse` and no batch fuse (the old handler trusted the
  payload for any EVC caller):

    ```solidity
    PlasmaVaultGovernance(plasmaVault).updateCallbackHandler(newHandler, EVC, 0xc555e119);
    ```

    `0xc555e119` is the selector of `onEulerFlashLoan(bytes)`; the registration key is `(EVC, selector)`.

- Ship the new batch fuse and the new handler together: the handler alone leaves the old fuse
  accepting any callback approval, the fuse alone leaves the old handler reachable.

---

## EulerV2BalanceFuse

Read-only balance fuse (`IMarketBalanceFuse`). It values every EVC sub-account of the vault on its
own, by what the vault keeps once the debt of that sub-account is settled, and returns the **sum over
sub-accounts, never below zero**, normalized to WAD (18 dec) (IL-9528, 3sigma audit finding #1).

- Supply = sub-account eVault shares → assets → USD via the price oracle middleware.
- Debt = `IBorrowing.debtOf(subAccount)` → USD.
- Each (eVault, sub-account) position is counted once, also when it is granted twice with other flags.
  An empty position (no shares, no debt) is not priced.
- Reverts `UnsupportedQuoteCurrencyFromOracle` if the oracle returns a 0 price for the asset of a
  non-empty position.
- **Limited liability per sub-account.** A liquidation seizes only collateral that the sub-account
  enabled on the EVC and that its controller recognizes (an LTV is configured); the debt left
  afterwards is socialized by the controller unless it sets `CFG_DONT_SOCIALIZE_DEBT`. With
  C = seizable collateral, F = every other position of the sub-account (plain supply, collateral the
  controller does not recognize) and D = debt, a sub-account is worth:
    - no debt: `C + F`;
    - the debt can be socialized: `F + max(0, C − D)` (F survives the liquidation);
    - the debt cannot be socialized (`CFG_DONT_SOCIALIZE_DEBT`, or no seizable collateral):
      `max(0, C + F − D)` (the debt stays and locks every position of the sub-account).
      Neither the idle balance of the vault nor its other sub-accounts back that debt, so the shortfall of
      one sub-account is not charged to the others and a negative net value never reverts. When every
      sub-account is healthy the result equals the plain sum of `supply − debt` over all substrates.
- **Socialization charge.** When an underwater sub-account will be socialized, its controller writes
  the residual debt off against its depositors, the vault among them: the vault's shares in that
  controller (any sub-account of the market) are charged `D × shares / totalSupply`, rounded up and
  bounded by the whole debt. The value is never above what the vault keeps after the liquidation, and
  the liquidation steps it up by at most the vault's part of the repaid debt.
- **The vault's own underlying is not counted twice (IL-9707).** Sub-account `0x00` is the Plasma Vault address itself. When the vault's underlying `asset()` is an eVault share `E` and market 11 has a row `(E, 0x00)`, the `E` shares held there are the vault's idle balance, which `totalAssets()` already counts. The position still takes part in the valuation of sub-account `0x00` (seizable collateral, plain supply, debt, socialization charge), and its value is then taken off the result of that sub-account, floored at zero: `max(0, v − value(E on 0x00))`. Unchanged: `E` on sub-accounts `0x01`–`0xFF` counts in full, any other eVault on `0x00` counts in full, and a vault whose underlying is not that eVault share, or a market without a row on `0x00`, gets the same numbers as before. The row granted twice (other flags) is read once and taken off once. The vault's `asset()` is read only for a market with a row on `0x00`. Before IL-9707 the shares were counted again (NAV about doubled, phantom performance fee). Moving an existing vault to this balance fuse is `addBalanceFuse(11, newFuse)` and a refresh of market 11 in one transaction; a vault with this configuration sees a one-time NAV drop, so rehearse it on a fork.
- **Atomist rule: with an eVault-share underlying, do not borrow on sub-account `0x00` (not enforced, fuses do not police grants).** A debt on `0x00` can take more than the rest of that sub-account, that is, part of the idle underlying (the debt itself, or a liquidation that seizes the idle `E`). The market is never negative and cannot show that part, so NAV is overstated by it. Example: idle `E` 1 000, plain supply 100, debt 300 on `0x00` gives market 0, `totalAssets` 1 000 and a real value of 800. Borrow on `0x01` or above instead.
- **Health is monitored off-chain.** The fuse gives no on-chain signal about bad debt. Monitor each
  sub-account with the controller vault's `accountLiquidity` (EVK) and the EVC account status.

This fuse is what makes EulerSwap LP positions visible to NAV: because the LP pool's
supply/borrow vaults are validated against the **same** `EULER_V2` substrates, every position
the pool can open is counted here. Register it as the balance fuse for `EULER_V2`:

```solidity
MarketBalanceFuseConfig({marketId: IporFusionMarkets.EULER_V2, fuse: address(eulerBalanceFuse)});
```

After any position change, the keeper or the alpha refreshes balances (a user operation must not be
able to trigger this refresh in a vault with a live EulerSwap pool, see
[Live EulerSwap pools and user-triggered refreshes](#live-eulerswap-pools-and-user-triggered-refreshes)).
The refresh is a public transaction that can be sandwiched, so submit it privately:

```solidity
uint256[] memory marketIds = new uint256[](1);
marketIds[0] = IporFusionMarkets.EULER_V2;
PlasmaVault(plasmaVault).updateMarketsBalances(marketIds);
```

### Pool entries and the fair point (IL-9706)

A pool entry is set apart from the eVault rows before any call to an eVault: it creates no position and no sub-account
row, so an entry on a sub-account without eVault rows is never read. A sub-account with live pools is worth
`max(0, v − Σd)`, where `v` is the value above (after the IL-9707 rule for `0x00`) and `d` is the displacement of each
live pool on it. The socialization charge is unchanged, and both subtractions floor at zero.

- **`d`.** The oracle value of the pool reserves minus the oracle value of the pool's _fair point_, rounded up and
  never negative. The fair point is the point on the pool curve that EulerSwap accepts with the lowest oracle value; it
  depends only on the curve parameters and the oracle prices, never on the reserves. `d` therefore moves one for one
  with the reserves and cancels against the sub-account holdings: a swap, a donation or a just-in-time borrow that
  moves the holdings and the reserves by the same amounts leaves the value unchanged, except for the LP fee, which
  stays in the value. The computation is in `EulerV2SwapFairPointLib`. The one exception is a pool on sub-account `0x00`
  that trades the vault's own underlying (see the `0x00` bullet below).
- **`d` is not capped by what the pool can deliver.** `d` comes from the virtual reserves and the curve parameters
  alone; nothing caps it by the supply balance, the eVault cash or the borrow capacity of the sub-account. Equilibrium
  reserves far above the holdings make `d` large and the value understated (a cheap entry for a new depositor). Keep the
  equilibrium reserves within the supply plus the just-in-time borrow capacity. `exit` (the operator is removed, so `d`
  becomes 0) and a reconfigure (a new fair point) move the value by `d` at once.
- **Sub-account `0x00` and the vault's underlying.** On `0x00` the pool's `eulerAccount` is the vault itself. If a
  supply vault of the pool is the vault's `asset()` (an eVault share), that leg of the pool is the vault's idle balance,
  which `totalAssets()` reads live and outside market 11. A donation or a swap on that leg then moves NAV at once,
  without a refresh, and after a refresh the IL-9707 subtraction removes the leg from `v` while `d` still counts its
  reserve, so the floor at zero drops the offset. The fair point cannot cancel this: the donation resistance and the
  fee-only claim of this section do not hold for such a pool. `EulerV2SwapDeployFuse.enter` rejects a new pool on `0x00`
  whose `supplyVault0` or `supplyVault1` equals the vault's `asset()` (`EulerV2SwapDeployFuseSubAccountZeroUsesVaultAsset(vault)`); use a sub-account `0x01` to `0xFF`. Borrow vaults
  are not covered by that check: with an eVault-share underlying, do not borrow on `0x00` (atomist rule above). Pools
  deployed earlier are unchanged (no migration): `exit` such a pool.
- **Live pool.** The pool has code, `getStaticParams().eulerAccount` is the entry's sub-account, the pool is an EVC
  operator of that sub-account, and `expiration` is 0 or in the future (the boundary of the deploy fuse). Anything else
  is skipped without a revert and without reading the reserves: an entry granted before the deploy (no code), a foreign pool, a
  pool uninstalled by `EulerV2SwapDeployFuse.exit`, an expired pool. The same pool and sub-account granted several
  times counts once; two pools on one sub-account are summed.
- **Entries must name EulerSwap v2 pools.** An entry names a pool created by the deploy fuse's `FACTORY`. An entry
  without code is skipped, but a contract with code that is not such a pool (a token, a v1 pool, a mistyped address)
  makes `getStaticParams()` revert or fail to decode, and every refresh of market 11 reverts until the entry is
  corrected. `Locked()` also relies on the v2 `getReserves`.
- **Prices.** Both pool assets are priced by the oracle middleware (`getAssets()` order); a zero price reverts with
  `UnsupportedQuoteCurrencyFromOracle`.
- **Mid-swap reads.** `getReserves` reverts `Locked()` inside a swap and the fuse does not catch it, so a refresh of
  market 11 from a swap callback reverts; no mid-swap state can be recorded. Every live pool of a listed sub-account
  is read, also when the sub-account is already at 0.
- **Rows the pool needs.** The pool's supply and borrow eVaults must be granted as rows of the pool sub-account and
  stay granted while the pool is live (`exit` the pool before revoking a row). A missing supply row hides that leg: a
  swap that drains the unseen leg raises `v − d` by that leg, although the level stays below the true value. A missing
  borrow row hides the just-in-time debt: `v` does not see it while `d` moves with the reserves, so the market is
  overstated by the hidden debt (reversible when the debt is repaid). The deploy fuse checks the rows only at deploy;
  a later grant that omits them is a grant risk the fuses do not police.
- **Only new deployments.** A live pool without an entry cannot be found (EVC operators cannot be listed) and is valued
  as before, from the sub-account state; the IL-9331 rule stays for it, and for vaults with an earlier balance fuse.
  A vault with an entry must use only the Euler fuses of this release (see the compatibility warning under
  [Pool entry](#pool-entry-eulerswap-pool-on-market-11-il-9706)).

What this closes: pushing the pool curve with a swap, a donation to the pool sub-account, and a JIT borrow no longer
move the recorded value beyond the fee, and a refresh in the middle of a swap reverts instead of recording the
transient state. This does not cover a pool on `0x00` that trades the vault's idle underlying.

What stays (not solved in code):

- A refresh around a real price move books the pool's pending arbitrage loss at that move: `d` follows the oracle, so
  the value falls when the oracle moves and the pool has not yet been arbitraged.
- A pool that expires drops out of the valuation, so the market value jumps up by `d` at the expiry (a pool without
  `expiration` has no such step).
- The role that configures substrates (`FUSE_MANAGER_ROLE`) can remove the entry with a grant that omits it; the
  valuation then falls back to the sub-account state and the value jumps. This is a grant risk, not enforced by the
  fuses.
- An existing pool on `0x00` that trades the vault's idle underlying keeps the exposure described above (no
  migration): `exit` it.
- On an underwater pool sub-account `v` does not move with the seizable leg, so a swap can change the value. From the
  fair point it cannot raise it; after an oracle move a swap toward the fair point lowers `d` and raises the value by
  that drop. Close such a pool (`EulerV2SwapDeployFuse.exit`, then unwind the positions).
- **Socialization charge of another sub-account.** If another sub-account is underwater with socializable debt in an
  eVault X and the pool sub-account supplies X, a donation raises the vault's shares in X and X's total supply, so the
  charge moves although `v − d` of the pool sub-account cancels. Example: debt 100, shares 100 of 1 000 become 1 100 of
  2 000: the charge goes from 10 to 55 and the market falls by 45, and the charge comes back when the donation is
  reversed. The invariance above holds for the pool sub-account only, not for the market. Operational rule: do not
  run a pool that supplies the controller of an underwater sub-account.

### Non-underlying borrowed assets

The fuse values only the collateral shares and the debt of the `EULER_V2` substrates. A borrowed
token held by the vault is outside this market: it is counted by the `ERC20_VAULT_BALANCE` market
(market 7), which needs that token as a substrate and the dependency edge `EULER_V2` → market 7
(see [Markets & substrates](#markets--substrates)). The edge matters for borrowing, withdrawing and
instant withdraw alike, because each of them refreshes market 11.

### Stale-cache window

Share prices follow the **cached** value of market 11, written by `updateMarketsBalances`, not a live
reading. Between two refreshes, deposits and exits from idle assets are priced at the last recorded
value of market 11. In a vault with a live EulerSwap pool the pool's value moves with its state (fees
earned by the pool, losses to arbitrage), so a position change in that window moves value between
share holders in proportion to share × delta. This is a property of the cache, not of the fuse: the
fuse reads current balances on every call. The mitigation is operational — only the keeper or the
alpha refreshes market 11, privately and at a short interval. The rule and what it forbids are in
[Live EulerSwap pools and user-triggered refreshes](#live-eulerswap-pools-and-user-triggered-refreshes).

---

## EulerV2SwapDeployFuse

Deploys an **EulerSwap v2 LP pool** owned by a vault sub-account, and decommissions it.
EulerSwap pools are Uniswap-v4 hooks; the LP account is the sub-account, and the pool acts as
the EVC account operator.

```solidity
struct EulerV2SwapDeployFuseEnterData {
    IEulerV2Swap.StaticParams staticParams; // vaults, eulerAccount, feeRecipient (immutable)
    IEulerV2Swap.DynamicParams dynamicParams; // curve / fee config
    IEulerV2Swap.InitialState initialState; // initial virtual reserves
    bytes32 salt; // CREATE2 salt (mined off-chain, see below)
    address predictedPool; // address alpha expects (anti-substitution guard)
    bytes1 subAccount;
}
struct EulerV2SwapDeployFuseExitData {
    address pool;
    bytes1 subAccount;
}
```

What `enter` enforces and does:

1. `staticParams.eulerAccount == generateSubAccountAddress(vault, subAccount)`.
2. `staticParams.feeRecipient == address(0)` — fees must compound into the supply vault
   (no external fee siphon).
3. **Dynamic-param sanity bounds**: `fee0 < 1e18`, `fee1 < 1e18`, `expiration` is 0 or in the
   future, and **no swap hook** (`swapHook == 0`, `swapHookedOperations == 0`). A swap hook
   would cede control of vault funds to external code.
4. `supplyVault0/1` must be granted **supply** substrates; any non-zero `borrowVault0/1` must be
   a granted **borrow** substrate (borrow vaults may be `address(0)` for supply-only pools).
   The pool also enables collateral **cross-wise** on activation (`supplyVault0` iff
   `borrowVault1 != 0`, `supplyVault1` iff `borrowVault0 != 0`), bypassing `EulerV2CollateralFuse`;
   so those supply vaults must also be granted with `isCollateral = true`
   (`EulerV2SwapDeployFuseUnsupportedVault` otherwise). Supply-only pools and the unused side of a
   one-sided pool need no collateral flag. Release note: JIT pool configurations must grant the
   cross-side supply vault with `isCollateral = true` (in addition to `canBorrow` on the borrow vaults).
5. **Curve pricing guard** (`EulerV2SwapCurveLib`, shared with `EulerV2SwapReconfigureFuse`):
   `priceX/priceY` (asset1 base units per asset0 base unit, so it embeds `10^(dec1-dec0)`) must be
   within `PRICE_DEVIATION_WAD` of the `PriceOracleMiddleware` ratio of `asset0/asset1`, and
   `initialState` must equal `(equilibriumReserve0, equilibriumReserve1)`. Errors:
   `EulerV2SwapCurvePriceOutOfBounds`, `EulerV2SwapInitialStateNotAtEquilibrium`,
   `EulerV2SwapUnsupportedOraclePrice`. Without this, ALPHA could open a permanent,
   permissionless off-market standing order over vault inventory (see "Curve pricing risk" below).
6. `FACTORY.computePoolAddress(staticParams, salt) == predictedPool` (anti-substitution).
7. `EVC.setAccountOperator(eulerAccount, predictedPool, true)` (direct call — the vault is the EVC owner).
8. `FACTORY.deployPool(...)` routed through `EVC.call` on behalf of `eulerAccount`
   (the factory is `EVCUtil` and requires `_msgSender() == eulerAccount`).
9. Asserts the deployed address equals `predictedPool`.

**Pool entry required (IL-9706).** `enter` also reverts `EulerV2SwapDeployFusePoolNotGranted(pool, subAccount)` unless
market 11 lists a [pool entry](#pool-entry-eulerswap-pool-on-market-11-il-9706) for exactly `(predictedPool, subAccount)`
(an eVault row with the same address does not count). The check runs after the eVault substrate checks and before the
curve pricing guard, the predicted-address check and the operator install, so a missing entry never installs the
operator or deploys. Runbook: first install this release's `EulerV2BalanceFuse` (`addBalanceFuse(11, …)`) and the
Euler fuses of this release, before the pool entry is granted (an earlier balance fuse reverts every refresh of
market 11 once the entry exists, and the deploy's own refresh would revert too; see the compatibility warning under
[Pool entry](#pool-entry-eulerswap-pool-on-market-11-il-9706)); then mine the salt, compute `predictedPool`, grant the
pool entry together with the eVault rows (`grantMarketSubstrates`), then deploy; keep the entry in every later grant. `exit` and
`EulerV2SwapReconfigureFuse` have no such gate, so pools deployed earlier keep working without a migration.

**Sub-account `0x00` with the vault's underlying.** `enter` also reverts `EulerV2SwapDeployFuseSubAccountZeroUsesVaultAsset(vault)`
when `subAccount == 0x00` and `supplyVault0` or `supplyVault1` equals the vault's `asset()`: that leg would be the vault's idle balance, which the fair point cannot
value (see [Pool entries and the fair point](#pool-entries-and-the-fair-point-il-9706)). The rule applies to new
deployments through this fuse; pools deployed earlier are unchanged and should be exited. Borrow vaults are not
checked: with an eVault-share underlying, do not borrow on `0x00`.

> **Curve pricing risk.** `PRICE_DEVIATION_WAD` is chosen by governance per fuse deployment (it is
> a constructor immutable, like `EulerV2SwapDeployFuse`/`EulerV2SwapReconfigureFuse` themselves) and
> must exceed the oracle's expected lag for the pair — a band tighter than the pair's oracle
> deviation threshold makes legitimate deploys/reconfigures revert during volatility.
> `PRICE_DEVIATION_WAD == 1e18` disables the lower bound (any ratio from 0 up to 2x the oracle is
> accepted), effectively "unbounded". Zero fees (`fee0 == fee1 == 0`) stay allowed: once the price is
> pinned to the oracle, the fee is an LP yield policy, not a safety bound. The price band is checked
> only at deploy and at reconfigure, not continuously: between those calls the pool keeps quoting its
> stored curve, so when the market moves outside the band an arbitrageur trades against the stale price
> and the loss is roughly the price move times the deliverable depth. ALPHA must reprice (via
> `EulerV2SwapReconfigureFuse`) or exit (`exit`) when the market leaves the band; the band caps the loss
> only at the moment it was set. Virtual reserves are **not** inventory: with non-zero borrow vaults the
> pool can
> just-in-time borrow up to the eVault LTV, so the deliverable side of a trade (and the loss exposure)
> is bounded by Euler's LTV and the `canBorrow` and `isCollateral` grants, not by the reserve numbers themselves.

`exit` just removes operator authorization (`setAccountOperator(..., false)`); withdrawing the
underlying positions is done with the Supply/Borrow fuses.

### Mining the salt (off-chain)

EulerSwap pools are Uniswap-v4 hooks: the pool **address** must encode the exact hook-permission
bits in its low 14 bits, or deployment reverts `HookAddressNotValid`. So you brute-force a
`salt` whose `computePoolAddress` result has `addr & 0x3FFF == 0x28A8` and isn't already deployed:

```solidity
uint160 constant HOOK_FLAG_MASK     = uint160((1 << 14) - 1);                         // 0x3FFF
uint160 constant HOOK_FLAG_REQUIRED =
    uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 5) | (1 << 3));                  // 0x28A8

for (uint256 i; i < 200000; ++i) {
    salt = bytes32(i);
    predictedPool = IEulerV2SwapFactory(FACTORY).computePoolAddress(staticParams, salt);
    if ((uint160(predictedPool) & HOOK_FLAG_MASK) == HOOK_FLAG_REQUIRED &&
        !IEulerV2SwapFactory(FACTORY).deployedPools(predictedPool)) break;
}
```

### Building params

```solidity
// asset0/asset1 follow token sort order (lower address = asset0).
IEulerV2Swap.StaticParams memory sp = IEulerV2Swap.StaticParams({
    supplyVault0: EVAULT_CBETH,
    supplyVault1: EVAULT_WETH,
    borrowVault0: EVAULT_CBETH,  // or address(0) for supply-only
    borrowVault1: EVAULT_WETH,
    eulerAccount: eulerAccount,  // == vault XOR subAccount
    feeRecipient: address(0)     // MUST be zero
});

IEulerV2Swap.DynamicParams memory dp = IEulerV2Swap.DynamicParams({
    equilibriumReserve0: uint112(5e18),
    equilibriumReserve1: uint112(5e18),
    minReserve0: 0,
    minReserve1: 0,
    priceX: uint80(1.13309e18),  // marginal rate asset0->asset1 = priceX/priceY
    priceY: uint80(1e18),
    concentrationX: uint64(5e17),
    concentrationY: uint64(5e17),
    fee0: uint64(3e15),          // 0.3%
    fee1: uint64(3e15),
    expiration: uint40(block.timestamp + 30 days), // finite end date; 0 (no expiry) is allowed but not recommended
    swapHookedOperations: 0,     // MUST be 0
    swapHook: address(0)         // MUST be zero
});

IEulerV2Swap.InitialState memory st = IEulerV2Swap.InitialState({reserve0: uint112(5e18), reserve1: uint112(5e18)});
```

### Deploy action

```solidity
EulerV2SwapDeployFuseEnterData memory data = EulerV2SwapDeployFuseEnterData({
    staticParams: sp, dynamicParams: dp, initialState: st,
    salt: salt, predictedPool: predictedPool, subAccount: bytes1(0x01)
});
actions[2] = FuseAction({
    fuse: eulerV2SwapDeployFuse,
    data: abi.encodeWithSignature(
        "enter(((address,address,address,address,address,address),(uint112,uint112,uint112,uint112,uint80,uint80,uint64,uint64,uint64,uint64,uint40,uint8,address),(uint112,uint112),bytes32,address,bytes1))",
        data
    )
});
```

> ⚠️ Supply collateral into the pool's supply vaults **in the same `execute`** (Supply fuse
> actions before the deploy action) so the pool is funded atomically.

### Decommission

```solidity
actions[0] = FuseAction({
    fuse: eulerV2SwapDeployFuse,
    data: abi.encodeWithSignature(
        "exit((address,bytes1))",
        EulerV2SwapDeployFuseExitData({pool: pool, subAccount: bytes1(0x01)})
    )
});
```

---

## EulerV2SwapReconfigureFuse

Updates the **mutable** curve / fee parameters and virtual reserves of an existing pool.

```solidity
struct EulerV2SwapReconfigureFuseEnterData {
    address pool;
    bytes1 subAccount;
    IEulerV2Swap.DynamicParams dynamicParams;
    IEulerV2Swap.InitialState initialState;
}
```

`enter` validation mirrors the deploy fuse:

1. `FACTORY.deployedPools(pool)` — the pool must be a genuine factory deployment.
2. `pool.getStaticParams().eulerAccount == vault XOR subAccount`.
3. The pool's `supplyVault0/1` (and non-zero `borrowVault0/1`) are still granted substrates, and the
   supply vaults the pool enables as collateral (cross-wise, see Deploy) still carry `isCollateral = true`
   (`EulerV2SwapReconfigureFuseUnsupportedVault` otherwise).
4. Same dynamic-param bounds (fee, expiration, **no swap hook**) **and the same curve pricing
   guard** (`EulerV2SwapCurveLib.requireCurveAtOraclePrice`, reserves pinned at equilibrium) as
   `EulerV2SwapDeployFuse.enter` — `reconfigure` resets the live reserves and re-prices the curve
   in one call, so an unpinned reconfigure is the same off-market bypass on a position that already
   holds funds.
5. `IEulerV2Swap.reconfigure(dynamicParams, initialState)` routed through `EVC.call`.

`exit()` reverts (`EulerV2SwapReconfigureFuseUnsupportedOperation`) — decommission via `EulerV2SwapDeployFuse.exit`.

```solidity
IEulerV2Swap.DynamicParams memory newDp = /* … e.g. wider band, higher fee … */;
actions[0] = FuseAction({
    fuse: eulerV2SwapReconfigureFuse,
    data: abi.encodeWithSignature(
        "enter((address,bytes1,(uint112,uint112,uint112,uint112,uint80,uint80,uint64,uint64,uint64,uint64,uint40,uint8,address),(uint112,uint112)))",
        EulerV2SwapReconfigureFuseEnterData({
            pool: pool, subAccount: bytes1(0x01),
            dynamicParams: newDp,
            initialState: IEulerV2Swap.InitialState({reserve0: uint112(6e18), reserve1: uint112(6e18)})
        })
    )
});
```

---

## EulerV2SwapRegistryFuse

Registers / unregisters a pool in the **public EulerSwap registry** (separate from the factory
in v2). Registration makes the pool discoverable / routable by the periphery.

```solidity
struct EulerV2SwapRegistryFuseEnterData {
    address pool;
    bytes1 subAccount;
}
struct EulerV2SwapRegistryFuseExitData {
    address pool;
    bytes1 subAccount;
}
```

- `enter` checks `pool.getStaticParams().eulerAccount == vault XOR subAccount`, then routes
  `registerPool(pool)` through `EVC.call` with **zero `msg.value`** — the PlasmaVault can't
  source or receive native ETH, so registration is **always zero-bond**. (Registration is
  rejected by the registry if a non-zero `minimumValidityBond` is ever configured.)
- `exit` reads the pool registered for the sub-account (`poolByEulerAccount`). No pool reverts
  `EulerV2SwapRegistryFuseNotRegistered(eulerAccount)`; a registered pool other than `pool` in the exit data
  reverts `EulerV2SwapRegistryFuseInvalidPool(pool, registeredPool)`. The registry holds one pool per
  sub-account and unregisters whichever it holds, so the check keeps the event and the caller's intent aligned
  with the pool that is actually removed. Then `unregisterPool()` runs via `EVC.call`.

```solidity
actions[0] = FuseAction({
    fuse: eulerV2SwapRegistryFuse,
    data: abi.encodeWithSignature(
        "enter((address,bytes1))",
        EulerV2SwapRegistryFuseEnterData({pool: pool, subAccount: bytes1(0x01)})
    )
});
```

**Teardown order and replacement pools.** The live registry refuses to unregister a pool while it is
still an authorized EVC operator of the sub-account (`OldOperatorStillInstalled()`), so decommission
first (`EulerV2SwapDeployFuse.exit`), then unregister. Replacing a pool is the same trap: registering
the replacement for a sub-account whose old pool is still installed as operator reverts with the same
error. Replace in this order: decommission the old pool → unregister it → deploy the new pool → register
it. This behaviour belongs to the registry, not to the fuse; the fork test pins it for unregistering.

---

## End-to-end example: deploy an LP pool

A full, ordered flow inside a single `PlasmaVault.execute` (called by the alpha), assuming the
`EULER_V2` substrates have already been granted by the atomist and the vault holds both assets:

```solidity
// 0. (off-chain) mine salt + predictedPool for the static params (hook-flag constraint), then grant the pool entry for
//    predictedPool next to the eVault rows (grantMarketSubstrates); the deploy reverts without it.

// 1. Supply both collateral sides on sub-account 0x01.
// 2. Deploy the pool (validates eulerAccount, feeRecipient, no-hook, vaults, predicted address).
FuseAction[] memory actions = new FuseAction[](3);
actions[0] = supplyAction(EVAULT_CBETH, 10e18, 0x01);
actions[1] = supplyAction(EVAULT_WETH,  10e18, 0x01);
actions[2] = deployPoolAction(salt, predictedPool); // EulerV2SwapDeployFuse.enter

vm.prank(ALPHA);
PlasmaVault(plasmaVault).execute(actions);

// 3. (optional) register the pool so the periphery can route swaps to it.
FuseAction[] memory reg = new FuseAction[](1);
reg[0] = registerAction(pool, 0x01); // EulerV2SwapRegistryFuse.enter
vm.prank(ALPHA);
PlasmaVault(plasmaVault).execute(reg);

// 4. Refresh NAV.
uint256[] memory mids = new uint256[](1); mids[0] = IporFusionMarkets.EULER_V2;
PlasmaVault(plasmaVault).updateMarketsBalances(mids);
```

Later, to wind down, in this order: decommission (`DeployFuse.exit`, removes operator auth) →
unregister (`RegistryFuse.exit`; the live registry rejects it while the pool is still an operator) →
repay any debt (`BorrowFuse.exit`) → withdraw collateral (`SupplyFuse.exit`). Keep the
`(vault, subAccount)` entries granted until the positions are closed (see
[Exit requirements](#exit-requirements)).

> A reference Base-mainnet fork test exercising this lifecycle lives at
> `test/fuses/euler/EulerV2SwapForkTest.t.sol` (real addresses, salt mining, swaps through the
> periphery, reconfigure, decommission). The Base fork test
> `EulerV2SwapForkTest.testShouldReflectJitBorrowInNav` forces a real just-in-time cbETH borrow (the pool
> borrows beyond a 1 cbETH deposit), asserts `debtOf(eulerAccount) > 0`, and checks that the market
> balance equals collateral minus debt priced independently; it covers pool-created JIT debt being
> netted in NAV, not other EulerSwap paths.

---

## Live EulerSwap pools and user-triggered refreshes

**Rule.** In a vault that has a live EulerSwap pool on the `EULER_V2` market (a pool deployed by
`EulerV2SwapDeployFuse` and not yet decommissioned), no user operation may be able to lead to a refresh of market 11. "User operation" means every
selector that has a pre-hook and that an account other than the keeper or the alpha can call
(`PlasmaVault._checkCanCall` runs the pre-hook for every `restricted` selector). Examples, not a
closed list: `deposit`, `depositWithPermit`, `mint`, `withdraw`, `redeem`, `redeemFromRequest`,
`transfer`, `transferFrom` (the last two once shares are transferable by users). Only the keeper or
the alpha refreshes it (`updateMarketsBalances`, or `execute`). That refresh is a public transaction
and can be sandwiched (swap before, trade against the refreshed cache after), so submit it privately
(private RPC or bundle) and not at times of user activity.

**Why.** The cached value of market 11 is what share prices follow. With a live pool, that value moves
with the pool's state, and a trader can move the pool state with a swap, so the cached value is not a
stable measure. A user who can cause the refresh decides which pool state gets recorded: shares are then
issued or paid at a value that is not the pool's long-run value, and the difference comes from, or goes
to, the other holders. This was reproduced on a Base fork for both user-triggered paths below, also
for a refresh in the middle of a swap, with and without a performance fee. A refresh can also read a
pool that is mid-swap, in which case EulerSwap itself rejects some reads (`Locked()`). Fusion does not
change the contracts for this: the fix is operational, plus a VaultValidator rule that is being prepared
separately; it must walk `getPreHookSelectors()` (every pre-hooked selector callable by a
non-keeper, non-alpha account) and not a fixed list of selectors.

**What counts as "can lead to a refresh".** The rule is about reachability, not about what is wired
directly:

1. A pre-hook on any user selector that refreshes market 11, that is, any pre-hook that calls
   `updateMarketsBalances`: `UpdateBalancesPreHook` (refreshes every active market),
   `UpdateBalancesIgnoreDustPreHook` (refreshes the markets whose cached balance is `>=` its
   threshold), `HyperCoreCapitalFlowPreHook` (refreshes the HyperCore market, so it matters when that
   market's dependency graph contains market 11), and any other such hook. A cache below the threshold today is **no permanent protection**: the cache of
   market 11 grows and crosses the threshold.
2. The same pre-hooks nested inside `ExchangeRateValidatorPreHook`.
3. An instant withdraw from market 11 (`EulerV2SupplyFuse.instantWithdraw` registered as an
   instant-withdraw fuse), which refreshes the market it pulls from.
4. A refresh, or an instant withdraw, of **another** market whose dependency graph contains market 11.
   The vault expands the graph recursively (`PlasmaVaultMarketsLib`), so the check must look at the
   whole closure, not at the direct edges only.

**What to do.** Do not wire a refreshing pre-hook (or one nested in `ExchangeRateValidatorPreHook`) on
user selectors of such a vault, do not register an instant-withdraw fuse for market 11, and check the
dependency graph of every other market (recursively) for market 11 before enabling a pool or changing
hooks. Do the same check again whenever a pre-hook, an instant-withdraw fuse or a dependency edge is
changed. See also the [stale-cache note](#stale-cache-window).

**Pools with a pool entry (IL-9706).** On a vault whose market 11 lists a pool entry for the pool and whose balance fuse is
from this release, the pool sub-account is valued by the fair point, so a swap, a donation or a JIT borrow no longer
moves the recorded value beyond the LP fee (see [Pool entries and the fair point](#pool-entries-and-the-fair-point-il-9706)).
A pool on `0x00` that trades the vault's own underlying is outside this valuation (its leg is idle, read live outside
market 11); new deployments of it are rejected and an existing one should be exited. The rule above is not relaxed by this: what stays there (a refresh around a real price move, the step at the expiry of
a pool, the removal of the entry, an underwater pool sub-account, the charge of another underwater sub-account) is
still moved by whoever can trigger a refresh. For pools without an entry and for vaults with an earlier balance fuse
the rule applies as written.

**Keeping the refresh of the other markets (IL-9609).** `UpdateBalancesPreHook` refreshes every active
market, so with a live pool it cannot be wired on a user selector, and the vault then gives up refreshing
all markets on user entry points. `UpdateBalancesExcludeMarketsPreHook` fixes that without relaxing the rule:
it refreshes every active market except the ones listed as its substrates. Register it directly on each
user selector (`setPreHookImplementations`) with market 11 (`EULER_V2`) as the only substrate. Limits, which
the NatSpec of the hook repeats:

- It only filters the list the hook itself passes to `updateMarketsBalances`. The vault expands the
  dependency graph of every refreshed market, so a market with an edge to market 11 still refreshes it:
  the reachability rules above (no edge to market 11 from a market that user operations refresh, no instant
  withdraw from market 11) stay in force.
- It cannot be nested in `ExchangeRateValidatorPreHook`: a nested hook receives no substrates, the exclusion
  list would be empty, and every market would be refreshed, market 11 included.
- Market 11 keeps a stale cache until the keeper or the alpha refreshes it (see the
  [stale-cache note](#stale-cache-window)).
- Hook deployment is once per chain and shared; a live vault switches with `setPreHookImplementations`.
- The Hooks V2 port (IL-9490) must keep the same behaviour: an excluded id is never passed to
  `updateMarketsBalances`, and an empty list means all active markets.

---

## Security notes

- **`EVC.call` is mandatory** for any on-behalf-of operation. Euler/EulerSwap are `EVCUtil`
  contracts; a direct call reverts `Unauthorized` for any non-zero sub-account.
- **No external control of vault positions.** Pools must have `feeRecipient == address(0)` and
  **no swap hook** — both are hard-rejected by Deploy/Reconfigure. This prevents ceding control
  of vault-owned funds to external parties.
- **NAV completeness by construction.** Pool supply/borrow vaults are validated against the same
  `EULER_V2` substrates that `EulerV2BalanceFuse` iterates, so a pool whose positions would be
  invisible to NAV cannot be deployed.
- **Anti-substitution.** Deploy verifies `computePoolAddress == predictedPool` and that the
  deployed address matches; Reconfigure/Registry verify `deployedPools` / `getStaticParams`
  ownership before acting.
- **Exits and the substrate grant.** Supply and Collateral exits do not re-check substrates, but
  Borrow exit, Controller exit and batch repay need the granted `(vault, subAccount)` entry (not
  `canBorrow`); the Borrow check stays because `exit` approves the eVault for `max`. See
  [Exit requirements](#exit-requirements): unwind before revoking an entry.
- **Approvals are scoped.** Supply and Borrow use `forceApprove(vault, amount)` then reset to
  `0` after the call. The Batch fuse approves only `(asset(), granted eVault)` pairs, validated
  before any approval or EVC call, and resets every pair to `0` after the batch
  (see [Approvals](#approvals)); a PlasmaVault callback item can only approve one of those
  declared pairs, so the reset clears it as well.
- **Callback origin.** `CallbackHandlerEuler` accepts `onEulerFlashLoan` only when the EVC
  on-behalf-of account is the PlasmaVault or one of its sub-accounts and the EVC context is
  neither operator-authenticated nor `controlCollateral` (see
  [Flash liquidity](#flash-liquidity-and-the-callback-handler)).
- **Stateless + delegatecall.** Fuses hold no storage; reentrancy protection comes from
  `PlasmaVault.execute`.
- **Zero-bond registration.** The Registry fuse always registers with `msg.value == 0`; the
  vault cannot post or be refunded a native-ETH validity bond.
- **Live pool and user-triggered refresh.** With a live EulerSwap pool, no user operation may be able
  to refresh market 11: neither a refreshing pre-hook (also nested in `ExchangeRateValidatorPreHook`,
  also `UpdateBalancesIgnoreDustPreHook` once its threshold is reached), nor an instant withdraw from
  market 11 or from a market that depends on it. See
  [Live EulerSwap pools and user-triggered refreshes](#live-eulerswap-pools-and-user-triggered-refreshes).

---

## Related

- `EulerFuseLib.sol` — substrate packing + sub-account derivation + capability checks.
- `ext/IEulerV2Swap.sol`, `ext/IEulerV2SwapFactory.sol`, `ext/IEulerV2SwapRegistry.sol`, `ext/IBorrowing.sol`
  — minimal external interfaces (transcribed from `euler-xyz/euler-swap` tag `eulerswap-2.0`).
- [`rewards_fuses/euler/RewardEulerTokenClaimFuse`](../../rewards_fuses/euler/README.md) — rEUL → EUL reward claiming.
