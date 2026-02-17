# FusionFactoryWrapper

A wrapper contract around IPOR's `FusionFactory` that deploys a fully configured **private PlasmaVault** with all core roles distributed in a **single transaction**.

## Overview

In the standard IPOR flow, deploying a vault requires multiple transactions to assign roles after `clone()`. `FusionFactoryWrapper` eliminates this by acting as a temporary owner — it clones the vault, assigns every required role, and then renounces its own privileges. The result is a ready-to-use vault where each actor can immediately perform their duties.

## Architecture

```
                              ┌─────────────────────────┐
                              │  FusionFactoryWrapper    │
                              │  (AccessControlEnumerable)│
                              └────────────┬────────────┘
                                           │ calls clone()
                                           ▼
                              ┌─────────────────────────┐
                              │  FusionFactory (proxy)   │
                              └────────────┬────────────┘
                                           │ creates
                         ┌─────────────────┼─────────────────┐
                         ▼                 ▼                 ▼
                  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐
                  │ PlasmaVault │  │AccessManager │  │  Managers    │
                  │ (ERC-4626)  │  │              │  │ (Withdraw,   │
                  └─────────────┘  └──────────────┘  │  Price, etc.)│
                                                     └──────────────┘
```

## Wrapper Roles (on the wrapper contract itself)

The wrapper has its own access control layer that governs **who can create vaults**:

| Role | Who holds it | Purpose |
|------|-------------|---------|
| `DEFAULT_ADMIN_ROLE` | Wrapper admin (set at deploy) | Can grant/revoke `VAULT_CREATOR_ROLE` |
| `VAULT_CREATOR_ROLE` | Authorized deployer(s) | Can call `createVault()` and `createVaultSigned()` |

Only addresses with `VAULT_CREATOR_ROLE` can create new vaults through the wrapper.

## Vault Roles (on each created vault's AccessManager)

Each vault created by the wrapper receives the following role assignments:

```
┌──────────────────────┐     ┌──────────────────────┐
│ Owner (role 1)       │     │ Guardian (role 2)     │
│ Tesseract Admin      │     │ Tesseract Guardian    │
│ Multisig             │     │ Multisig              │
│                      │     │                       │
│ • Grant/revoke:      │     │ • Freeze vault (AML)  │
│   Guardian, Atomist  │     │ • Cancel operations   │
│ • Key rotation only  │     │ • No timelocks        │
└──────────────────────┘     └───────────────────────┘

┌──────────────────────┐     ┌──────────────────────┐
│ Atomist (role 100)   │     │ Alpha (role 200)      │
│ Tesseract DCV        │     │ DCV Manager           │
│ Provisioner          │     │                       │
│                      │     │ • Execute strategies   │
│ • Add fuses          │     │ • Allocate funds       │
│ • Set fees           │     │ • Reallocate between   │
│ • Grant/revoke:      │     │   markets              │
│   Alpha, Whitelist,  │     └───────────────────────┘
│   FuseManager, etc.  │
└──────────────────────┘     ┌──────────────────────┐
                             │ Whitelist (role 800)  │
                             │ User / Deployer       │
                             │                       │
                             │ • Deposit             │
                             │ • Withdraw            │
                             │ • Mint / Redeem       │
                             └───────────────────────┘
```

### Role Hierarchy

```
OWNER_ROLE (1)
├── manages GUARDIAN_ROLE (2)
├── manages ATOMIST_ROLE (100)
└── manages itself

ATOMIST_ROLE (100)
├── manages ALPHA_ROLE (200)
├── manages FUSE_MANAGER_ROLE (300)
├── manages WHITELIST_ROLE (800)
├── manages CLAIM_REWARDS_ROLE (600)
├── manages TRANSFER_REWARDS_ROLE (700)
├── manages CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE (900)
├── manages UPDATE_MARKETS_BALANCES_ROLE (1000)
├── manages UPDATE_REWARDS_BALANCE_ROLE (1100)
└── manages PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE (1200)
```

