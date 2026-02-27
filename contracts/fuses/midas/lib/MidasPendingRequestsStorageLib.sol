// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title MidasPendingRequestsStorageLib
/// @notice ERC-7201 namespaced storage library for tracking pending Midas deposit and redemption requests
/// @dev Runs in PlasmaVault's delegatecall context. Tracks pending request IDs per vault address
///      for both deposit vaults and redemption vaults.
library MidasPendingRequestsStorageLib {
    error MidasPendingStorageRequestAlreadyExists(address midasVault, uint256 requestId);
    error MidasPendingStorageRequestNotFound(address midasVault, uint256 requestId);

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.midas.PendingRequests")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MIDAS_PENDING_REQUESTS_SLOT =
        0x7d3961bffbb073dc243411cd8479c04c9511c56c3318be62af0b5a8ccb3ffc00;

    /// @custom:storage-location erc7201:io.ipor.midas.PendingRequests
    struct MidasPendingRequestsStorage {
        /// @dev Array of Midas vault addresses that have pending deposit requests
        address[] depositVaults;
        /// @dev Mapping from deposit vault address to array of pending deposit request IDs
        mapping(address => uint256[]) depositRequestIds;
        /// @dev Array of Midas vault addresses that have pending redemption requests
        address[] redemptionVaults;
        /// @dev Mapping from redemption vault address to array of pending redemption request IDs
        mapping(address => uint256[]) redemptionRequestIds;
    }

    /// @notice Gets the storage pointer for Midas pending requests
    /// @return storagePtr The storage struct pointer
    function _getStorage() private pure returns (MidasPendingRequestsStorage storage storagePtr) {
        assembly {
            storagePtr.slot := MIDAS_PENDING_REQUESTS_SLOT
        }
    }

    // ============ Deposit Request Tracking ============

    /// @notice Add a pending deposit request for a vault
    /// @param depositVault_ The Midas deposit vault address
    /// @param requestId_ The request ID returned by depositRequest()
    function addPendingDeposit(address depositVault_, uint256 requestId_) internal {
        MidasPendingRequestsStorage storage s = _getStorage();

        // Validate no duplicate
        uint256[] storage ids = s.depositRequestIds[depositVault_];
        uint256 length = ids.length;
        for (uint256 i; i < length; ) {
            if (ids[i] == requestId_) {
                revert MidasPendingStorageRequestAlreadyExists(depositVault_, requestId_);
            }
            unchecked {
                ++i;
            }
        }

        // If vault is not yet tracked, add it
        if (length == 0) {
            s.depositVaults.push(depositVault_);
        }

        ids.push(requestId_);
    }

    /// @notice Remove a pending deposit request for a vault
    /// @param depositVault_ The Midas deposit vault address
    /// @param requestId_ The request ID to remove
    function removePendingDeposit(address depositVault_, uint256 requestId_) internal {
        MidasPendingRequestsStorage storage s = _getStorage();
        uint256[] storage ids = s.depositRequestIds[depositVault_];
        uint256 length = ids.length;

        bool found;
        for (uint256 i; i < length; ) {
            if (ids[i] == requestId_) {
                // Swap-and-pop
                ids[i] = ids[length - 1];
                ids.pop();
                found = true;
                break;
            }
            unchecked {
                ++i;
            }
        }

        if (!found) {
            revert MidasPendingStorageRequestNotFound(depositVault_, requestId_);
        }

        // If vault has no more request IDs, remove it from the vaults array
        if (ids.length == 0) {
            _removeDepositVault(s, depositVault_);
        }
    }

    /// @notice Get all pending deposit vaults and their request IDs
    /// @return vaults Array of deposit vault addresses with pending requests
    /// @return requestIds Array of arrays containing request IDs per vault
    function getPendingDeposits()
        internal
        view
        returns (address[] memory vaults, uint256[][] memory requestIds)
    {
        MidasPendingRequestsStorage storage s = _getStorage();
        uint256 length = s.depositVaults.length;
        vaults = new address[](length);
        requestIds = new uint256[][](length);

        for (uint256 i; i < length; ) {
            vaults[i] = s.depositVaults[i];
            requestIds[i] = s.depositRequestIds[vaults[i]];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Get pending deposit request IDs for a specific vault
    /// @param depositVault_ The Midas deposit vault address
    /// @return Array of pending request IDs
    function getPendingDepositsForVault(address depositVault_) internal view returns (uint256[] memory) {
        return _getStorage().depositRequestIds[depositVault_];
    }

    /// @notice Check if a deposit request is pending for a vault
    /// @param depositVault_ The deposit vault address
    /// @param requestId_ The request ID to check
    /// @return True if the request is pending
    function isDepositPending(address depositVault_, uint256 requestId_) internal view returns (bool) {
        uint256[] storage ids = _getStorage().depositRequestIds[depositVault_];
        uint256 length = ids.length;
        for (uint256 i; i < length; ) {
            if (ids[i] == requestId_) {
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    // ============ Redemption Request Tracking ============

    /// @notice Add a pending redemption request for a vault
    /// @param redemptionVault_ The Midas redemption vault address
    /// @param requestId_ The request ID returned by redeemRequest()
    function addPendingRedemption(address redemptionVault_, uint256 requestId_) internal {
        MidasPendingRequestsStorage storage s = _getStorage();

        // Validate no duplicate
        uint256[] storage ids = s.redemptionRequestIds[redemptionVault_];
        uint256 length = ids.length;
        for (uint256 i; i < length; ) {
            if (ids[i] == requestId_) {
                revert MidasPendingStorageRequestAlreadyExists(redemptionVault_, requestId_);
            }
            unchecked {
                ++i;
            }
        }

        // If vault is not yet tracked, add it
        if (length == 0) {
            s.redemptionVaults.push(redemptionVault_);
        }

        ids.push(requestId_);
    }

    /// @notice Remove a pending redemption request for a vault
    /// @param redemptionVault_ The Midas redemption vault address
    /// @param requestId_ The request ID to remove
    function removePendingRedemption(address redemptionVault_, uint256 requestId_) internal {
        MidasPendingRequestsStorage storage s = _getStorage();
        uint256[] storage ids = s.redemptionRequestIds[redemptionVault_];
        uint256 length = ids.length;

        bool found;
        for (uint256 i; i < length; ) {
            if (ids[i] == requestId_) {
                // Swap-and-pop
                ids[i] = ids[length - 1];
                ids.pop();
                found = true;
                break;
            }
            unchecked {
                ++i;
            }
        }

        if (!found) {
            revert MidasPendingStorageRequestNotFound(redemptionVault_, requestId_);
        }

        // If vault has no more request IDs, remove it from the vaults array
        if (ids.length == 0) {
            _removeRedemptionVault(s, redemptionVault_);
        }
    }

    /// @notice Get all pending redemption vaults and their request IDs
    /// @return vaults Array of redemption vault addresses with pending requests
    /// @return requestIds Array of arrays containing request IDs per vault
    function getPendingRedemptions()
        internal
        view
        returns (address[] memory vaults, uint256[][] memory requestIds)
    {
        MidasPendingRequestsStorage storage s = _getStorage();
        uint256 length = s.redemptionVaults.length;
        vaults = new address[](length);
        requestIds = new uint256[][](length);

        for (uint256 i; i < length; ) {
            vaults[i] = s.redemptionVaults[i];
            requestIds[i] = s.redemptionRequestIds[vaults[i]];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Get pending redemption request IDs for a specific vault
    /// @param redemptionVault_ The Midas redemption vault address
    /// @return Array of pending request IDs
    function getPendingRedemptionsForVault(address redemptionVault_) internal view returns (uint256[] memory) {
        return _getStorage().redemptionRequestIds[redemptionVault_];
    }

    /// @notice Check if a redemption request is pending for a vault
    /// @param redemptionVault_ The redemption vault address
    /// @param requestId_ The request ID to check
    /// @return True if the request is pending
    function isRedemptionPending(address redemptionVault_, uint256 requestId_) internal view returns (bool) {
        uint256[] storage ids = _getStorage().redemptionRequestIds[redemptionVault_];
        uint256 length = ids.length;
        for (uint256 i; i < length; ) {
            if (ids[i] == requestId_) {
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    // ============ Private Helpers ============

    function _removeDepositVault(MidasPendingRequestsStorage storage s, address vault_) private {
        address[] storage vaults = s.depositVaults;
        uint256 length = vaults.length;
        for (uint256 i; i < length; ) {
            if (vaults[i] == vault_) {
                vaults[i] = vaults[length - 1];
                vaults.pop();
                return;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _removeRedemptionVault(MidasPendingRequestsStorage storage s, address vault_) private {
        address[] storage vaults = s.redemptionVaults;
        uint256 length = vaults.length;
        for (uint256 i; i < length; ) {
            if (vaults[i] == vault_) {
                vaults[i] = vaults[length - 1];
                vaults.pop();
                return;
            }
            unchecked {
                ++i;
            }
        }
    }
}
