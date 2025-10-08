// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title WethEthAdapterStorageLib
/// @notice Library for managing WethEthAdapter storage in Plasma Vault
/// @dev Implements storage pattern using an isolated storage slot to maintain delegator address
library WethEthAdapterStorageLib {
    /// @dev Storage slot for WETH ETH adapter address
    /// @dev Calculation: keccak256(abi.encode(uint256(keccak256("io.ipor.ebisu.WethEthAdapter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WETH_ETH_ADAPTER_SLOT =
        0x0129b8eb100deb46c8d563a313bc53ab38d2bf7ea1b50270934f4d98d5e3b300;

    /// @dev Structure holding the WETH ETH adapter address
    /// @custom:storage-location erc7201:io.ipor.ebisu.WethEthAdapter
    struct WethEthAdapterStorage {
        /// @dev The address of the WETH ETH adapter
        address adapter;
    }

    /// @notice Gets the WETH ETH adapter storage pointer
    /// @return storagePtr The WethEthAdapterStorage struct from storage
    function getWethEthAdapterStorage() internal pure returns (WethEthAdapterStorage storage storagePtr) {
        assembly {
            storagePtr.slot := WETH_ETH_ADAPTER_SLOT
        }
    }

    /// @notice Sets the WETH ETH adapter address
    /// @param adapter_ The address of the WETH ETH adapter
    function setWethEthAdapter(address adapter_) internal {
        WethEthAdapterStorage storage storagePtr = getWethEthAdapterStorage();
        storagePtr.adapter = adapter_;
    }

    /// @notice Gets the WETH ETH adapter address
    /// @return The address of the WETH ETH adapter
    function getWethEthAdapter() internal view returns (address) {
        WethEthAdapterStorage storage storagePtr = getWethEthAdapterStorage();
        return storagePtr.adapter;
    }
}