### Detailed Role Permissions

#### Owner (Tesseract Admin Multisig)

- **Purpose**: Emergency key rotation only. Not used in day-to-day operations.
- **Can do**:
  - Grant/revoke `GUARDIAN_ROLE`, `ATOMIST_ROLE`, `OWNER_ROLE`
- **Cannot do**:
  - Directly manage Alpha, Whitelist, or FuseManager roles (those are under Atomist)
  - Execute strategies or interact with vault funds

#### Guardian (Tesseract Guardian Multisig)

- **Purpose**: AML compliance — freeze vaults when suspicious activity is detected.
- **Can do**:
  - Pause the vault (disable deposits/withdrawals)
  - Cancel scheduled operations
- **Cannot do**:
  - Grant or revoke any roles
  - Execute strategies or move funds
- **Configuration**: Operates with delay = 0 (no timelocks) for immediate action.

#### Atomist (Tesseract DCV Provisioner)

- **Purpose**: Vault provisioning and configuration. The operational admin of the vault.
- **Can do**:
  - Add/remove fuses via `addFuses()` (with `FUSE_MANAGER_ROLE`, granted automatically)
  - Add balance fuses via `addBalanceFuse()`
  - Set market substrates via `grantMarketSubstrates()`
  - Configure price oracle middleware
  - Set management and performance fees
  - Update dependency balance graphs
  - Grant/revoke: `ALPHA_ROLE`, `WHITELIST_ROLE`, `FUSE_MANAGER_ROLE`, and all other operational roles
- **Cannot do**:
  - Grant Owner or Guardian roles
  - Override vault pause set by Guardian

#### Alpha (DCV Manager)

- **Purpose**: Active fund management — executes investment strategies.
- **Can do**:
  - Call `execute()` on the PlasmaVault to allocate/reallocate funds across markets
- **Cannot do**:
  - Add or remove fuses
  - Grant any roles
  - Deposit or withdraw (unless also whitelisted)

#### Whitelist (User / Deployer)

- **Purpose**: Deposit and withdrawal access to the private vault.
- **Can do**:
  - `deposit()` / `mint()` — add funds to the vault
  - `withdraw()` / `redeem()` — remove funds from the vault
- **Cannot do**:
  - Execute strategies
  - Configure vault parameters
  - Grant any roles

## Vault Creation Methods

### `createVault(CreateVaultInput calldata input)`

Direct vault creation. The caller must have `VAULT_CREATOR_ROLE`.

```solidity
FusionFactoryWrapper.CreateVaultInput memory input = FusionFactoryWrapper.CreateVaultInput({
    assetName: "My DCV Vault",
    assetSymbol: "mDCV",
    underlyingToken: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
    redemptionDelayInSeconds: 0,
    daoFeePackageIndex: 0,
    owner: 0x...,     // Tesseract Admin Multisig
    guardian: 0x...,   // Tesseract Guardian Multisig (or address(0) to skip)
    atomist: 0x...,    // Tesseract DCV Provisioner
    alpha: 0x...,      // DCV Manager
    whitelist: 0x...   // User who requested the vault
});

FusionFactoryLogicLib.FusionInstance memory instance = wrapper.createVault(input);
// instance.plasmaVault   — the vault address
// instance.accessManager — the AccessManager address
```

### `createVaultSigned(CreateVaultInput calldata input, uint8 v, bytes32 r, bytes32 s)`

Vault creation with EIP-712 signature verification. The whitelist user signs the vault parameters off-chain, proving they consent to the vault creation with the specified configuration. The caller must still have `VAULT_CREATOR_ROLE`.

This prevents a scenario where someone creates a vault on behalf of a user without their knowledge.

## Internal Vault Creation Flow

When `createVault()` or `createVaultSigned()` is called, the following happens atomically:

