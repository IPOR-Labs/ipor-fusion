// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IPlasmaVaultBase} from "../interfaces/IPlasmaVaultBase.sol";
import {Errors} from "../libraries/errors/Errors.sol";
import {PlasmaVaultGovernance} from "./PlasmaVaultGovernance.sol";
import {ERC20VotesUpgradeable} from "./ERC20VotesUpgradeable.sol";
import {PlasmaVaultLib} from "../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";
import {ContextClient} from "../managers/context/ContextClient.sol";
import {PreHooksHandler} from "../pre_hooks_handlers/PreHooksHandler.sol";
/**
 * @title PlasmaVaultBase - Core Extension for PlasmaVault Token Functionality
 * @notice Stateless extension providing ERC20 Votes and Permit capabilities for PlasmaVault
 * @dev Designed to be used exclusively through delegatecall from PlasmaVault
 *
 * Core Features:
 * - ERC20 Token Implementation
 * - Governance Voting Support
 * - Permit Functionality
 * - Supply Cap Management
 * - Access Control Integration
 *
 * Token Features:
 * - ERC20 Standard Compliance
 * - Voting Power Delegation
 * - Gasless Approvals (Permit)
 * - Supply Cap Enforcement
 * - Upgradeable Design
 *
 * Security Aspects:
 * - Delegatecall-only Operations
 * - Access Control Integration
 * - Supply Cap Validation
 * - Nonce Management
 * - Context Preservation
 *
 * Integration Points:
 * - PlasmaVault: Main Vault Contract
 * - Access Manager: Permission Control
 * - Context System: Message Sender Management
 * - Storage Libraries: State Management
 *
 * Inheritance Structure:
 * - IPlasmaVaultBase: Interface Definition
 * - ERC20PermitUpgradeable: Permit Functionality
 * - ERC20VotesUpgradeable: Voting Capabilities
 * - PlasmaVaultGovernance: Governance Features
 * - ContextClient: Context Management
 *
 * Error Handling:
 * - ERC20ExceededCap: Supply Cap Violations
 * - ERC20InvalidCap: Invalid Cap Configuration
 * - Standard OpenZeppelin Errors
 *
 * @custom:security-contact security@ipor.network
 */
