# FusionFactory — Deterministic Cross-Chain Vault Deployment

## Overview

FusionFactory deploys complete Fusion Vault stacks (PlasmaVault + AccessManager + all managers) with **deterministic addresses** across all EVM-compatible chains using **Solady CREATE3**.

The same `masterSalt` on any chain produces the same set of addresses. **Only `masterSalt` and the factory address determine the deployed addresses** — all other parameters (asset name, underlying token, owner, fees, redemption delay) can differ per chain without affecting the addresses.

## Architecture

### Deployment Phases

Vault creation happens in two phases:

| Phase | Components | When | Deterministic? |
|-------|-----------|------|----------------|
| **Phase 1** (atomic) | AccessManager, PriceManager, WithdrawManager, PlasmaVault, FeeManager | `clone()` / `cloneWithSalt()` | Yes (except FeeManager) |
| **Phase 2** (lazy) | RewardsManager, ContextManager | `deployComponent()` | Yes |

FeeManager is created internally by `PlasmaVault.init()` via `new` — its address is not deterministic but is stored in the vault instance registry.

Phase 1 deploys atomically because PlasmaVault initialization requires AccessManager, PriceManager, WithdrawManager, and FeeConfig to be ready. Phase 2 is lazy because RewardsManager and ContextManager are not required during vault initialization — their addresses are pre-computed and can be deployed later.

### Salt Derivation

```
masterSalt
  ├── keccak256(masterSalt, "vault")     → PlasmaVault
  ├── keccak256(masterSalt, "access")    → AccessManager
  ├── keccak256(masterSalt, "price")     → PriceManager
  ├── keccak256(masterSalt, "withdraw")  → WithdrawManager
  ├── keccak256(masterSalt, "rewards")   → RewardsManager
  └── keccak256(masterSalt, "context")   → ContextManager
```

Two salt domains prevent collisions:
- **Auto** (`clone()`): `masterSalt = keccak256("ipor.fusion.auto", factoryIndex)`
- **Explicit** (`cloneWithSalt()`): `masterSalt = keccak256("ipor.fusion.explicit", userSalt)`

### Library Structure

```
FusionFactory.sol                    ← Public entry point (upgradeable proxy)
  ├── FusionFactoryLib.sol           ← Orchestration (clone, cloneWithSalt, deployComponent, predict)
  ├── FusionFactoryLogicLib.sol      ← Deployment logic (doCloneDeterministic, doCloneDeterministicFullStack)
  ├── FusionFactoryConfigLib.sol     ← Post-deploy configuration (WithdrawManager, Fuses, FeeManager)
  ├── FusionFactoryAccessInitLib.sol ← AccessManager initialization + role setup
  ├── FusionFactoryLazyDeployLib.sol ← Phase 2 lazy deployment with temp role management
  ├── FusionFactoryCreate3Lib.sol    ← CREATE3 wrapper, salt derivation, address prediction
  └── FusionFactoryStorageLib.sol    ← ERC-7201 storage (VaultInstanceAddresses, Component enum)
```

### Sub-Factory Pattern

All sub-factories (PlasmaVaultFactory, AccessManagerFactory, PriceManagerFactory, WithdrawManagerFactory, RewardsManagerFactory, ContextManagerFactory) follow a common pattern:

- **`FUSION_FACTORY` immutable** — set at construction, restricts callers via `onlyFusionFactory` modifier
- **`deployDeterministic(baseAddress_, salt_, ...)`** — deploys EIP-1167 minimal proxy via CREATE3 (replaces old `clone()`)
- **`predictDeterministicAddress(salt_)`** — view function to predict deployment address
- Sub-factories can only be called by FusionFactory — prevents unauthorized direct deployments

## Usage

### 1. Full-Stack Deployment (clone)

Deploys all 7 components atomically. Backward-compatible with the original `clone()` API.