```
Step 1: Clone vault with wrapper as temporary OWNER
        └── FusionFactory.clone(..., address(this), ...)
        └── Wrapper receives OWNER_ROLE on the new vault

Step 2: Grant GUARDIAN_ROLE → guardian address (if not zero)
        └── Wrapper can do this because it holds OWNER_ROLE

Step 3: Grant temporary ATOMIST_ROLE → wrapper itself
        └── Wrapper can do this because OWNER manages ATOMIST

Step 4: Grant ATOMIST-managed roles:
        ├── ALPHA_ROLE → alpha address
        ├── WHITELIST_ROLE → whitelist address
        └── FUSE_MANAGER_ROLE → atomist address

Step 5: Grant ATOMIST_ROLE → real atomist address

Step 6: Renounce ATOMIST_ROLE from wrapper

Step 7: Grant OWNER_ROLE → real owner address

Step 8: Renounce OWNER_ROLE from wrapper
        └── Wrapper has NO roles on the vault after this step
```

After completion, the wrapper retains **zero privileges** on the created vault.

## Created Vault Properties

| Property | Value |
|----------|-------|
| Type | Private (whitelist-only) |
| ERC standard | ERC-4626 (tokenized vault) |
| Timelocks | None (delay = 0 on all roles) |
| Wrapper residual access | None (all roles renounced) |

## Post-Deployment: What Atomist Must Do

After vault creation, the Atomist (DCV Provisioner) must configure the vault:

1. **Add fuses** — `addFuses(address[])` for each protocol integration
2. **Add balance fuses** — `addBalanceFuse(uint256 marketId, address fuse)` per market
3. **Set market substrates** — `grantMarketSubstrates(uint256 marketId, bytes32[] substrates)` (allowed assets per market)
4. **Configure price oracle** — set the price oracle middleware address
5. **Set fees** — management fee and performance fee
6. **Configure dependency graph** — `updateDependencyBalanceGraphs()`
7. **Add more whitelist users** — `grantRole(WHITELIST_ROLE, user, 0)` as needed

## Deployment

### Prerequisites

- Foundry installed
- `ETHEREUM_PROVIDER_URL` set in `.env`
- Access to the deployer private key or hardware wallet

### Deploy

```bash
# Dry run (simulation)
WRAPPER_ADMIN=<admin-multisig> \
VAULT_CREATOR=<provisioner-address> \
forge script script/DeployFusionFactoryWrapper.s.sol \
  --rpc-url $ETHEREUM_PROVIDER_URL \
  --sender <deployer-address>

# Real deployment with verification
WRAPPER_ADMIN=<admin-multisig> \
VAULT_CREATOR=<provisioner-address> \
forge script script/DeployFusionFactoryWrapper.s.sol \
  --rpc-url $ETHEREUM_PROVIDER_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --private-key $DEPLOYER_PRIVATE_KEY
```

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `WRAPPER_ADMIN` | Yes | Address receiving `DEFAULT_ADMIN_ROLE` on the wrapper |
| `VAULT_CREATOR` | No | Address receiving `VAULT_CREATOR_ROLE` (can be granted later) |
| `FUSION_FACTORY_PROXY` | No | FusionFactory proxy address (default: `0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852`) |

## Security Considerations

- **Wrapper has no residual access** — after each vault creation, the wrapper renounces both `OWNER_ROLE` and `ATOMIST_ROLE`. It cannot interfere with any vault it created.
- **Zero-address validation** — owner, atomist, alpha, and whitelist addresses are validated. Guardian is optional (`address(0)` skips assignment).
- **VAULT_CREATOR_ROLE gate** — only authorized addresses can create vaults, preventing spam or unauthorized deployments.
- **EIP-712 signed variant** — `createVaultSigned()` requires the whitelist user's signature, ensuring they consent to the vault parameters before creation.
- **No timelocks** — all roles are granted with `delay = 0` for immediate operational readiness. This is intentional for the Tesseract DCV use case where Guardian needs instant freeze capability.
