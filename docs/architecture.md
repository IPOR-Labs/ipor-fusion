# PlasmaVault architecture

This document maps the contracts and call paths implemented in the current checkout. It complements the more detailed
[vault component overview](../contracts/vaults/README.md), but the source files linked here are authoritative whenever
the older overview differs. In particular, the current implementation has no separate `PlasmaVaultErc4626` view
component: ERC-4626 previews and conversions are implemented directly by `PlasmaVault`.

## Mental model

A vault created by [PlasmaVaultFactory](../contracts/factory/PlasmaVaultFactory.sol) is an EIP-1167 clone of a
`PlasmaVault` implementation. The clone address is the persistent identity: it owns the underlying assets, is the
ERC-20 share token, and holds all vault storage. The implementation, base, plugin, pre-hook, fuse, and balance-fuse
addresses provide code that can execute in that same storage context through `delegatecall`.

```text
caller
  │ external call
  ▼
PlasmaVault clone address ───────────── owns assets, shares, and vault storage
  │ delegatecall from the minimal proxy
  ▼
PlasmaVault implementation
  ├─ direct ERC-4626/accounting/execute logic
  ├─ delegatecall ─► PlasmaVaultBase ─► governance and ERC-20/permit code
  ├─ delegatecall ─► optional PlasmaVaultVotesPlugin
  ├─ delegatecall ─► configured pre-hook
  ├─ delegatecall ─► supported action fuse ── external call ─► protocol
  └─ delegatecall ─► balance/withdraw fuse
       │ external calls
       ├─► IporFusionAccessManager
       ├─► PriceOracleMiddleware
       ├─► WithdrawManager
       ├─► FeeManager and fee accounts
       └─► RewardsClaimManager / ContextManager
```

For every delegated path, `address(this)` is the clone and storage reads/writes target the clone. Solidity delegatecall
also preserves the caller, subject to Fusion's explicit context-sender mechanism described below. By contrast, manager,
oracle, token, and protocol calls are normal external calls: those contracts own their own storage, and they see the
vault clone as caller unless a documented intermediate call changes it.

## Components and responsibilities

| Component                                                                          | Runtime responsibility                                                                           | State location                              |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------- |
| [`PlasmaVault`](../contracts/vaults/PlasmaVault.sol)                               | Direct ERC-4626 operations, NAV, fuse execution, callbacks, fallback router, fee realization     | Vault clone                                 |
| [`PlasmaVaultBase`](../contracts/vaults/PlasmaVaultBase.sol)                       | ERC-20/permit updates, supply-cap enforcement, and governance functions reached through fallback | Vault clone through delegatecall            |
| [`PlasmaVaultGovernance`](../contracts/vaults/PlasmaVaultGovernance.sol)           | Fuse, substrate, oracle, limit, callback, pre-hook, and other vault configuration                | Vault clone through the base                |
| [`PlasmaVaultVotesPlugin`](../contracts/vaults/plugins/PlasmaVaultVotesPlugin.sol) | Optional votes selectors and voting-unit updates                                                 | Vault clone through delegatecall            |
| Action fuses under [`contracts/fuses/`](../contracts/fuses/)                       | Protocol-specific enter/exit actions selected by `execute`                                       | Vault clone plus external protocol state    |
| Balance fuses under [`contracts/fuses/`](../contracts/fuses/)                      | Read a market position and return its USD WAD value during balance refresh                       | Vault clone through delegatecall            |
| [`PreHooksHandler`](../contracts/handlers/pre_hooks/PreHooksHandler.sol)           | Delegatecalls a configured hook before a restricted selector runs                                | Vault clone                                 |
| [`UniversalReader`](../contracts/universal_reader/UniversalReader.sol)             | Uses a static self-call followed by delegatecall for read-only extension logic                   | Vault clone; static context prevents writes |
| External managers and oracle                                                       | Access policy, fee distribution, withdrawal state, rewards vesting, context, and prices          | Each external contract                      |

The factory assembles these addresses during creation, but it is not in the normal deposit or strategy-execution call
path. [FusionFactoryLogicLib](../contracts/factory/lib/FusionFactoryLogicLib.sol) creates the manager set and calls
`PlasmaVaultFactory.clone`; [`proxyInitialize`](../contracts/vaults/PlasmaVault.sol) then initializes the clone once.

## Entry points and routing

### Directly implemented on PlasmaVault

The primary asset paths (`deposit`, `depositWithPermit`, `mint`, `withdraw`, and `redeem`), `execute`, market-balance
updates, reward claiming, ERC-4626 previews, conversions, and `totalAssets` are implemented in
[PlasmaVault.sol](../contracts/vaults/PlasmaVault.sol). They do not enter the fallback router.