```solidity
FusionFactoryLogicLib.FusionInstance memory vault = fusionFactory.clone(
    "Fusion USDC Vault",           // assetName
    "fUSDC",                       // assetSymbol
    0xA0b86991c...,                // underlyingToken (USDC)
    86400,                         // redemptionDelayInSeconds (24h)
    0xOwnerAddress...,             // owner
    0                              // daoFeePackageIndex
);

// All 7 components are deployed and configured:
// vault.plasmaVault, vault.accessManager, vault.priceManager,
// vault.withdrawManager, vault.feeManager, vault.rewardsManager, vault.contextManager
```

### 2. Predict Addresses Before Deployment

```solidity
// Predict addresses for an explicit salt
(
    address vault,
    address accessManager,
    address priceManager,
    address withdrawManager,
    address rewardsManager,
    address contextManager
) = fusionFactory.predictAddresses(masterSalt);

// Predict addresses for the next auto-deployment (clone())
(vault, accessManager, priceManager, withdrawManager, rewardsManager, contextManager)
    = fusionFactory.predictNextAddresses();
```

### 3. Cross-Chain Deterministic Deployment (cloneWithSalt)

Deploy Phase 1 atomically. Phase 2 components (RewardsManager, ContextManager) are pre-computed but not yet deployed.

```solidity
bytes32 masterSalt = keccak256("my-unique-vault-salt-v1");

// Step 1: Predict addresses (optional — can be done off-chain)
(address vault, , , , address rewardsManager, address contextManager)
    = fusionFactory.predictAddresses(masterSalt);

// Step 2: Deploy Phase 1
// Only masterSalt determines the addresses — assetName, underlyingToken, owner, fees etc.
// do NOT affect the deployed addresses. As long as the FusionFactory is at the same address
// on each chain and uses the same masterSalt, the vault stack gets identical addresses.
FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.cloneWithSalt(
    "Fusion USDC Vault",           // can differ per chain
    "fUSDC",                       // can differ per chain
    0xA0b86991c...,                // can differ per chain (e.g. different USDC address)
    86400,                         // can differ per chain
    0xOwnerAddress...,             // can differ per chain
    0,                             // can differ per chain
    masterSalt                     // THIS determines the addresses
);

// Phase 1 deployed: AccessManager, PriceManager, WithdrawManager, PlasmaVault, FeeManager
// Phase 2 pre-computed: RewardsManager and ContextManager addresses are known but not deployed
```

### 4. Lazy Deploy Phase 2 Components

Deploy RewardsManager and ContextManager when ready. Order does not matter.

```solidity
import {Component} from "./lib/FusionFactoryStorageLib.sol";

// Deploy RewardsManager at its pre-computed address
address rewardsManager = fusionFactory.deployComponent(
    instance.plasmaVault,
    Component.RewardsManager
);

// Deploy ContextManager at its pre-computed address
address contextManager = fusionFactory.deployComponent(
    instance.plasmaVault,
    Component.ContextManager
);
```

### 5. Query Vault Instance

```solidity
import {VaultInstanceAddresses} from "./lib/FusionFactoryStorageLib.sol";

VaultInstanceAddresses memory info = fusionFactory.getVaultInstanceAddresses(plasmaVaultAddress);

// Check deployment status
bool rewardsReady = info.rewardsManagerDeployed;   // true after deployComponent(RewardsManager)
bool contextReady = info.contextManagerDeployed;    // true after deployComponent(ContextManager)

// Access all addresses
info.plasmaVault;       // Phase 1
info.accessManager;     // Phase 1
info.priceManager;      // Phase 1
info.withdrawManager;   // Phase 1
info.feeManager;        // Phase 1
info.rewardsManager;    // Phase 2 (address known even before deployment)
info.contextManager;    // Phase 2 (address known even before deployment)
```

## Access Control

