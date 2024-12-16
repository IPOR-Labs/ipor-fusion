// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Context Manager Storage Library
/// @notice Library managing storage for approved addresses and nonces in the Context Manager system
/// @dev Implements storage patterns for managing approved addresses and nonces with minimal collision risk
library ContextManagerStorageLib {
    /// @dev Thrown when storage state becomes inconsistent during operations
    error InconsistentStorageState();
    /// @dev Thrown when attempting to use a nonce value that is too low or already used
    error NonceTooLow();

    /// @notice Emitted when an address's nonce is updated
    /// @param addr The address whose nonce was updated
    /// @param newNonce The new nonce value
    event NonceUpdated(address indexed addr, uint256 newNonce);

    /// @notice Emitted when an address is added to the approved addresses list
    /// @param addr The address that was added to the approved addresses list
    event ApprovedAddressAdded(address indexed addr);

    /// @notice Emitted when an address is removed from the approved addresses list
    /// @param addr The address that was removed from the approved addresses list
    event ApprovedAddressRemoved(address indexed addr);

    /// @dev Storage slot for approved addresses mapping and array
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.context.manager.approved.addresses")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant APPROVED_ADDRESSES = 0xcd52b1eda56201f4a7653cae301594a261618d67f76e8e1d5e26f1bb9f772a00;

    /// @dev Storage slot for nonces mapping
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.context.manager.nonces")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant NONCES_SLOT = 0x0409b94a090b90a18fc2f85ddcc3023733517210eae8ad3941f503bbcf96a600;

    /// @notice Storage structure for managing approved addresses
    /// @dev Uses a mapping for O(1) lookups and an array for enumeration
    struct ApprovedAddresses {
        /// @dev Mapping of address to approval status (1 = approved, 0 = not approved)
        mapping(address target => uint256 isGranted) addressGranted;
        /// @dev Array of all approved addresses for enumeration
        address[] addresses;
    }

    /// @notice Storage structure for managing nonces
    /// @dev Used for replay protection in signature-based operations
    struct Nonces {
        /// @dev Mapping of address to their current nonce
        mapping(address sender => uint256 nonce) addressToNonce;
    }

    /// @notice Adds an address to the approved addresses list
    /// @dev Will not add zero address or already approved addresses
    /// @param addr The address to be approved
    /// @return success True if the address was newly added, false if it was already approved or invalid
    function addApprovedAddress(address addr) internal returns (bool success) {
        if (addr == address(0) || isApproved(addr)) {
            return false;
        }

        ApprovedAddresses storage $ = _getApprovedAddresses();

        // Add to mapping and array
        $.addressGranted[addr] = 1;
        $.addresses.push(addr);

        // Emit event for better transparency and tracking
        emit ApprovedAddressAdded(addr);

        return true;
    }

    /// @notice Removes an address from the approved addresses list
    /// @dev Maintains array consistency by replacing removed element with the last element
    /// @param addr The address to be removed from approved list
    /// @return success True if the address was removed, false if it wasn't approved or invalid
    function removeApprovedAddress(address addr) internal returns (bool success) {
        // Quick validation
        if (addr == address(0) || !isApproved(addr)) {
            return false;
        }

        ApprovedAddresses storage $ = _getApprovedAddresses();

        // Remove from mapping first
        $.addressGranted[addr] = 0;

        // Remove from array by finding and replacing with last element
        uint256 length = $.addresses.length;
        for (uint256 i; i < length; ++i) {
            if ($.addresses[i] == addr) {
                // If not the last element, replace with the last one
                if (i != length - 1) {
                    $.addresses[i] = $.addresses[length - 1];
                }
                $.addresses.pop();

                emit ApprovedAddressRemoved(addr);
                return true;
            }
        }
    }

    /// @notice Retrieves the complete list of approved addresses
    /// @dev Creates a new array in memory with all approved addresses
    /// @return result Array containing all currently approved addresses
    function getApprovedAddresses() internal view returns (address[] memory result) {
        return _getApprovedAddresses().addresses;
    }

    /// @notice Checks if an address is approved
    /// @dev Quick O(1) lookup using the addressGranted mapping
    /// @param addr The address to check approval status for
    /// @return True if the address is approved, false otherwise
    function isApproved(address addr) internal view returns (bool) {
        ApprovedAddresses storage $ = _getApprovedAddresses();
        return $.addressGranted[addr] == 1;
    }

    /// @notice Retrieves the current nonce for an address
    /// @dev Used for signature validation and replay protection
    /// @param addr The address to get the nonce for
    /// @return The current nonce value for the address
    function getNonce(address addr) internal view returns (uint256) {
        Nonces storage $ = _getNonces();
        return $.addressToNonce[addr];
    }

    /// @notice Verifies and updates the nonce for an address
    /// @dev Ensures new nonce is higher than current nonce to prevent replay attacks
    /// @param addr The address to update the nonce for
    /// @param newNonce The new nonce value to set
    /// @custom:throws NonceTooLow if the provided nonce is not higher than the current nonce
    function verifyAndUpdateNonce(address addr, uint256 newNonce) internal {
        Nonces storage $ = _getNonces();
        if ($.addressToNonce[addr] >= newNonce) {
            revert NonceTooLow();
        }
        $.addressToNonce[addr] = newNonce;
        emit NonceUpdated(addr, newNonce);
    }

    /// @dev Internal function to access the ApprovedAddresses storage slot
    /// @return $ Reference to the ApprovedAddresses storage struct
    function _getApprovedAddresses() private pure returns (ApprovedAddresses storage $) {
        assembly {
            $.slot := APPROVED_ADDRESSES
        }
    }

    /// @dev Internal function to access the Nonces storage slot
    /// @return $ Reference to the Nonces storage struct
    function _getNonces() private pure returns (Nonces storage $) {
        assembly {
            $.slot := NONCES_SLOT
        }
    }
}
