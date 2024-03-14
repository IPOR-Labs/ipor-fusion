// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @title Storage ID's associated with the IPOR Protocol Router.
library StorageLib {
    uint256 constant STORAGE_SLOT_BASE = 1_000_000;

    // append only
    enum StorageId {
        MARKETS_GRANTED_ASSETS
    }

    struct MarketsGrantedAssets {
        // marketId => asset =>  1 - granted, otherwise  - not granted
        mapping(uint256 => mapping(address => uint256)) value;
    }


    function getMarketsGrantedAssets() internal pure returns (MarketsGrantedAssets storage grantedAssets) {
        uint256 slot = _getStorageSlot(StorageId.MARKETS_GRANTED_ASSETS);
        assembly {
            grantedAssets.slot := slot
        }
    }

    function _getStorageSlot(StorageId storageId) private pure returns (uint256 slot) {
        return uint256(storageId) + STORAGE_SLOT_BASE;
    }
}
