// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {ContextManagerStorageLib} from "./ContextManagerStorageLib.sol";

/// @title ContextManager contract responsible for managing context data
contract ContextManager is AccessManagedUpgradeable {
    /// @notice Emitted when an address is added to approved list
    event AddressApproved(address indexed addr);

    /// @notice Emitted when an address is removed from approved list
    event AddressRemoved(address indexed addr);

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
}
