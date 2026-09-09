# Manager contributor instructions

These instructions supplement the repository root `AGENTS.md` for
`contracts/managers/` and its subdirectories.

## Start here

- Read [`../../docs/architecture.md`](../../docs/architecture.md) for how the
  vault reaches each manager and which addresses it caches.
- Read [`../../docs/roles-and-permissions.md`](../../docs/roles-and-permissions.md)
  for the roles, the two kinds of delay and the identity checklist. It is the
  reference; this file only says what is specific to editing a manager.
- The selector-to-role map for **every** manager lives outside this tree, in
  [`../vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol`](../vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol).
  Trust it over NatSpec: some `WithdrawManager` comments still say `ATOMIST_ROLE`
  for the fee setters that the initializer wires to the dedicated fee roles.

## What is here

| Directory   | Contract                                                         | Created as                                                                | Reached by the vault                                                                                 |
| ----------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `access/`   | `IporFusionAccessManager` (extends OpenZeppelin `AccessManager`) | clone via `AccessManagerFactory`                                          | authority of every `restricted` call; `canCallAndUpdate` on deposit/withdraw/transfer selectors      |
| `context/`  | `ContextManager`                                                 | clone or `new` via `ContextManagerFactory`                                | never; it calls the vault and the managers on behalf of a sender                                     |
| `fee/`      | `FeeManager` plus two `FeeAccount`s                              | `new` inside `FeeManagerFactory`, called by the vault during its own init | through the fee account: `FeeAccount.FEE_MANAGER()`                                                  |
| `price/`    | `PriceOracleMiddlewareManager`                                   | clone via `PriceManagerFactory`                                           | as the vault's `priceOracleMiddleware`; see [`../price_oracle/AGENTS.md`](../price_oracle/AGENTS.md) |
| `rewards/`  | `RewardsClaimManager`; `RewardsRouter`                           | clone via `RewardsManagerFactory`; `new` via `RewardsRouterFactory`       | `balanceOf()` folded into `totalAssets`; router is inert until granted roles                         |
| `withdraw/` | `WithdrawManager`                                                | clone via `WithdrawManagerFactory`                                        | `canWithdrawFromRequest` and `canWithdrawFromUnallocated`                                            |

All managers except `IporFusionAccessManager` inherit the repository's own
[`access/AccessManagedUpgradeable.sol`](access/AccessManagedUpgradeable.sol),
and most inherit [`context/ContextClient.sol`](context/ContextClient.sol). No
manager is ever reached by `delegatecall`; that is the fuse path only. Each
manager has its own storage at its own address.

## Identity: who is `msg.sender` on each path

- **Vault to manager** is a direct call, so the manager sees the vault. That is
  why `canCallAndUpdate`, `canWithdrawFromRequest`, `canWithdrawFromUnallocated`
  and `validateAllAssetsPrices` are wired to `TECH_PLASMA_VAULT_ROLE`, and why
  `FeeManager.calculateAndUpdatePerformanceFee` checks `msg.sender` against the
  vault directly instead of using `restricted`.
- **Through `ContextManager`** the manager's `_msgSender()` returns the sender
  stored by `ContextClientStorageLib`, but `AccessManagedUpgradeable` authorizes
  `setupContext` and `clearContext` against the real caller, which must hold
  `TECH_CONTEXT_MANAGER_ROLE`. `runWithContext` is open to anyone and forces the
  context sender to `msg.sender`; `runWithContextAndSignature` verifies a custom
  (not EIP-712) signature over contract address, expiry, nonce, chain ID, target
  and calldata.
- **`RewardsRouter`** bypasses the selector map: it checks `hasRole` itself for
  `ALPHA_ROLE` and `ATOMIST_ROLE`, and it needs the claim, transfer and update
  rewards roles granted to the router address before it does anything.
- **`WithdrawManager.requestShares`** is public and unauthenticated by design.
  The gates on that path are the request fee, the withdraw window and the
  release timestamp set by `releaseFunds` (`ALPHA_ROLE`).
- **`IporFusionAccessManager.initialize`** revokes `ADMIN_ROLE` from its own
  caller and assigns the guardian to every other role. `updateTargetClosed`
  (`GUARDIAN_ROLE`) is the pause switch.

Tests must keep these identities separate. A test that pranks one address for
the vault, the manager and the operator proves nothing about production gating.

## Units: three different percentages

