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
    event AddressApproved(address indexed addr);

    /// @notice Emitted when an address is removed from approved list
    event AddressRemoved(address indexed addr);

    /// @notice Emitted when a call is executed within context
    event ContextCall(address indexed target, bytes data, bytes result);

    /// @notice Custom errors for better gas efficiency and clarity
    error AddressNotApproved(address addr);
    error LengthMismatch();
    error EmptyArrayNotAllowed();
    error InvalidAuthority();
    error SignatureExpired();
    error InvalidSignature();
    error NonceTooLow();

    /// @notice Chain ID used for signature verification
    uint256 public immutable CHAIN_ID;

    /**
     * @notice Initializes the ContextManager with initial authority and approved addresses
     * @param initialAuthority Address of the initial authority for access control
     * @param approvedAddresses Array of initially approved addresses
     * @dev Sets up access control and approved addresses list
     * @custom:security Validates initial authority and approved addresses
     */
    constructor(address initialAuthority, address[] memory approvedAddresses) initializer {
        if (initialAuthority == address(0)) {
            revert InvalidAuthority();
        }

        // Validate approved addresses
        uint256 length = approvedAddresses.length;
        if (length == 0) {
            revert EmptyArrayNotAllowed();
        }

        super.__AccessManaged_init_unchained(initialAuthority);

        // Add approved addresses
        for (uint256 i; i < length; ++i) {
            // Validate each address
            if (approvedAddresses[i] == address(0)) {
                revert InvalidAuthority();
            }

            ContextManagerStorageLib.addApprovedAddress(approvedAddresses[i]);
        }

        CHAIN_ID = block.chainid;
    }

    /**
     * @notice Adds multiple addresses to the approved addresses list
     * @param addrs Array of addresses to be approved
     * @return approvedCount Number of newly approved addresses
     * @dev Only callable by restricted roles
     * @custom:security Validates addresses and prevents zero address additions
     */
    function addApprovedAddresses(address[] calldata addrs) external restricted returns (uint256 approvedCount) {
        uint256 length = addrs.length;
        if (length == 0) {
            revert EmptyArrayNotAllowed();
        }

        for (uint256 i; i < length; ++i) {
            // Validate address
            if (addrs[i] == address(0)) {
                revert InvalidAuthority();
            }

            // addApprovedAddress returns true only if address was newly added
            if (ContextManagerStorageLib.addApprovedAddress(addrs[i])) {
                unchecked {
                    ++approvedCount;
                }
            }
        }
    }

    /**
     * @notice Removes multiple addresses from the approved addresses list
     * @param addrs Array of addresses to be removed
     * @return removedCount Number of addresses actually removed
     * @dev Only callable by restricted roles
     */
    function removeApprovedAddresses(address[] calldata addrs) external restricted returns (uint256 removedCount) {
        uint256 length = addrs.length;
        for (uint256 i; i < length; ++i) {
            if (ContextManagerStorageLib.removeApprovedAddress(addrs[i])) {
                unchecked {
                    ++removedCount;
                }
            }
        }
    }

    /**
     * @notice Executes multiple calls to approved addresses within a managed context
     * @param executeData Struct containing arrays of target addresses and call data
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
     */
    function runWithContext(ExecuteData calldata executeData) external returns (bytes[] memory results) {
        uint256 length = executeData.targets.length;

        // Validate array lengths and non-empty arrays
        if (length == 0) {
            revert EmptyArrayNotAllowed();
        }

        if (executeData.datas.length != length) {
            revert LengthMismatch();
        }

        results = new bytes[](length);

        for (uint256 i; i < length; ++i) {
            address target = executeData.targets[i];

            // Validate target address
            if (target == address(0)) {
                revert InvalidAuthority();
            }

            // Execute within context
            results[i] = _executeWithinContext(target, msg.sender, executeData.datas[i]);
        }
    }

    /**
     * @notice Executes multiple calls with signature verification and sender impersonation
     * @param contextDataArray Array of context data containing signatures
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
     */
    function runWithContextAndSignature(
        ContextDataWithSender[] calldata contextDataArray
    ) external returns (bytes[] memory results) {
        uint256 length = contextDataArray.length;

        // Validate non-empty array
        if (length == 0) {
            revert EmptyArrayNotAllowed();
        }

        results = new bytes[](length);

        ContextDataWithSender calldata contextData;
        for (uint256 i; i < length; ++i) {
            contextData = contextDataArray[i];

            // Check if signature has expired
            if (block.timestamp > contextData.expirationTime) {
                revert SignatureExpired();
            }

            // Verify signature
            if (!_verifySignature(contextData)) {
                revert InvalidSignature();
            }

            // Verify and update nonce
            ContextManagerStorageLib.verifyAndUpdateNonce(contextData.sender, contextData.nonce);

            // Execute within context
            results[i] = _executeWithinContext(contextData.target, contextData.sender, contextData.data);
        }
    }

    /**
     * @notice Checks if an address is approved
     * @param addr Address to check
     * @return bool True if address is approved
     */
    function isApproved(address addr) external view returns (bool) {
        return ContextManagerStorageLib.isApproved(addr);
    }

    /**
     * @notice Returns the list of all approved addresses
     * @return Array of approved addresses
     */
    function getApprovedAddresses() external view returns (address[] memory) {
        return ContextManagerStorageLib.getApprovedAddresses();
    }

    /**
     * @notice Verifies the signature of context data using ECDSA recovery
     * @param contextData The context data containing the signature to verify
     * @return bool True if the recovered signer matches the claimed sender
     * @dev Creates a hash of (expirationTime, nonce, chainId, target, data)
     * and verifies that the signature's recovered address matches the sender
     * @custom:security Uses ECDSA.recover for signature verification
     */
    function _verifySignature(ContextDataWithSender memory contextData) internal view returns (bool) {
        return
            ECDSA.recover(
                keccak256(
                    abi.encodePacked(
                        contextData.expirationTime,
                        contextData.nonce,
                        CHAIN_ID,
                        contextData.target,
                        contextData.data
                    )
                ),
                contextData.signature
            ) == contextData.sender;
    }

    /**
     * @notice Gets the current nonce for a specific address
     * @param addr The address to get the nonce for
     * @return Current nonce value for the address
     */
    function getNonce(address addr) external view returns (uint256) {
        return ContextManagerStorageLib.getNonce(addr);
    }

    /**
     * @notice Executes a single call within context after verifying target approval
     * @param target The contract address to call
     * @param sender The sender address to set in context
     * @param data The calldata to execute
     * @return bytes The result of the execution
     * @dev Requirements:
     * - Target must be an approved address
     * - Context must be set up before and cleared after execution
     * @custom:security Ensures proper context setup and cleanup
     */
    function _executeWithinContext(address target, address sender, bytes calldata data) private returns (bytes memory) {
        // Check if target address is approved
        if (!ContextManagerStorageLib.isApproved(target)) {
            revert AddressNotApproved(target);
        }

        // Setup context before execution
        IContextClient(target).setupContext(sender);

        // Execute call
        bytes memory result = target.functionCall(data);

        // Clear context after execution
        IContextClient(target).clearContext();

        emit ContextCall(target, data, result);

        return result;
    }
}