contract PlasmaVaultBase is
    IPlasmaVaultBase,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    PlasmaVaultGovernance,
    ContextClient,
    PreHooksHandler
{
    /**
     * @dev Total supply cap has been exceeded.
     */
    error ERC20ExceededCap(uint256 increasedSupply, uint256 cap);

    /**
     * @dev The supplied cap is not a valid cap.
     */
    error ERC20InvalidCap(uint256 cap);

    /// @notice Initializes the PlasmaVaultBase contract
    /// @param assetName_ The name of the asset
    /// @param accessManager_ The address of the access manager contract
    /// @param totalSupplyCap_ The maximum total supply cap for the vault
    /// @dev Validates access manager address and total supply cap
    /// @custom:access Only during initialization
    function init(
        string memory assetName_,
        address accessManager_,
        uint256 totalSupplyCap_
    ) external override initializer {
        if (accessManager_ == address(0)) {
            revert Errors.WrongAddress();
        }

        super.__ERC20Votes_init();
        super.__ERC20Permit_init(assetName_);
        super.__AccessManaged_init(accessManager_);
        __init(totalSupplyCap_);
    }

    function __init(uint256 cap_) internal onlyInitializing {
        // solhint-disable-previous-line func-name-mixedcase
        PlasmaVaultStorageLib.ERC20CappedStorage storage $ = PlasmaVaultStorageLib.getERC20CappedStorage();
        if (cap_ == 0) {
            revert ERC20InvalidCap(0);
        }
        $.cap = cap_;
    }

    /// @notice Gets the maximum total supply cap for the vault
    /// @dev Retrieves the configured supply cap from ERC20CappedStorage
    ///
    /// Supply Cap System:
    /// - Enforces maximum vault size limit
    /// - Stored in underlying asset decimals
    /// - Critical for deposit control
    /// - Part of risk management
    ///
    /// Storage Pattern:
    /// - Uses PlasmaVaultStorageLib.ERC20CappedStorage
    /// - Single value storage slot
    /// - Set during initialization
    /// - Modifiable by governance
    ///
    /// Integration Context:
    /// - Used during minting operations
    /// - Referenced in deposit validation
    /// - Part of supply control system
    /// - Critical for vault scaling
    ///
    /// Use Cases:
    /// - Deposit limit validation
    /// - Share minting control
    /// - TVL management
    /// - Risk parameter monitoring
    ///
    /// Related Components:
    /// - ERC20 Implementation
    /// - Supply Control System
    /// - Deposit Validation
    /// - Risk Management
    ///
    /// @return uint256 The maximum total supply cap in underlying asset decimals
    /// @custom:access Public view
    /// @custom:security Non-privileged view function
    function cap() public view virtual returns (uint256) {
        return PlasmaVaultStorageLib.getERC20CappedStorage().cap;
    }

    /// @notice Updates token balances and voting power during transfers
    /// @dev Can only be executed via delegatecall from PlasmaVault
    ///
    /// Execution Context:
    /// - Called through PlasmaVault._update()
    /// - Uses delegatecall for storage access
    /// - Maintains PlasmaVault context
    /// - Critical for token operations
    ///
    /// Operation Flow:
    /// - Updates token balances
    /// - Validates supply cap
    /// - Updates voting power
    /// - Maintains ERC20 state
    ///
    /// Integration Points:
    /// - ERC20 balance updates
    /// - Voting power tracking
    /// - Supply cap validation
    /// - Transfer hooks
    ///
    /// Security Considerations:
    /// - Delegatecall only
    /// - Preserves vault context
    /// - Maintains state consistency
    /// - Critical for token integrity
    ///
    /// Related Components:
    /// - ERC20VotesUpgradeable
    /// - Supply Cap System
    /// - Token Operations
    /// - Voting Mechanism
    ///
    /// @param from_ Source address for the transfer
    /// @param to_ Destination address for the transfer
    /// @param value_ Amount of tokens to transfer
    /// @custom:access External, but only through delegatecall
    /// @custom:security Critical for token operations
    function updateInternal(address from_, address to_, uint256 value_) external override {
        _update(from_, to_, value_);
    }

    /// @notice Gets the current nonce for an address
    /// @dev Overrides both ERC20PermitUpgradeable and NoncesUpgradeable implementations
    ///
    /// Nonce System:
    /// - Tracks permit usage per address
    /// - Prevents replay attacks
    /// - Critical for permit operations
    /// - Maintains signature uniqueness
    ///
    /// Integration Context:
    /// - Used in permit operations
    /// - Part of ERC20Permit functionality
    /// - Supports gasless approvals
    /// - Enables meta-transactions
    ///
    /// Security Features:
    /// - Sequential nonce tracking
    /// - Signature validation
    /// - Replay protection
    /// - Transaction ordering
    ///
    /// Use Cases:
    /// - Permit signature validation
    /// - Gasless token approvals
    /// - Meta-transaction processing
    /// - Signature replay prevention
    ///
    /// Related Components:
    /// - ERC20Permit Implementation
    /// - Signature Validation
    /// - Meta-transaction System
    /// - Security Framework
    ///
    /// @param owner_ The address to query the nonce for
    /// @return uint256 The current nonce for the address
    /// @custom:access Public view
    /// @custom:security Critical for permit operations
    function nonces(address owner_) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner_);
    }

    /// @dev Notice! Can be executed only by Plasma Vault in delegatecall.
    /// Combines the logic required for ERC20VotesUpgradeable and ERC20VotesUpgradeable
    function _update(address from_, address to_, uint256 value_) internal virtual override {
        super._update(from_, to_, value_);

        /// @dev total supply cap validation is disabled when performance and management fee is minted
        if (PlasmaVaultLib.isTotalSupplyCapValidationEnabled()) {
            /// @dev check total supply cap
            if (from_ == address(0)) {
                uint256 maxSupply = cap();
                uint256 supply = totalSupply();
                if (supply > maxSupply) {
                    revert ERC20ExceededCap(supply, maxSupply);
                }
            }
        }

        _transferVotingUnits(from_, to_, value_);
    }

    /// @notice Internal function to get the message sender from context
    /// @return The address of the message sender
    function _msgSender() internal view override returns (address) {
        return _getSenderFromContext();
    }

    function _checkCanCall(address caller_, bytes calldata data_) internal override {
        super._checkCanCall(caller_, data_);
        _runPreHooks(bytes4(data_[0:4]));
    }
}