| Method | Required Role |
|--------|--------------|
| `clone()` | Public |
| `cloneSupervised()` | `MAINTENANCE_MANAGER_ROLE` |
| `cloneWithSalt()` | `MAINTENANCE_MANAGER_ROLE` |
| `cloneSupervisedWithSalt()` | `MAINTENANCE_MANAGER_ROLE` |
| `deployComponent()` | `MAINTENANCE_MANAGER_ROLE` on factory **OR** `ATOMIST_ROLE` on vault's AccessManager |
| `predictAddresses()` | Public (view) |
| `predictNextAddresses()` | Public (view) |
| `getVaultInstanceAddresses()` | Public (view) |
| `setDaoFeePackages()` | `DAO_FEE_MANAGER_ROLE` |
| `updateFactoryAddresses()` | `MAINTENANCE_MANAGER_ROLE` |
| `updateBaseAddresses()` | `MAINTENANCE_MANAGER_ROLE` |

## Events

### Vault Creation

```solidity
// Emitted by FusionFactoryLib on every clone/cloneWithSalt
event FusionInstanceCreated(
    uint256 index, uint256 version,
    string assetName, string assetSymbol, uint8 assetDecimals,
    address underlyingToken, string underlyingTokenSymbol, uint8 underlyingTokenDecimals,
    address initialOwner, address plasmaVault, address plasmaVaultBase, address feeManager
);

// Emitted by FusionFactory on cloneWithSalt/cloneSupervisedWithSalt
event VaultInstanceCreatedDeterministic(
    bytes32 indexed masterSalt, address indexed plasmaVault,
    address accessManager, address priceManager, address withdrawManager,
    address feeManager, address rewardsManager, address contextManager
);

// Emitted by FusionFactory on deployComponent
event ComponentDeployed(address indexed plasmaVault, Component component, address deployedAddress);

// Emitted inside FusionFactoryLazyDeployLib
event LazyComponentDeployed(address indexed plasmaVault, Component component, address deployedAddress);
```

## Errors

### FusionFactory

| Error | Context |
|-------|---------|
| `UnauthorizedCaller()` | `deployComponent()` — caller has neither `MAINTENANCE_MANAGER_ROLE` nor `ATOMIST_ROLE` |

### FusionFactoryLib

| Error | Context |
|-------|---------|
| `InvalidFactoryAddress()` | Sub-factory address is zero |
| `InvalidAddress()` | General zero-address validation |
| `InvalidUnderlyingToken()` | Underlying token address is zero |
| `InvalidOwner()` | Owner address is zero |
| `InvalidWithdrawWindow()` | Withdraw window is zero |
| `DaoFeePackageIndexOutOfBounds(index, length)` | DAO fee package index exceeds array |
| `DaoFeePackagesArrayEmpty()` | No DAO fee packages configured |
| `FeeExceedsMaximum(fee, maxFee)` | Fee exceeds maximum allowed |
| `FeeRecipientZeroAddress()` | Fee recipient is zero address |
| `VaultNotCreatedByFactory()` | Vault not found in factory registry |
| `ComponentAlreadyDeployed()` | Phase 2 component already deployed |
| `UnauthorizedComponentDeployer()` | Caller not authorized to deploy component |

### FusionFactoryCreate3Lib

| Error | Context |
|-------|---------|
| `SaltAlreadyUsed()` | CREATE3 salt reuse attempt |
| `InvalidImplementation()` | Implementation address is zero |

### FusionFactoryLazyDeployLib

| Error | Context |
|-------|---------|
| `ComponentAlreadyDeployed()` | Double-deploy prevention |
| `VaultNotRegistered()` | Vault not found in instance registry |

### Sub-Factories

| Error | Context |
|-------|---------|
| `InvalidBaseAddress()` | Base implementation address is zero |
| `CallerNotFusionFactory()` | Caller is not the FusionFactory |

## Security Model

### Factory ADMIN_ROLE Lifecycle

When using `cloneWithSalt()` (lazy deployment):

