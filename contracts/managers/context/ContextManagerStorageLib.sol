// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

library ContextManagerStorageLib {
    /// @dev Custom error for inconsistent storage state
    error InconsistentStorageState();
    error NonceTooLow();
    error AddressNotApproved(address addr);

    /// @notice Emitted when the nonce is updated
    event NonceUpdated(address indexed addr, uint256 newNonce);

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.context.manager.approved.addresses")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant APPROVED_ADDRESSES = 0x6ab1bcc6104660f940addebf2a0f1cdfdd8fb6e9a4305fcd73bc32a2bcbabc00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.context.manager.nonces")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant NONCES_SLOT = 0x6ab1bcc6104660f940addebf2a0f1cdfdd8fb6e9a4305fcd73bc32a2bcbab100;

    struct ApprovedAddresses {
        /// @dev key is the address, value is 1 if the address is granted, otherwise - 0
        mapping(address => uint256) addressGranted;
        /// @dev list of addresses that are granted
        address[] addresses;
    }

    struct Nonces {
        mapping(address => uint256) addressToNonce;
    }

    function _getApprovedAddresses() private pure returns (ApprovedAddresses storage $) {
        assembly {
            $.slot := APPROVED_ADDRESSES
        }
    }

    function _getNonces() private pure returns (Nonces storage $) {
        assembly {
            $.slot := NONCES_SLOT
        }
    }

    /// @notice Adds an address to the approved addresses list if it's not already added
    /// @param addr The address to be added
    /// @return true if address was added, false if it was already in the list
    function addApprovedAddress(address addr) internal returns (bool) {
        if (addr == address(0)) {
            return false;
        }
        ApprovedAddresses storage $ = _getApprovedAddresses();

        // Check if address is already granted
        if ($.addressGranted[addr] == 1) {
            return false;
        }

        // Add to mapping and array
        $.addressGranted[addr] = 1;
        $.addresses.push(addr);
        return true;
    }

    /// @notice Removes an address from the approved addresses list
    /// @param addr The address to be removed
    /// @return true if address was removed, false if it wasn't in the list
    function removeApprovedAddress(address addr) internal returns (bool) {
        ApprovedAddresses storage $ = _getApprovedAddresses();

        // Check if address is not granted
        if ($.addressGranted[addr] == 0) {
            return false;
        }

        // Remove from mapping
        $.addressGranted[addr] = 0;

        // Remove from array by finding and replacing with last element
        uint256 length = $.addresses.length;
        for (uint256 i = 0; i < length; i++) {
            if ($.addresses[i] == addr) {
                // If not the last element, replace with the last one
                if (i != length - 1) {
                    $.addresses[i] = $.addresses[length - 1];
                }
                $.addresses.pop();
                return true;
            }
        }

        // Should never reach here if storage is consistent
        revert InconsistentStorageState();
    }

    /// @notice Returns the list of all approved addresses
    /// @return Array of approved addresses in memory
    function getApprovedAddressesList() internal view returns (address[] memory) {
        ApprovedAddresses storage $ = _getApprovedAddresses();
        uint256 length = $.addresses.length;

        address[] memory approvedAddresses = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            approvedAddresses[i] = $.addresses[i];
        }

        return approvedAddresses;
    }

    /// @notice Checks if an address is in the approved list
    /// @param addr The address to check
    /// @return true if address is approved, false otherwise
    function isApproved(address addr) internal view returns (bool) {
        ApprovedAddresses storage $ = _getApprovedAddresses();
        return $.addressGranted[addr] == 1;
    }

    /// @notice Gets the current nonce value for a specific address
    /// @param addr The address to get the nonce for
    /// @return Current nonce value for the address
    function getNonce(address addr) internal view returns (uint256) {
        Nonces storage $ = _getNonces();
        return $.addressToNonce[addr];
    }

    /// @notice Increments the nonce for a specific address and returns the new value
    /// @param addr The address to increment the nonce for
    /// @return New nonce value after increment
    function verifyAndUpdateNonce(address addr, uint256 newNonce) internal returns (uint256) {
        Nonces storage $ = _getNonces();
        if ($.addressToNonce[addr] >= newNonce) {
            revert NonceTooLow();
        }
        $.addressToNonce[addr] = newNonce;
        emit NonceUpdated(addr, newNonce);
    }
}