Restricted entry points run the access check in
[`AccessManagedUpgradeable`](../contracts/managers/access/AccessManagedUpgradeable.sol). `PlasmaVault` overrides
`_checkCanCall` to distinguish caller, receiver, or owner where required, consume scheduled operations, and invoke the
pre-hook configured for the original selector. Its `_msgSender()` reads
[`ContextClientStorageLib`](../contracts/managers/context/ContextClientStorageLib.sol): without an active context it is
`msg.sender`; with an authorized context it is the stored sender.

### Fallback router

The fallback in [PlasmaVault.sol](../contracts/vaults/PlasmaVault.sol) evaluates routes in this order:

1. If the execution flag is set, call [`CallbackHandlerLib`](../contracts/libraries/CallbackHandlerLib.sol) and return
   empty bytes. This branch takes precedence over votes and base routing and is intended for callbacks received while an
   action fuse is executing.
2. If `msg.sig` is one of the explicit IVotes/IERC6372/plugin selectors, delegatecall the configured
   `PlasmaVaultVotesPlugin`; revert `VotesPluginNotEnabled` when the plugin address is zero.
3. Delegate every other selector to the configured `PlasmaVaultBase`.

The base inherits `PlasmaVaultGovernance`, so governance selectors that are absent from `PlasmaVault` are served by the
base in vault context. Ordinary ERC-20 and permit functionality is reached the same way. A selector unsupported by the
base ultimately reverts; the router does not silently accept unknown operations.

There is one related internal route: `PlasmaVault._update` delegatecalls `PlasmaVaultBase.updateInternal` whenever an
ERC-20 mint, burn, or transfer updates share balances. The public `PlasmaVault.updateInternal` always reverts, preventing
an external caller from using that reserved selector directly on the vault.

## Representative call traces

### Deposit

```text
caller → clone → PlasmaVault.deposit(assets, receiver)
  → nonReentrant + restricted
      → access checks for caller and receiver
      → configured pre-hook, if any
  → _deposit
      → reject zero assets / zero receiver
      → realize accrued management fee, if nonzero
      → calculate gross shares and call ERC4626Upgradeable.deposit
          → transfer underlying from effective sender to clone
          → mint receiver shares
              → PlasmaVault._update
                  → delegatecall PlasmaVaultBase.updateInternal
                      → update ERC-20 storage, enforce cap, update optional votes plugin
      → mint the deposit-fee share difference to WithdrawManager, if any
```

The deposited underlying remains at the vault clone until later fuse execution allocates it. The deposit path reads NAV
through `totalAssets`, which combines the clone's underlying balance, cached market assets, and the vested rewards balance
when a rewards manager is configured. Deposit does not itself refresh every market balance.

### Strategy execution

```text
authorized caller → clone → PlasmaVault.execute(FuseAction[])
  → nonReentrant + restricted + selector pre-hook
  → snapshot net total assets
  → set execution-started flag
  → for each action
      → require FusesLib.isFuseSupported(fuse)
      → read fuse MARKET_ID and collect unique touched markets
      → delegatecall fuse with supplied data
          → external protocol calls occur as the vault clone
          → callback to clone, if any, is handled by fallback's callback branch
  → clear execution-started flag
  → refresh touched/dependent markets through balance-fuse delegatecalls
  → convert USD WAD balances through PriceOracleMiddleware into underlying units
  → update cached per-market and aggregate assets; enforce distribution limits
  → realize performance fee from the before/after result
  → emit ExecuteFinished
```

[`FusesLib`](../contracts/libraries/FusesLib.sol) stores the supported action and balance-fuse configuration.
[`PlasmaVaultMarketsLib`](../contracts/vaults/lib/PlasmaVaultMarketsLib.sol) expands balance dependencies, delegates
`balanceOf()` to each balance fuse, performs oracle conversion, updates the caches, and returns data for
[`AssetDistributionProtectionLib`](../contracts/libraries/AssetDistributionProtectionLib.sol). A revert at any step
reverts the complete transaction, including the execution flag and prior delegated writes.

### Normal fallback call

```text
caller → clone → selector absent from PlasmaVault
  → execution flag false
  ├─ votes selector + plugin configured → delegatecall votes plugin
  ├─ votes selector + no plugin         → revert VotesPluginNotEnabled
  └─ all other selectors                → delegatecall PlasmaVaultBase
```

For example, ERC-20 `transfer` reaches the base. The base updates the clone's ERC-20 storage and may delegate the voting
unit update to the votes plugin. Governance calls also reach the base, but their `restricted` modifiers still consult the
vault's configured authority.

## Storage ownership