1. **Phase 1**: Factory is set as `initialAuthority` on AccessManager
2. **AccessManager.initialize()** revokes factory's authority
3. **Factory re-grants itself ADMIN_ROLE** via extended `accountToRoles` in initialization data
4. **Phase 2 deploy**: Factory uses ADMIN_ROLE to configure RewardsManager (temp role grants for `setupVestingTime` and `setRewardsClaimManagerAddress`)
5. **After both Phase 2 components deployed**: Factory's ADMIN_ROLE is **automatically revoked**

The factory never retains permanent elevated access to any vault.

### Lazy Deploy Temporary Role Flow (RewardsManager)

1. Factory grants itself `TECH_REWARDS_CLAIM_MANAGER_ROLE` (using ADMIN_ROLE)
2. Factory temporarily changes `setupVestingTime` access from `ATOMIST_ROLE` to `ADMIN_ROLE`
3. Executes `setupVestingTime()` and `setRewardsClaimManagerAddress()`
4. Restores `setupVestingTime` to require `ATOMIST_ROLE`
5. Revokes `TECH_REWARDS_CLAIM_MANAGER_ROLE`
6. If ContextManager already deployed → revokes factory ADMIN_ROLE

### Salt Protection

- `cloneWithSalt()` requires `MAINTENANCE_MANAGER_ROLE` — prevents salt squatting
- CREATE3 reverts on salt reuse — each salt can only be used once
- Domain separation (`"ipor.fusion.auto"` vs `"ipor.fusion.explicit"`) prevents collisions between `clone()` and `cloneWithSalt()`

### Double-Deploy Prevention

- `deployComponent()` checks `rewardsManagerDeployed` / `contextManagerDeployed` flags
- Attempting to deploy an already-deployed component reverts with `ComponentAlreadyDeployed()`

### Sub-Factory Authorization

- All sub-factories restricted to FusionFactory caller via `onlyFusionFactory()` modifier
- `FUSION_FACTORY` is immutable — set at construction time

## Data Structures

```solidity
struct VaultInstanceAddresses {
    bytes32 masterSalt;
    address plasmaVault;
    address accessManager;
    address priceManager;
    address withdrawManager;
    address feeManager;
    address rewardsManager;
    address contextManager;
    bool    rewardsManagerDeployed;
    bool    contextManagerDeployed;
    address owner;
    bool    withAdmin;
    address daoFeeRecipientAddress;
}

enum Component {
    RewardsManager,
    ContextManager
}

struct FeePackage {
    uint256 managementFee;    // 2 decimals (10000 = 100%)
    uint256 performanceFee;   // 2 decimals (10000 = 100%)
    address feeRecipient;
}
```

## Cross-Chain Deployment Workflow

To deploy the same vault stack on multiple chains:

```
1. Choose a masterSalt (e.g., keccak256("my-vault-v1"))

2. On each chain, call predictAddresses(masterSalt) to verify expected addresses

3. On Chain A (Ethereum):
   fusionFactory.cloneWithSalt(
       "Fusion USDC",   0xA0b8...,  owner_eth, ..., masterSalt
   )
   fusionFactory.deployComponent(vault, RewardsManager)
   fusionFactory.deployComponent(vault, ContextManager)

4. On Chain B (Arbitrum) — same factory address, same masterSalt:
   fusionFactory.cloneWithSalt(
       "Fusion USDC",   0xFF97...,  owner_arb, ..., masterSalt   // different USDC, different owner
   )
   fusionFactory.deployComponent(vault, RewardsManager)
   fusionFactory.deployComponent(vault, ContextManager)

5. Result: identical vault addresses on both chains
   (despite different underlying tokens, owners, and other parameters)
```

**Requirements:**
- The FusionFactory itself must be deployed at the same address on each chain (also via CREATE3 or CREATE2)
- The same `masterSalt` must be used — all other parameters (asset name, token, owner, fees) are independent and can differ per chain
