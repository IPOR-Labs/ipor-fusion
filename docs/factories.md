# Factory guide

Use this guide to choose the factory code and the matching test mode in the
current checkout. It does not identify a deployed factory or certify that the
checked-out ABI matches one. This repository does not yet track a deployment
registry or versioned ABIs; when an existing deployment matters, record the
network, address and block and verify its implementation and configuration
on-chain.

Read [`architecture.md`](architecture.md) for vault execution boundaries and
[`roles-and-permissions.md`](roles-and-permissions.md) before choosing the
creation caller, owner or fee package.

## Choose the factory by the product being created

| Goal                            | Entry point                                                                                                                                                                                                    | What it creates                                                                                                                        | Start with these tests                                                                                                                                                                         |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Complete Fusion vault           | [`FusionFactory.clone` or `cloneSupervised`](../contracts/factory/FusionFactory.sol)                                                                                                                           | A coordinated PlasmaVault, AccessManager, PriceManager, WithdrawManager, RewardsClaimManager, ContextManager and FeeManager system.    | [`FusionFactory.t.sol`](../test/factory/FusionFactory.t.sol) and [`FusionFactoryBusinessClientFeePackagesTest.t.sol`](../test/factory/FusionFactoryBusinessClientFeePackagesTest.t.sol)        |
| One orchestration component     | The small factories beside [`FusionFactory.sol`](../contracts/factory/FusionFactory.sol)                                                                                                                       | Direct or minimal-proxy instances of AccessManager, PriceManager, WithdrawManager, RewardsClaimManager, ContextManager or PlasmaVault. | The full FusionFactory suite, because these factories currently have no independent test files.                                                                                                |
| Fee subsystem for a PlasmaVault | [`FeeManagerFactory.deployFeeManager`](../contracts/managers/fee/FeeManagerFactory.sol)                                                                                                                        | FeeManager plus its management- and performance-fee accounts.                                                                          | The full FusionFactory suite and fee-manager tests under [`test/managers/`](../test/managers/)                                                                                                 |
| Wrapped PlasmaVault             | [`WrappedPlasmaVaultFactory`](../contracts/factory/extensions/WrappedPlasmaVaultFactory.sol) or [`WhitelistWrappedPlasmaVaultFactory`](../contracts/factory/extensions/WhitelistWrappedPlasmaVaultFactory.sol) | A new wrapper around an existing PlasmaVault; the whitelist variant adds its access model.                                             | [`WrappedPlasmaVaultFactory.t.sol`](../test/factory/WrappedPlasmaVaultFactory.t.sol) or [`WhitelistWrappedPlasmaVaultFactory.t.sol`](../test/factory/WhitelistWrappedPlasmaVaultFactory.t.sol) |
| Standalone rewards router       | [`RewardsRouterFactory`](../contracts/factory/RewardsRouterFactory.sol)                                                                                                                                        | A router bound to an existing vault; required vault roles are granted separately.                                                      | Rewards router suites under [`test/managers/`](../test/managers/)                                                                                                                              |
| One price-feed implementation   | The matching source in [`contracts/factory/price_feed/`](../contracts/factory/price_feed/)                                                                                                                     | A protocol-specific price-feed contract, independent of full vault creation.                                                           | Match the factory name under [`test/factory/price_feed/`](../test/factory/price_feed/) and [`test/price_oracle/price_feed/`](../test/price_oracle/price_feed/)                                 |

Do not substitute a component factory for `FusionFactory` when the test needs a
production-shaped full vault. Conversely, do not route a wrapper or a price-feed
unit test through `FusionFactory` merely because both are called factories.

## Complete vault composition

The current full-vault route is:

1. `FusionFactory.clone` is permissionless; `cloneSupervised` requires the
   factory maintenance role and also makes the direct caller a vault admin.
2. [`FusionFactoryLib`](../contracts/factory/lib/FusionFactoryLib.sol) validates
   common inputs, allocates the instance index and delegates the composition to
   [`FusionFactoryLogicLib`](../contracts/factory/lib/FusionFactoryLogicLib.sol).
3. The logic library reads the active component-factory and base addresses from
   [`FusionFactoryStorageLib`](../contracts/factory/lib/FusionFactoryStorageLib.sol),
   selects the fee package by the direct factory caller, and clones the managers
   and PlasmaVault.
4. During [`PlasmaVault`](../contracts/vaults/PlasmaVault.sol) initialization,
   the configured `feeFactory` calls
   [`FeeManagerFactory`](../contracts/managers/fee/FeeManagerFactory.sol). This
   factory is intentionally outside `contracts/factory/`; omitting it from a
   factory change or fixture leaves the creation path incomplete.
5. The logic library creates or clones ContextManager, connects all managers,
   initializes FeeManager and installs the generated AccessManager roles.

The component factory set stored by FusionFactory contains exactly
`accessManagerFactory`, `plasmaVaultFactory`, `feeManagerFactory`,
`withdrawManagerFactory`, `rewardsManagerFactory`, `contextManagerFactory` and
`priceManagerFactory`. Any change to an initialization struct or constructor
must be checked across the caller, the selected component factory, its created
contract, and the full-vault tests.

## “Version” has three different meanings

