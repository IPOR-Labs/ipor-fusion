# Factory contributor instructions

These instructions supplement the repository root `AGENTS.md` for
`contracts/factory/` and its subdirectories.

## Start here

- Read [`../../docs/factories.md`](../../docs/factories.md) to choose the product,
  version evidence and test mode.
- Read [`../../docs/roles-and-permissions.md`](../../docs/roles-and-permissions.md)
  before changing callers, owners, factory roles or fee packages.
- For full-vault creation, inspect `FusionFactory.sol`, `lib/FusionFactoryLib.sol`,
  `lib/FusionFactoryLogicLib.sol` and `lib/FusionFactoryStorageLib.sol` together.
- Always include
  [`../managers/fee/FeeManagerFactory.sol`](../managers/fee/FeeManagerFactory.sol)
  in a full-vault creation review even though it is outside this directory.

## Identify the factory layer before editing

- `FusionFactory` is the UUPS orchestration proxy for a complete Fusion vault.
- `AccessManagerFactory`, `PlasmaVaultFactory`, `PriceManagerFactory`,
  `WithdrawManagerFactory`, `RewardsManagerFactory` and `ContextManagerFactory`
  are component construction helpers used by the orchestration flow.
- `extensions/` creates wrapped vault products around an existing PlasmaVault.
- `price_feed/` creates independent protocol-specific price feeds.
- `RewardsRouterFactory` creates a standalone per-vault router; it does not create
  or configure a complete vault.

Do not solve a full-vault problem by bypassing `FusionFactory` with a component
factory unless the task explicitly tests that lower-level boundary.

## Full-vault change checklist

1. Trace the input through both FusionFactory libraries, the active storage
   getters and the selected component factory.
2. Check the created contract's constructor or initializer and every matching
   struct. `PlasmaVaultInitData`, `FeeConfig`, `FeeManagerInitData` and
   `FusionInstance` cross directory boundaries.
3. Preserve the direct `msg.sender`: it selects custom fee packages and differs
   from `owner_`. `cloneSupervised` also derives the new vault admin from it.
4. Treat the Fusion factory version as one mutable composition label, not a
   version registry. Updating factory addresses or base addresses replaces the
   active set.
5. Preserve external ABI, UUPS authorization and ERC-7201 storage slots. Analyze
   storage compatibility before adding state to an upgradeable factory.
6. Validate nonzero addresses and units at the same trust boundary as existing
   code; fee percentages use basis points and time values use seconds.
7. If an initializer shape changes, update every component factory and full-vault
   caller in the same change, including `FeeManagerFactory` outside this tree.

Do not change compiler settings or enable `via_ir`. Do not add indexed event
parameters; this repository deliberately keeps event parameters in data.

## Tests and evidence

- Full local creation: `test/factory/FusionFactory.t.sol`.
- Caller-specific fees: `test/factory/FusionFactoryBusinessClientFeePackagesTest.t.sol`.
- Wrapper factories: their matching files under `test/factory/`.
- Price-feed factories: search both `test/factory/price_feed/` and
  `test/price_oracle/price_feed/` by contract name.
- Component factories have no dedicated suites; cover them through the smallest
  full flow that reaches the changed component.

Run the local FusionFactory suite before fork expansion. For any fork test,
inspect `setUp()`, provider environment reads, pinned block and all helpers.
`FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages` upgrades an
existing proxy, grants roles and replaces components; a passing test that uses it
is evidence for that mutated fixture, not the unchanged deployment.

Keep these modes explicit in the test name and handoff:

- fresh local deployment;
- fresh deployment against fork state;
- intentional upgrade of an existing proxy on a fork;
- use of an existing factory without upgrade or configuration mutation.

Never claim the last mode if the fixture upgrades code, replaces bases/factories
or grants roles to make creation succeed. When a deployment matters, record the
network, address, block, implementation and ABI source; this checkout has no
maintained deployment registry yet.
