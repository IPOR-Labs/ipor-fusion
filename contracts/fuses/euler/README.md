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
14. [Security notes](#security-notes)

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

### Stateless fuses

All fuses are stateless (no storage variables) and run via `delegatecall` from
`PlasmaVault.execute(FuseAction[])`, so inside a fuse `address(this) == PlasmaVault`.
Reentrancy protection is inherited from `PlasmaVault.execute`.

### Transient-storage variants

Every fuse exposes both a typed entrypoint (`enter`/`exit` taking a struct) and a
`enterTransient`/`exitTransient` variant that reads its parameters from transient storage
(used by the batched-execution path). This document shows the typed entrypoints; the transient
ones take identical parameters.

---

## Fuse catalogue

| Fuse | Purpose | `enter` | `exit` |
|------|---------|---------|--------|
| `EulerV2SupplyFuse` | Deposit / withdraw collateral in an eVault | deposit assets → shares | withdraw assets (also `instantWithdraw`) |
| `EulerV2BorrowFuse` | Borrow / repay against a sub-account | borrow assets | repay assets |
| `EulerV2CollateralFuse` | Enable / disable an eVault as collateral | `enableCollateral` | `disableCollateral` |
| `EulerV2ControllerFuse` | Enable / disable a borrow controller | `enableController` | `disableController` |
| `EulerV2BatchFuse` | Atomic multi-op batch via `EVC.batch` | validated batch | reverts (`UnsupportedOperation`) |
| `EulerV2BalanceFuse` | NAV: net `collateral − debt` in USD (WAD) | — (balance fuse) | — |
| `EulerV2SwapDeployFuse` | Deploy / decommission an EulerSwap LP pool | deploy pool | remove operator auth |
| `EulerV2SwapReconfigureFuse` | Update a pool's curve / fee params | reconfigure | reverts (`UnsupportedOperation`) |
| `EulerV2SwapRegistryFuse` | Register / unregister a pool in the public registry | register (zero bond) | unregister |

Constructor parameters (all immutable):

| Fuse | Constructor args |
|------|------------------|
| Supply / Borrow / Collateral / Controller / Batch / Balance | `(uint256 marketId, address evc)` |
| `EulerV2SwapDeployFuse` / `EulerV2SwapReconfigureFuse` | `(uint256 marketId, address evc, address eulerV2SwapFactory)` |
| `EulerV2SwapRegistryFuse` | `(uint256 marketId, address evc, address eulerV2SwapRegistry)` |

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
    address eulerVault;   // the Euler eVault (ERC-4626)
    bool    isCollateral; // may be enabled as collateral
    bool    canBorrow;    // may be borrowed from
    bytes1  subAccounts;  // sub-account id this rule applies to
}
```

Capability checks performed by the fuses:

| Helper | True when the granted substrate has… |
|--------|--------------------------------------|
| `canSupply`   | matching `(vault, subAccount)` |
| `canCollateral` | matching `(vault, subAccount)` **and** `isCollateral` |
| `canBorrow`   | matching `(vault, subAccount)` **and** `canBorrow` |
| `canInstantWithdraw` | matching `(vault, subAccount)` **and** `!isCollateral && !canBorrow` |

> Note: a `(vault, subAccount)` pair that is collateral or borrowable is **not** instant-withdrawable
> — instant withdrawal is only allowed for "plain" supply substrates that are neither used as
> collateral nor borrowed against, since withdrawing collateral could leave a position unhealthy.

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

---

## EulerV2SupplyFuse

Deposits the vault's underlying asset into an Euler eVault (ERC-4626 `deposit`) under a
sub-account, and withdraws it back. Implements `IFuseInstantWithdraw`.

```solidity
struct EulerV2SupplyFuseEnterData { address eulerVault; uint256 maxAmount;  bytes1 subAccount; }
struct EulerV2SupplyFuseExitData  { address eulerVault; uint256 maxAmount;  bytes1 subAccount; }
```

- `enter` returns **minted shares** (ERC-4626 semantics); deposits `min(maxAmount, vault balance)`.
- `exit` returns **withdrawn assets**; withdraws `min(maxAmount, sub-account's redeemable assets)`.
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
when the substrate is **neither collateral nor borrowable** (`canInstantWithdraw`), and it
**catches** failures (emits `EulerV2SupplyFuseExitFailed` and returns 0 instead of reverting).

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
struct EulerV2BorrowFuseEnterData { address eulerVault; uint256 assetAmount;    bytes1 subAccount; }
struct EulerV2BorrowFuseExitData  { address eulerVault; uint256 maxAssetAmount; bytes1 subAccount; }
```

- `enter` borrows `assetAmount` (routed via `EVC.call(... onBehalfOf = subAccount)`); requires `canBorrow`.
- `exit` repays up to `maxAssetAmount` (`forceApprove(max)` → `repay` → `forceApprove(0)`); requires `canBorrow`.
- Both return `(eulerVault, amount, subAccount)`. Zero amount is a no-op that still emits the event.

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
struct EulerV2CollateralFuseEnterData { address eulerVault; bytes1 subAccount; }
struct EulerV2CollateralFuseExitData  { address eulerVault; bytes1 subAccount; }
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
struct EulerV2ControllerFuseEnterData { address eulerVault; bytes1 subAccount; }
struct EulerV2ControllerFuseExitData  { address eulerVault; bytes1 subAccount; }
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
    address targetContract;    // an eVault, the EVC, or the PlasmaVault (callback)
    bytes1  onBehalfOfAccount; // sub-account id
    bytes   data;              // ABI-encoded call
}
struct EulerV2BatchFuseData {
    EulerV2BatchItem[] batchItems;
    address[] assetsForApprovals;       // tokens to approve before the batch…
    address[] eulerVaultsForApprovals;  // …to these vaults (cleared to 0 afterwards)
}
```

Supported per-item selectors (everything else reverts `UnsupportedOperation`):

| Target | Allowed selectors | Validation |
|--------|-------------------|------------|
| eVault | `deposit`, `withdraw`, `borrow`, `repay`, `repayWithShares`, `disableController` | `canSupply`/`canBorrow` + sub-account match |
| EVC | `enableController` | `canCollateral` + account match |
| PlasmaVault | `onEulerFlashLoan` (callback only) | — |

> Flash loans **cannot be initiated** through this fuse (only the callback selector is whitelisted).
> `exit()` always reverts — batches are one-shot atomic operations.

```solidity
EulerV2BatchItem[] memory items = new EulerV2BatchItem[](2);
items[0] = EulerV2BatchItem({
    targetContract: EVAULT_WETH,
    onBehalfOfAccount: bytes1(0x01),
    data: abi.encodeWithSelector(IBorrowing.borrow.selector, 2e18, subAccountAddr)
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

---

## EulerV2BalanceFuse

Read-only balance fuse (`IMarketBalanceFuse`). For each substrate it computes
`collateral − debt` in USD and returns the total **net** balance normalized to WAD (18 dec).

- Collateral = sub-account eVault shares → assets → USD via the price oracle middleware.
- Debt = `IBorrowing.debtOf(subAccount)` → USD.
- Reverts `UnsupportedQuoteCurrencyFromOracle` if the oracle returns a 0 price for an asset.

This fuse is what makes EulerSwap LP positions visible to NAV: because the LP pool's
supply/borrow vaults are validated against the **same** `EULER_V2` substrates, every position
the pool can open is counted here. Register it as the balance fuse for `EULER_V2`:

```solidity
MarketBalanceFuseConfig({marketId: IporFusionMarkets.EULER_V2, fuse: address(eulerBalanceFuse)});
```

After any position change, refresh balances:

```solidity
uint256[] memory marketIds = new uint256[](1);
marketIds[0] = IporFusionMarkets.EULER_V2;
PlasmaVault(plasmaVault).updateMarketsBalances(marketIds);
```

---

## EulerV2SwapDeployFuse

Deploys an **EulerSwap v2 LP pool** owned by a vault sub-account, and decommissions it.
EulerSwap pools are Uniswap-v4 hooks; the LP account is the sub-account, and the pool acts as
the EVC account operator.

```solidity
struct EulerV2SwapDeployFuseEnterData {
    IEulerV2Swap.StaticParams  staticParams;  // vaults, eulerAccount, feeRecipient (immutable)
    IEulerV2Swap.DynamicParams dynamicParams; // curve / fee config
    IEulerV2Swap.InitialState  initialState;  // initial virtual reserves
    bytes32 salt;          // CREATE2 salt (mined off-chain, see below)
    address predictedPool; // address alpha expects (anti-substitution guard)
    bytes1  subAccount;
}
struct EulerV2SwapDeployFuseExitData { address pool; bytes1 subAccount; }
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
5. `FACTORY.computePoolAddress(staticParams, salt) == predictedPool` (anti-substitution).
6. `EVC.setAccountOperator(eulerAccount, predictedPool, true)` (direct call — the vault is the EVC owner).
7. `FACTORY.deployPool(...)` routed through `EVC.call` on behalf of `eulerAccount`
   (the factory is `EVCUtil` and requires `_msgSender() == eulerAccount`).
8. Asserts the deployed address equals `predictedPool`.

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
    expiration: 0,               // 0 = no expiry
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
    bytes1  subAccount;
    IEulerV2Swap.DynamicParams dynamicParams;
    IEulerV2Swap.InitialState  initialState;
}
```

`enter` validation mirrors the deploy fuse:

1. `FACTORY.deployedPools(pool)` — the pool must be a genuine factory deployment.
2. `pool.getStaticParams().eulerAccount == vault XOR subAccount`.
3. The pool's `supplyVault0/1` (and non-zero `borrowVault0/1`) are still granted substrates.
4. Same dynamic-param bounds (fee, expiration, **no swap hook**).
5. `IEulerV2Swap.reconfigure(dynamicParams, initialState)` routed through `EVC.call`.

`exit()` reverts (`UnsupportedOperation`) — decommission via `EulerV2SwapDeployFuse.exit`.

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
struct EulerV2SwapRegistryFuseEnterData { address pool; bytes1 subAccount; }
struct EulerV2SwapRegistryFuseExitData  { address pool; bytes1 subAccount; }
```