| Value                          | Unit                                       | Where                                                           |
| ------------------------------ | ------------------------------------------ | --------------------------------------------------------------- |
| management and performance fee | 2 decimals, `10000` = 100%                 | `FeeManager`, `FeeManagerFactory` structs, `PlasmaVaultFeesLib` |
| deposit fee                    | WAD, `1e18` = 100%                         | `FeeManagerStorageLib`, `FeeManager.calculateDepositFee`        |
| withdraw fee and request fee   | WAD, `1e18` = 100%                         | `WithdrawManager`                                               |
| high-water mark                | assets per one whole share                 | `FeeManager`                                                    |
| delays                         | seconds; redemption delay capped at 7 days | `IporFusionAccessManager`, `RedemptionDelayLib`                 |

Mixing the 2-decimal and WAD conventions is silent and off by `1e14`. Name the
unit in every new field, argument and test.

## Change checklist

1. **Count the selectors.** Adding or removing a `restricted` function on a
   manager requires updating the matching `ROLES_TO_FUNCTION_*` constant at the
   top of `IporFusionAccessManagerInitializerLibV1.sol`, and a new role requires
   `ADMIN_ROLES_ARRAY_LENGTH`. The arrays are fixed-size; a wrong count fails
   at initialization, not at compile time.
2. **Keep both initializers in sync.** A clone-able manager has a
   `constructor(...) initializer` for a base deployment and a
   `proxyInitialize(...) initializer` for the factory. Changing one signature
   without the other breaks either path silently.
3. **Follow a struct across directories.** `FeeManagerInitData`, `FeeConfig` and
   `RecipientFee` are consumed by `FusionFactoryLogicLib` and by
   `PlasmaVault` init. `FeeManagerFactory` validates nothing; every new invariant
   belongs in the `FeeManager` constructor.
4. **Fees are stored twice.** `FeeManager._updateFees` writes its own storage
   and calls the vault's `configureManagementFee` and
   `configurePerformanceFee`. A new update path must do both, and harvest first
   so the old rate is settled.
5. **The vault caches manager addresses.** Withdraw manager (canonical slot plus
   a legacy fallback kept only for two fee fuses), rewards claim manager, price
   manager, and the fee accounts. Replacing a manager means updating the vault's
   slot as well, and new code must use `getWithdrawManager().manager`, never the
   legacy getter.
6. **Preserve the ERC-7201 namespaces** of every `*StorageLib` here and of
   `AccessManagedUpgradeable`, which shares OpenZeppelin's slot on purpose.
   `RedemptionDelayLib` reads `REDEMPTION_DELAY_IN_SECONDS` from `address(this)`
   and is only correct when linked into the access manager.
7. **Withdraw math.** `canWithdrawFromRequest` mutates state (it decrements the
   request and `sharesToRelease`); only released shares are reserved, pending
   requests are not; a release timestamp must be in the past and later than the
   request; `redeemFromRequest` applies no withdraw fee while the ERC-4626
   previews already subtract it.
8. **Rewards.** `RewardsClaimManager.claimRewards` is where reward fuses are
   checked against a fuse list that belongs to the manager, not the vault, and
   `transfer` refuses the underlying token. Vesting changes must respect the
   `UnsafeVestingTime` and `UnsafeReschedule` guards.
9. Do not add `indexed` event parameters. A few events in `context/` already
   have them; they are existing exceptions, not a licence. Do not change
   compiler settings or enable `via_ir`.

## Tests and evidence

No manager suite is classified in `config/test-suites.json`, so `npm run
test:unit` does not run any of them and an unlisted suite carries no claim about
being local. Read `setUp()` before quoting a result. As of this checkout:

- **Local (no RPC):** `test/managers/FeeManagerFactoryTest.t.sol`,
  `FeeManagerPerformanceFeeCalculationTest.t.sol`, `RewardsClaimManagerTest.t.sol`
  (with `MockPlasmaVault.sol` and `MockToken.sol`), `RewardsRouterTest.t.sol`,
  and `test/libraries/PlasmaVaultStorageLibLegacyFallbackTest.t.sol`.
- **Fork:** the other files in [`../../test/managers/`](../../test/managers/),
  everything in [`../../test/context/`](../../test/context/) (shared fixture
  `ContextManagerInitSetup.sol` on Base), `test/roles/IporPlasmaVaultRolesTest.t.sol`
  (Arbitrum), and the vault suites that exercise a manager through the vault:
  `test/vaults/PlasmaVaultFee.t.sol`, `PlasmaVaultDepositFee.t.sol`,
  `PlasmaVaultScheduledWithdraw.t.sol` (the main request and release suite),
  `PlasmaVaultWithdraw.t.sol`, and `test/pre_hooks/ValidateAllAssetsPricesPreHookTest.t.sol`.

Start with the direct manager suite, then the vault suite for the path the
change reaches (fee accrual, withdraw, rewards in `totalAssets`, price
validation), then the matching `test/context/` file, because every manager is
also callable through `ContextManager`. Report a missing provider or archive
state as an infrastructure limitation.