The vault does not rely on the ordinary sequential storage layout of each delegated code contract. It combines
OpenZeppelin upgradeable namespaces with explicit Fusion namespaces:

- [PlasmaVaultStorageLib](../contracts/libraries/PlasmaVaultStorageLib.sol) defines slots for ERC-4626 asset metadata,
  supply-cap state, aggregate and per-market assets, balance fuses, substrates, dependency graphs, fees, execution and
  callback state, oracle, managers, base, plugin, and share scaling.
- [FuseStorageLib](../contracts/libraries/FuseStorageLib.sol) defines supported-fuse indexes and integration position
  storage used by fuse libraries.
- OpenZeppelin upgradeable parents own namespaced ERC-20, reentrancy, initialization, and access-managed state, still at
  the vault clone because their code runs in clone context.
- [ContextClientStorageLib](../contracts/managers/context/ContextClientStorageLib.sol) stores the optional effective sender
  in a dedicated namespace at the target contract.
- Individual integrations may define additional namespaced storage libraries. Their namespace and struct layout are part
  of the vault's upgrade compatibility even when the code lives under an integration directory.

The implementation, base, plugin, and fuse contracts should be treated as code providers, not as the source of a vault's
live balances or configuration. Reading their own storage addresses does not describe a clone's state.

## External managers and services

| Contract                                                                                                                            | Relationship to the vault                                                                                                             |
| ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| [`IporFusionAccessManager`](../contracts/managers/access/IporFusionAccessManager.sol)                                               | External authority used by `restricted` selectors; owns role, target-function, and delay policy.                                      |
| [`FeeManagerFactory`](../contracts/managers/fee/FeeManagerFactory.sol) and [`FeeManager`](../contracts/managers/fee/FeeManager.sol) | Initialization deploys a manager and fee accounts; the vault stores fee-account addresses and fee rates used when minting fee shares. |
| [`WithdrawManager`](../contracts/managers/withdraw/WithdrawManager.sol)                                                             | Owns request/window/fee state; the vault queries it and may mint, burn, or transfer request-related shares.                           |
| [`RewardsClaimManager`](../contracts/managers/rewards/RewardsClaimManager.sol)                                                      | Owns reward/vesting state; its vested `balanceOf()` contributes to vault `totalAssets` when configured.                               |
| [`ContextManager`](../contracts/managers/context/ContextManager.sol)                                                                | Coordinates approved calls and temporarily sets the effective sender on context-aware targets.                                        |
| [`PriceOracleMiddleware`](../contracts/price_oracle/PriceOracleMiddleware.sol)                                                      | Supplies the underlying asset price used to convert balance-fuse USD WAD values during cache refresh.                                 |

These contracts may share an authority, but they are separate addresses with separate storage. A future roles document
will map their selectors and administrators; this architecture map intentionally does not claim who currently holds any
role on any deployment.

## Where to start for a change

| Change                                                 | Primary code                                                                                                                                   | First tests to inspect                                                                                          |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Deposit, mint, withdraw, redeem, NAV, conversion       | [`PlasmaVault.sol`](../contracts/vaults/PlasmaVault.sol), [`PlasmaVaultFeesLib`](../contracts/vaults/lib/PlasmaVaultFeesLib.sol)               | [`test/vaults/`](../test/vaults/)                                                                               |
| ERC-20 shares, permit, cap, fallback governance        | [`PlasmaVaultBase.sol`](../contracts/vaults/PlasmaVaultBase.sol), [`PlasmaVaultGovernance.sol`](../contracts/vaults/PlasmaVaultGovernance.sol) | [`test/vaults/`](../test/vaults/), [`test/roles/`](../test/roles/)                                              |
| Action fuse or protocol position                       | Integration under [`contracts/fuses/`](../contracts/fuses/), `FusesLib`                                                                        | Matching integration under [`test/fuses/`](../test/fuses/) or [`test/unitTest/fuses/`](../test/unitTest/fuses/) |
| Balance cache, dependencies, limits, oracle conversion | `PlasmaVaultMarketsLib`, `PlasmaVaultLib`, balance fuse, oracle                                                                                | Matching fuse tests plus [`test/vaults/`](../test/vaults/) and [`test/price_oracle/`](../test/price_oracle/)    |
| Votes fallback or transfer voting units                | `PlasmaVault.fallback`, `PlasmaVaultBase._update`, [`PlasmaVaultVotesPlugin`](../contracts/vaults/plugins/PlasmaVaultVotesPlugin.sol)          | [`test/vaults/extensions/`](../test/vaults/extensions/)                                                         |

Always inspect fixture setup before treating a test as proof of deployed behavior. The factory fork tests can replace
implementations, managers, or permissions, so their success may prove the checked-out architecture rather than an
unchanged production deployment.