- `enter` checks `pool.getStaticParams().eulerAccount == vault XOR subAccount`, then routes
  `registerPool(pool)` through `EVC.call` with **zero `msg.value`** — the PlasmaVault can't
  source or receive native ETH, so registration is **always zero-bond**. (Registration is
  rejected by the registry if a non-zero `minimumValidityBond` is ever configured.)
- `exit` checks a pool is registered for the sub-account (`poolByEulerAccount != 0`), then
  `unregisterPool()` via `EVC.call`.

```solidity
actions[0] = FuseAction({
    fuse: eulerV2SwapRegistryFuse,
    data: abi.encodeWithSignature(
        "enter((address,bytes1))",
        EulerV2SwapRegistryFuseEnterData({pool: pool, subAccount: bytes1(0x01)})
    )
});
```

---

## End-to-end example: deploy an LP pool

A full, ordered flow inside a single `PlasmaVault.execute` (called by the alpha), assuming the
`EULER_V2` substrates have already been granted by the atomist and the vault holds both assets:

```solidity
// 0. (off-chain) mine salt + predictedPool for the static params (hook-flag constraint).

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

Later, to wind down: unregister (`RegistryFuse.exit`) → decommission
(`DeployFuse.exit`, removes operator auth) → repay any debt (`BorrowFuse.exit`) → withdraw
collateral (`SupplyFuse.exit`).

> A reference Base-mainnet fork test exercising this whole lifecycle lives at
> `test/fuses/euler/EulerV2SwapForkTest.t.sol` (includes real addresses, salt mining, swaps
> through the periphery, JIT borrow, reconfigure and NAV-safety regression).

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
- **Exit is always permitted.** Supply/Borrow/Collateral exits do not re-check substrates, so a
  position can always be unwound even after its substrate was revoked.
- **Approvals are scoped.** Supply/Borrow/Batch use `forceApprove(vault, amount)` then reset to
  `0` after the call.
- **Stateless + delegatecall.** Fuses hold no storage; reentrancy protection comes from
  `PlasmaVault.execute`.
- **Zero-bond registration.** The Registry fuse always registers with `msg.value == 0`; the
  vault cannot post or be refunded a native-ETH validity bond.

---

## Related

- `EulerFuseLib.sol` — substrate packing + sub-account derivation + capability checks.
- `ext/IEulerV2Swap.sol`, `ext/IEulerV2SwapFactory.sol`, `ext/IEulerV2SwapRegistry.sol`, `ext/IBorrowing.sol`
  — minimal external interfaces (transcribed from `euler-xyz/euler-swap` tag `eulerswap-2.0`).
- [`rewards_fuses/euler/RewardEulerTokenClaimFuse`](../../rewards_fuses/euler/README.md) — rEUL → EUL reward claiming.
