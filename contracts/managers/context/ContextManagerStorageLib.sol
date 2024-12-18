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
    /// @param target The address whose nonce was updated
    /// @param newNonce The new nonce value
    event NonceUpdated(address indexed target, uint256 newNonce);

    /// @notice Emitted when an address is added to the approved addresses list
    /// @param target The address that was added to the approved addresses list
    event ApprovedTargetAdded(address indexed target);

    /// @notice Emitted when an address is removed from the approved targets list
    /// @param target The address that was removed from the approved targets list
    event ApprovedTargetRemoved(address indexed target);

    /// @dev Storage slot for approved targets mapping and array
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.context.manager.approved.targets")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant APPROVED_TARGETS = 0xba0b14fc3b5f6eb62b63f24324d3267b78a7c3121b0d922dabc8df20fcad1800;

    /// @dev Storage slot for nonces mapping
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.context.manager.nonces")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant NONCES_SLOT = 0x0409b94a090b90a18fc2f85ddcc3023733517210eae8ad3941f503bbcf96a600;

    /// @notice Storage structure for managing approved addresses
    /// @dev Uses a mapping for O(1) lookups and an array for enumeration
    struct ApprovedTargets {
        /// @dev Mapping of target to approval status (1 = approved, 0 = not approved)
        mapping(address target => uint256 isApproved) targetApproved;
        /// @dev Array of all approved targets for enumeration
        address[] targets;
    }

    /// @notice Storage structure for managing nonces
    /// @dev Used for replay protection in signature-based operations
    struct Nonces {
        /// @dev Mapping of address to their current nonce
        mapping(address sender => uint256 nonce) addressToNonce;
    }

    /// @notice Adds an address to the approved addresses list
    /// @dev Will not add zero address or already approved addresses
    /// @param target_ The address to be approved
    /// @return success True if the address was newly added, false if it was already approved or invalid
    function addApprovedTarget(address target_) internal returns (bool success) {
        if (target_ == address(0) || isTargetApproved(target_)) {
            return false;
        }

        ApprovedTargets storage $ = _getApprovedTargets();

        $.targetApproved[target_] = 1;
        $.targets.push(target_);

        emit ApprovedTargetAdded(target_);

        return true;
    }

    /// @notice Removes an address from the approved addresses list
    /// @dev Maintains array consistency by replacing removed element with the last element
    /// @param target_ The address to be removed from approved list
    /// @return success True if the address was removed, false if it wasn't approved or invalid
    function removeApprovedTarget(address target_) internal returns (bool success) {
        if (target_ == address(0) || !isTargetApproved(target_)) {
            return false;
        }

        ApprovedTargets storage $ = _getApprovedTargets();

        $.targetApproved[target_] = 0;

        uint256 length = $.targets.length;

        for (uint256 i; i < length; ++i) {
            if ($.targets[i] == target_) {
                if (i != length - 1) {
                    $.targets[i] = $.targets[length - 1];
                }
                $.targets.pop();

                emit ApprovedTargetRemoved(target_);
                return true;
            }
        }
    }

    /// @notice Retrieves the complete list of approved addresses
    /// @dev Creates a new array in memory with all approved addresses
    /// @return result Array containing all currently approved addresses
    function getApprovedTargets() internal view returns (address[] memory result) {
        return _getApprovedTargets().targets;
    }

    /// @notice Checks if an address is approved
    /// @dev Quick O(1) lookup using the addressGranted mapping
    /// @param target_ The address to check approval status for
    /// @return True if the address is approved, false otherwise
    function isTargetApproved(address target_) internal view returns (bool) {
        ApprovedTargets storage $ = _getApprovedTargets();
        return $.targetApproved[target_] == 1;
    }

    /// @notice Retrieves the current nonce for an address
    /// @dev Used for signature validation and replay protection
    /// @param sender_ The address to get the nonce for
    /// @return The current nonce value for the address
    function getNonce(address sender_) internal view returns (uint256) {
        Nonces storage $ = _getNonces();
        return $.addressToNonce[sender_];
    }

    /// @notice Verifies and updates the nonce for an address
    /// @dev Ensures new nonce is higher than current nonce to prevent replay attacks
    /// @param sender_ The address to update the nonce for
    /// @param newNonce_ The new nonce value to set
    /// @custom:throws NonceTooLow if the provided nonce is not higher than the current nonce
    function verifyAndUpdateNonce(address sender_, uint256 newNonce_) internal {
        Nonces storage $ = _getNonces();

        if ($.addressToNonce[sender_] >= newNonce_) {
            revert NonceTooLow();
        }

        $.addressToNonce[sender_] = newNonce_;

        emit NonceUpdated(sender_, newNonce_);
    }

    /// @dev Internal function to access the ApprovedTargets storage slot
    /// @return $ Reference to the ApprovedTargets storage struct
    function _getApprovedTargets() private pure returns (ApprovedTargets storage $) {
        assembly {
            $.slot := APPROVED_TARGETS
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
