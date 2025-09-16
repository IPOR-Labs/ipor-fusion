// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {ContextManagerStorageLib} from "./ContextManagerStorageLib.sol";
import {IContextClient} from "./IContextClient.sol";

/**
 * @title ContextManager
 * @notice Manages execution context and permissions for vault operations with signature-based authentication
 * @dev This contract implements a secure context management system that enables:
 * - Batch execution of calls to approved addresses
 * - Signature-based execution with sender impersonation
 * - Management of approved addresses with access control
 *
 * Security features:
 * - Nonce-based replay attack prevention
 * - Signature expiration timestamps
 * - Chain ID verification
 * - Approved address whitelist
 * - Role-based access control via AccessManagedUpgradeable
 *
 * Role-based permissions:
 * - ATOMIST_ROLE: Can add/remove approved addresses and manage context configuration
 * - TECH_CONTEXT_MANAGER_ROLE: Technical role for context setup/cleanup operations
 * - PUBLIC_ROLE: No special permissions, can only interact with public functions
 *
 * Function permissions:
 * - addApprovedAddresses: Restricted to ATOMIST_ROLE
 * - removeApprovedAddresses: Restricted to ATOMIST_ROLE
 * - setupContext: Restricted to TECH_CONTEXT_MANAGER_ROLE
 * - clearContext: Restricted to TECH_CONTEXT_MANAGER_ROLE
 *
 * Key components:
 * - ExecuteData: Structure for batch execution
 * - ContextDataWithSender: Structure for signature-verified execution
 * - Storage management via ContextManagerStorageLib
 * - Integration with IContextClient for context setup/cleanup
 */

/**
 * @title ExecuteData
 * @notice Structure for batch execution data
 * @param targets Array of approved contract addresses to be called
 * @param datas Array of calldata corresponding to each target
 * @dev Both arrays must be non-empty and of equal length
 */
struct ExecuteData {
    address[] targets;
    bytes[] datas;
}

/**
 * @title ContextDataWithSender
 * @notice Structure for signature-verified execution context
 * @param sender The original transaction sender to be impersonated
 * @param expirationTime Unix timestamp after which the signature becomes invalid
 * @param nonce Sequential number for replay attack prevention
 * @param target The approved contract address to be called
 * @param data The calldata to be executed on the target
 * @param signature EIP-712 compatible signature of (expirationTime, nonce, chainId, target, data)
 * @dev Signature is verified using ECDSA recovery to match the sender
 */
struct ContextDataWithSender {
    address sender;
    uint256 expirationTime;
    uint256 nonce;
    address target;
    bytes data;
    /// @notice signature of data (uint256:expirationTime, uint256:nonce, uint256:chainId, address:target, bytes:data)
    bytes signature;
}

/**
 * @title ContextManager
 * @notice Manages execution context and permissions for vault operations
 * @dev This contract implements a secure context management system with signature verification
 * and access control for DeFi vault operations
 *
 * Security considerations:
 * - Uses nonces to prevent replay attacks
 * - Implements signature expiration to limit the validity window of signed messages
 * - Maintains an approved address list for additional security
 * - Inherits AccessManagedUpgradeable for role-based access control
 *
 * The contract allows for:
 * 1. Batch execution of calls to approved addresses
 * 2. Signature-based execution with sender impersonation
 * 3. Management of approved addresses
 */