Do not choose a factory from a version number alone:

- **Fusion composition label.** `getFusionFactoryVersion()` returns one active
  storage value. Both `updateFactoryAddresses(version, ...)` and
  `updateBaseAddresses(version, ...)` overwrite that value and the corresponding
  active address set. The contract does not retain a queryable history keyed by
  version. New `FusionInstance` events copy the current label.
- **Proxy implementation.** `FusionFactory`, wrapper factories and price-feed
  factories use UUPS proxies. The implementation behind a deployed proxy is a
  separate fact from the composition label and must be read at the relevant
  block before using the checked-out ABI or testing an upgrade.
- **Clone bases and component factories.** The active base addresses determine
  clone bytecode, while the active factory addresses determine how components
  are constructed. Matching the outer FusionFactory implementation is therefore
  insufficient; inspect both `getBaseAddresses()` and `getFactoryAddresses()`.

The active-value behavior is implemented in
[`FusionFactory.sol`](../contracts/factory/FusionFactory.sol) and
[`FusionFactoryStorageLib.sol`](../contracts/factory/lib/FusionFactoryStorageLib.sol).
There is no common version getter on the standalone wrapper and price-feed
factories; identify those by proxy implementation and matching source/ABI.

## Pick the test mode before writing the fixture

| Mode                                   | Required setup                                                                                                                                                                                                                             | What a passing test proves                                                                                       | Representative source                                                                                                                                                                                                                       |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Fresh local deployment                 | Deploy every component factory, implementation/base, middleware dependency and the FusionFactory implementation plus ERC-1967 proxy; grant factory roles and configure fee packages/bases locally. No RPC should be read.                  | Behavior of the checked-out contracts and the fixture's local configuration.                                     | [`FusionFactory.t.sol`](../test/factory/FusionFactory.t.sol)                                                                                                                                                                                |
| Fresh deployment on a fork             | Select and pin a fork, then deploy a new FusionFactory/proxy. Existing contracts may be read as dependencies or as configuration sources, but the created factory remains local to the fork.                                               | Checked-out factory behavior against external state at that block, including every copied or replaced component. | [`FusionFactoryDaoFeePackagesForkTest.t.sol`](../test/factory/FusionFactoryDaoFeePackagesForkTest.t.sol) and [`FusionFactoryBusinessClientFeePackagesForkTest.t.sol`](../test/factory/FusionFactoryBusinessClientFeePackagesForkTest.t.sol) |
| Upgrade of an existing proxy on a fork | Bind the exact deployed proxy, deploy a new implementation, impersonate an authorized admin, call `upgradeToAndCall`, and record every role grant and component/base replacement.                                                          | Behavior of the upgraded and mutated fork fixture—not behavior of the original deployment.                       | [`FusionFactoryDaoFeePackagesHelper.sol`](../test/test_helpers/FusionFactoryDaoFeePackagesHelper.sol) and tests that call it                                                                                                                |
| Existing factory without upgrade       | Bind a verified deployment with its matching ABI at a named block; read implementation, version, factory/base addresses, roles and fee packages; invoke it with the intended direct caller without replacing code, configuration or roles. | Behavior of that deployed factory at the selected state and under the real caller/configuration assumptions.     | No dedicated tracked factory test currently provides this evidence; T25 in the agent-readiness plan is intended to add one.                                                                                                                 |

Directory names are not proof of a mode. In particular, the two
`FusionFactory*ForkTest` suites above deploy a fresh factory, while
`FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages` upgrades an
existing proxy and replaces multiple factory/base addresses. Read `setUp()` and
every helper before describing fork evidence.

Never make an “existing factory” test pass by silently upgrading it, granting a
missing role or replacing an incompatible component. If mutation is the subject
of the test, name it in the test and handoff.

## Test selection

Start with the smallest relevant suite:

```bash
# Full vault creation, local and without RPC credentials
forge test --match-path test/factory/FusionFactory.t.sol

# Caller-keyed fee-package behavior, local
forge test --match-path test/factory/FusionFactoryBusinessClientFeePackagesTest.t.sol

# One wrapper variant
forge test --match-path test/factory/WrappedPlasmaVaultFactory.t.sol

# One price-feed factory (often a pinned fork; inspect setUp first)
forge test --match-path test/factory/price_feed/ERC4626PriceFeedFactoryTest.t.sol
```

For a full-vault factory change, run the local FusionFactory suite first and add
the business-client suite whenever fee selection, caller identity or final fee
configuration can change. Expand to a pinned fork only when the behavior depends
on external contracts. Missing RPC or archive state is an infrastructure result,
not a protocol pass or failure.

## Existing-deployment preflight

Before planning any operation through an existing factory, capture:

1. network, proxy address and block;
2. proxy implementation and the ABI/source matched to it;
3. `getFusionFactoryVersion()`, `getFactoryAddresses()` and
   `getBaseAddresses()` at that block;
4. price middleware, burn-request fuses, withdraw window and vesting period;
5. exact direct caller and its factory roles;
6. the fee-package array selected for that caller and the intended index.

If any of these disagree with a local fixture or the checked-out source, stop and
report the discrepancy. Source code and a locally green test do not establish a
live factory's identity or current state.
