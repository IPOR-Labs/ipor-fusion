# PlasmaVault Architecture

## Overview

PlasmaVault uses a **modular delegatecall-based architecture** to achieve:
- **Contract size optimization** - staying under the 24KB limit
- **Separation of concerns** - each component has a single responsibility
- **Extensibility** - optional plugins can be added without modifying core contracts
- **Gas efficiency** - vaults only pay for features they use

## Component Diagram

```
                                    ┌─────────────────────────┐
                                    │      PlasmaVault        │
                                    │    (Main Entry Point)   │
                                    │                         │
                                    │  - ERC4626 core logic   │
                                    │  - Deposit/Withdraw     │
                                    │  - Fuse execution       │
                                    │  - Fallback router      │
                                    └───────────┬─────────────┘
                                                │
                          ┌─────────────────────┼─────────────────────┐
                          │                     │                     │
                          ▼                     ▼                     ▼
               ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
               │ PlasmaVaultBase  │  │PlasmaVaultErc4626│  │    Plugins       │
               │                  │  │      View        │  │                  │
               │ - ERC20 logic    │  │                  │  │ - VotesPlugin    │
               │ - ERC20Permit    │  │ - previewDeposit │  │ - Future plugins │
               │ - Supply cap     │  │ - previewMint    │  │                  │
               │ - Voting units   │  │ - previewRedeem  │  │                  │
               │   propagation    │  │ - maxDeposit     │  │                  │
               │                  │  │ - maxMint, etc.  │  │                  │
               └──────────────────┘  └──────────────────┘  └──────────────────┘
```

## Components

### PlasmaVault (Main Contract)

**Location:** `PlasmaVault.sol`

The main entry point and orchestrator. Contains:
- ERC4626 vault implementation (deposit, mint, withdraw, redeem)
- Fuse action execution system
- Fee management integration
- Fallback router that delegates calls to appropriate components

**Key mechanism - Fallback Router:**
```solidity
fallback(bytes calldata) external returns (bytes memory) {
    bytes4 sig = msg.sig;

    // Route ERC4626 view functions
    if (_isERC4626ViewFunction(sig)) {
        return erc4626.functionDelegateCall(msg.data);
    }

    // Route Votes functions to plugin
    if (_isVotesFunction(sig)) {
        return votesPlugin.functionDelegateCall(msg.data);
    }

    // Default: route to PlasmaVaultBase
    return PLASMA_VAULT_BASE().functionDelegateCall(msg.data);
}
```

### PlasmaVaultBase

**Location:** `PlasmaVaultBase.sol`

Core ERC20 functionality that was extracted to reduce PlasmaVault size:
- ERC20 token operations (transfer, approve, etc.)
- ERC20Permit (gasless approvals)
- Total supply cap enforcement
- Voting units propagation to VotesPlugin during transfers

**Storage:** Uses PlasmaVault's storage via delegatecall context.

### Plugins (Optional Components)

**Location:** `plugins/`

Plugins provide optional functionality that not all vaults need. They:
- Are called via delegatecall from PlasmaVault
- Share storage with PlasmaVault (ERC-7201 namespaced storage)
- Can be enabled/disabled per vault instance

#### PlasmaVaultVotesPlugin

**Location:** `plugins/PlasmaVaultVotesPlugin.sol`

Provides ERC20Votes (governance) functionality:
- Vote delegation (`delegate`, `delegateBySig`)
- Voting power queries (`getVotes`, `getPastVotes`)
- Checkpointing for historical voting power
- IERC5805 / IERC6372 compliance

**Gas optimization:** Vaults without this plugin save ~2,800-9,800 gas per transfer (no checkpoint updates).

## Storage Architecture

All components share storage through **ERC-7201 namespaced storage pattern**:

```
PlasmaVault Storage Layout (shared via delegatecall)
├── ERC20Storage (balances, allowances)
├── ERC4626Storage (underlying asset)
├── VotesStorage (delegatees, checkpoints) - used by VotesPlugin
├── NoncesStorage (permit nonces) - shared by Permit and VotesPlugin
├── EIP712Storage (domain separator)
├── PlasmaVault-specific storage slots
│   ├── PlasmaVaultBase address
│   ├── PlasmaVaultERC4626 address
│   ├── PlasmaVaultVotesPlugin address
│   └── ... other configuration
```

## Initialization

During vault creation, addresses of all components are provided:

```solidity
struct PlasmaVaultInitData {
    // ... other fields
    address plasmaVaultBase;         // Required
    address plasmaVaultERC4626;      // Optional (address(0) to disable)
    address plasmaVaultVotesPlugin;  // Optional (address(0) to disable)
}
```

## Call Flow Examples

### Deposit (PlasmaVault directly)
```
User → PlasmaVault.deposit() → [internal logic] → shares minted
```

### Transfer (routed to PlasmaVaultBase)
```
User → PlasmaVault.transfer()
     → fallback()
     → PlasmaVaultBase.functionDelegateCall()
     → [if VotesPlugin enabled] VotesPlugin.transferVotingUnits()
```

### Preview Deposit (direct in PlasmaVault)
```
User → PlasmaVault.previewDeposit()
     → (handled directly, no fallback routing)
```

### Delegate Votes (routed to VotesPlugin)
```
User → PlasmaVault.delegate()
     → fallback()
     → _isVotesFunction() = true
     → PlasmaVaultVotesPlugin.functionDelegateCall()
```

## Creating New Plugins

To create a new plugin:

1. **Create the plugin contract** in `plugins/` directory
2. **Use ERC-7201 namespaced storage** that doesn't conflict with existing slots
3. **Create an interface** in `interfaces/`
4. **Add routing logic** in PlasmaVault's fallback function
5. **Add storage slot** for plugin address in PlasmaVaultStorageLib
6. **Update PlasmaVaultInitData** struct if plugin is configured at init time

Example plugin structure:
```solidity
// plugins/PlasmaVaultMyPlugin.sol
contract PlasmaVaultMyPlugin is IPlasmaVaultMyPlugin {
    // Use unique ERC-7201 storage slot
    bytes32 private constant MY_STORAGE_LOCATION =
        0x...; // keccak256("io.ipor.fusion.MyPlugin")

    struct MyStorage {
        // plugin-specific state
    }

    function _getMyStorage() private pure returns (MyStorage storage $) {
        assembly { $.slot := MY_STORAGE_LOCATION }
    }

    // Plugin functions...
}
```

## Benefits of This Architecture

1. **Contract Size Management**
   - PlasmaVault stays under 24KB limit
   - New features added as plugins without bloating main contract

2. **Gas Efficiency**
   - Vaults only pay for features they use
   - No voting overhead for non-governance vaults

3. **Upgradability**
   - Plugins can be upgraded independently
   - New plugins can be added to existing vault deployments

4. **Security**
   - Clear separation of concerns
   - Each component can be audited independently
   - Storage isolation via ERC-7201 namespacing
