// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {ContextManagerStorageLib} from "./ContextManagerStorageLib.sol";
import {IContextClient} from "./IContextClient.sol";

struct ExecuteData {
    address[] addrs;
    bytes[] data;
}

struct ContextDataWithSender {
    address sender;
    uint256 expirationTime;
    uint256 nonce;
    address target;
    bytes data;
    /// @notice signature of data (expirationTime, nonce, target, data)
    bytes signature;
}

/// @title ContextManager contract responsible for managing context data
contract ContextManager is AccessManagedUpgradeable {
    using Address for address;

    /// @notice Emitted when an address is added to approved list
    event AddressApproved(address indexed addr);

    /// @notice Emitted when an address is removed from approved list
    event AddressRemoved(address indexed addr);

    /// @notice Custom errors
    error AddressNotApproved(address addr);
    error LengthMismatch();

    /// @notice Emitted when a call is executed within context
    event ContextCall(address indexed target, bytes data, bytes result);

    // Add error for expired signature
    error SignatureExpired();
    error InvalidSignature();
    error NonceTooLow();

    constructor(address initialAuthority, address[] memory approvedAddresses) {
        super.__AccessManaged_init_unchained(initialAuthority);
        for (uint256 i; i < approvedAddresses.length; ++i) {
            ContextManagerStorageLib.addApprovedAddress(approvedAddresses[i]);
            emit AddressApproved(approvedAddresses[i]);
        }
    }

    /// @notice Adds multiple addresses to the approved addresses list
    /// @param addrs Array of addresses to be approved
    /// @return approvedCount Number of newly approved addresses (excluding already approved ones)
    function addApprovedAddresses(address[] calldata addrs) external restricted returns (uint256 approvedCount) {
        uint256 length = addrs.length;
        for (uint256 i; i < length; ) {
            if (ContextManagerStorageLib.addApprovedAddress(addrs[i])) {
                emit AddressApproved(addrs[i]);
                unchecked {
                    ++approvedCount;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Removes multiple addresses from the approved addresses list
    /// @param addrs Array of addresses to be removed
    /// @return removedCount Number of addresses that were actually removed
    function removeApprovedAddresses(address[] calldata addrs) external restricted returns (uint256 removedCount) {
        uint256 length = addrs.length;
        for (uint256 i; i < length; ) {
            if (ContextManagerStorageLib.removeApprovedAddress(addrs[i])) {
                emit AddressRemoved(addrs[i]);
                unchecked {
                    ++removedCount;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Executes multiple calls to approved addresses
    /// @param executeData Struct containing arrays of target addresses and call data
    /// @return results Array of results from each call
    function runWithContext(ExecuteData calldata executeData) external returns (bytes[] memory results) {
        uint256 length = executeData.addrs.length;
        // Check arrays length match
        if (executeData.addrs.length != length) {
            revert LengthMismatch();
        }

        results = new bytes[](length);

        for (uint256 i; i < length; ++i) {
            address target = executeData.addrs[i];
            bytes calldata data = executeData.data[i];

            // Check if address is approved
            if (!ContextManagerStorageLib.isApproved(target)) {
                revert AddressNotApproved(target);
            }

            IContextClient(target).setupContext(msg.sender);

            // Execute call
            results[i] = target.functionCall(data);

            IContextClient(target).clearContext();

            emit ContextCall(target, data, results[i]);
        }
    }

    /// @notice Executes multiple calls to approved addresses with signature verification
    /// @param contextDataArray Array of context data containing signatures and call data
    /// @return results Array of results from each call
    function runWithContextAndSignature(
        ContextDataWithSender[] calldata contextDataArray
    ) external returns (bytes[] memory results) {
        uint256 length = contextDataArray.length;
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

            // Check if target address is approved
            if (!ContextManagerStorageLib.isApproved(contextData.target)) {
                revert AddressNotApproved(contextData.target);
            }

            IContextClient(contextData.target).setupContext(contextData.sender);

            // Execute call
            results[i] = contextData.target.functionCall(contextData.data);

            IContextClient(contextData.target).clearContext();

            emit ContextCall(contextData.target, contextData.data, results[i]);
        }
    }

    function _verifySignature(ContextDataWithSender memory contextData) internal view returns (bool) {
        return
            ECDSA.recover(
                keccak256(
                    abi.encodePacked(
                        contextData.expirationTime,
                        contextData.nonce,
                        contextData.target,
                        contextData.data
                    )
                ),
                contextData.signature
            ) == contextData.sender;
    }

    /// @notice Gets the current nonce for a specific address
    /// @param addr The address to get the nonce for
    /// @return Current nonce value for the address
    function getNonce(address addr) external view returns (uint256) {
        return ContextManagerStorageLib.getNonce(addr);
    }
}