contract ContextManager is AccessManagedUpgradeable {
    using Address for address;

    /// @notice Emitted when an address is added to approved list
    event TargetApproved(address indexed target);

    /// @notice Emitted when an address is removed from approved list
    event TargetRemoved(address indexed target);

    /// @notice Emitted when a call is executed within context
    event ContextCall(address indexed target, bytes data, bytes result);

    /// @notice Custom errors for better gas efficiency and clarity
    error TargetNotApproved(address target);
    error LengthMismatch();
    error EmptyArrayNotAllowed();
    error InvalidAuthority();
    error SignatureExpired();
    error InvalidSignature();
    error NonceTooLow();

    /// @notice Chain ID used for signature verification
    uint256 public immutable CHAIN_ID;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address initialAuthority_, address[] memory approvedTargets_) initializer {
        CHAIN_ID = block.chainid;
        _initialize(initialAuthority_, approvedTargets_);
    }

    /// @notice Initializes the ContextManager with access manager and approved targets (for cloning)
    /// @param initialAuthority_ The address of the access control manager
    /// @param approvedTargets_ Array of initially approved targets
    /// @dev This method is called after cloning to initialize the contract
    function proxyInitialize(address initialAuthority_, address[] memory approvedTargets_) external initializer {
        _initialize(initialAuthority_, approvedTargets_);
    }

    function _initialize(address initialAuthority_, address[] memory approvedTargets_) private {
        if (initialAuthority_ == address(0)) {
            revert InvalidAuthority();
        }

        uint256 length = approvedTargets_.length;

        if (length == 0) {
            revert EmptyArrayNotAllowed();
        }

        super.__AccessManaged_init_unchained(initialAuthority_);

        for (uint256 i; i < length; ++i) {
            if (approvedTargets_[i] == address(0)) {
                revert InvalidAuthority();
            }

            ContextManagerStorageLib.addApprovedTarget(approvedTargets_[i]);
        }
    }
    /**
     * @notice Gets the current nonce for a specific address
     * @param sender_ The sender to get the nonce for
     * @return Current nonce value for the sender
     */
    function getNonce(address sender_) external view returns (uint256) {
        return ContextManagerStorageLib.getNonce(sender_);
    }

    /**
     * @notice Checks if an address is approved
     * @param target_ Target to check
     * @return bool True if target is approved
     */
    function isTargetApproved(address target_) external view returns (bool) {
        return ContextManagerStorageLib.isTargetApproved(target_);
    }

    /**
     * @notice Returns the list of all approved targets
     * @return Array of approved targets
     */
    function getApprovedTargets() external view returns (address[] memory) {
        return ContextManagerStorageLib.getApprovedTargets();
    }

    /**
     * @notice Adds multiple targets to the approved targets list
     * @param targets_ Array of targets to be approved
     * @return approvedCount Number of newly approved targets
     * @dev Only callable by restricted roles
     * @custom:security Validates targets and prevents zero address additions
     * @custom:access Restricted to ATOMIST_ROLE
     */
    function addApprovedTargets(address[] calldata targets_) external restricted returns (uint256 approvedCount) {
        uint256 length = targets_.length;

        if (length == 0) {
            revert EmptyArrayNotAllowed();
        }

        for (uint256 i; i < length; ++i) {
            if (targets_[i] == address(0)) {
                revert InvalidAuthority();
            }

            if (ContextManagerStorageLib.addApprovedTarget(targets_[i])) {
                unchecked {
                    ++approvedCount;
                }
            }
        }
    }

    /**
     * @notice Removes multiple targets from the approved targets list
     * @param targets_ Array of targets to be removed
     * @return removedCount Number of targets actually removed
     * @dev Only callable by restricted roles
     * @custom:access Restricted to ATOMIST_ROLE
     */
    function removeApprovedTargets(address[] calldata targets_) external restricted returns (uint256 removedCount) {
        uint256 length = targets_.length;

        for (uint256 i; i < length; ++i) {
            if (ContextManagerStorageLib.removeApprovedTarget(targets_[i])) {
                unchecked {
                    ++removedCount;
                }
            }
        }
    }

    /**
     * @notice Executes multiple calls to approved targets within a managed context
     * @param executeData_ Struct containing arrays of target addresses and call data
     * @return results Array of bytes containing the results of each call
     * @dev Requirements:
     * - All target addresses must be pre-approved
     * - Arrays must be non-empty and of equal length
     * - Zero addresses are not allowed
     * - For each call:
     *   1. Sets up context with original sender
     *   2. Executes the call
     *   3. Clears the context
     * @custom:security Ensures proper context isolation between calls
     * @custom:access No role restrictions - callable by anyone
     */
    function runWithContext(ExecuteData calldata executeData_) external returns (bytes[] memory results) {
        uint256 length = executeData_.targets.length;

        if (length == 0) {
            revert EmptyArrayNotAllowed();
        }

        if (executeData_.datas.length != length) {
            revert LengthMismatch();
        }

        results = new bytes[](length);

        for (uint256 i; i < length; ++i) {
            address target = executeData_.targets[i];

            if (target == address(0)) {
                revert InvalidAuthority();
            }

            results[i] = _executeWithinContext(target, msg.sender, executeData_.datas[i]);
        }
    }

    /**
     * @notice Executes multiple calls with signature verification and sender impersonation
     * @param contextDataArray_ Array of context data containing signatures
     * @return results Array of bytes containing the results of each call
     * @dev Requirements:
     * - Signatures must not be expired (block.timestamp <= expirationTime)
     * - Signatures must be valid and match the claimed sender
     * - Nonces must be sequential and not reused
     * - Target addresses must be pre-approved
     * - Array must not be empty
     * - For each call:
     *   1. Verifies signature and nonce
     *   2. Sets up context with impersonated sender
     *   3. Executes the call
     *   4. Clears the context
     * @custom:security Implements multiple security checks for signature-based execution
     * @custom:access No role restrictions - callable by anyone with valid signatures
     */
    function runWithContextAndSignature(
        ContextDataWithSender[] calldata contextDataArray_
    ) external returns (bytes[] memory results) {
        uint256 length = contextDataArray_.length;

        if (length == 0) {
            revert EmptyArrayNotAllowed();
        }

        results = new bytes[](length);

        ContextDataWithSender calldata contextData;

        for (uint256 i; i < length; ++i) {
            contextData = contextDataArray_[i];

            if (block.timestamp > contextData.expirationTime) {
                revert SignatureExpired();
            }

            if (!_verifySignature(contextData)) {
                revert InvalidSignature();
            }

            ContextManagerStorageLib.verifyAndUpdateNonce(contextData.sender, contextData.nonce);

            results[i] = _executeWithinContext(contextData.target, contextData.sender, contextData.data);
        }
    }

    /**
     * @notice Executes a single call within context after verifying target approval
     * @param target_ The contract address to call
     * @param sender_ The sender address to set in context
     * @param data_ The calldata to execute
     * @return bytes The result of the execution
     * @dev Requirements:
     * - Target must be an approved address
     * - Context must be set up before and cleared after execution
     * @custom:security Ensures proper context setup and cleanup
     * @custom:access Internal function - access controlled by public functions
     */
    function _executeWithinContext(
        address target_,
        address sender_,
        bytes calldata data_
    ) private returns (bytes memory) {
        if (!ContextManagerStorageLib.isTargetApproved(target_)) {
            revert TargetNotApproved(target_);
        }

        IContextClient(target_).setupContext(sender_);

        bytes memory result = target_.functionCall(data_);

        IContextClient(target_).clearContext();

        emit ContextCall(target_, data_, result);

        return result;
    }

    /**
     * @notice Verifies the signature of context data using ECDSA recovery
     * @param contextData_ The context data containing the signature to verify
     * @return bool True if the recovered signer matches the claimed sender
     * @dev Creates a hash of (contextManagerAddress, expirationTime, nonce, chainId, target, data)
     * and verifies that the signature's recovered address matches the sender
     * @custom:security Uses ECDSA.recover for signature verification
     */
    function _verifySignature(ContextDataWithSender memory contextData_) internal view returns (bool) {
        return
            ECDSA.recover(
                keccak256(
                    abi.encodePacked(
                        address(this),
                        contextData_.expirationTime,
                        contextData_.nonce,
                        CHAIN_ID,
                        contextData_.target,
                        contextData_.data
                    )
                ),
                contextData_.signature
            ) == contextData_.sender;
    }
}
