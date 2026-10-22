// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {HyperCoreLib} from "./HyperCoreLib.sol";

/// @title HyperCoreSupportedDexLib
/// @notice IPOR product and risk policy: which HIP-3 perp dexes the HyperCore fuses allow.
/// @dev This is not a HyperCore protocol fact. Enabling a dex is a deliberate decision of ours (USDC collateral only,
///      HyperEVM mainnet only); changing the set is a policy change, not a protocol update.
library HyperCoreSupportedDexLib {
    /// @dev HyperEVM mainnet chain id; HIP-3 dexes are supported only on this chain
    uint256 internal constant HYPEREVM_MAINNET_CHAIN_ID = 999;
    /// @dev HIP-3 perp dex index of the `xyz` dex (USDC collateral)
    uint32 internal constant XYZ_PERP_DEX = 1;
    /// @dev HIP-3 perp dex index of the `abcd` dex (USDC collateral)
    uint32 internal constant ABCD_PERP_DEX = 6;
    /// @dev HIP-3 perp dex index of the `para` dex (USDC collateral)
    uint32 internal constant PARA_PERP_DEX = 8;
    /// @dev HIP-3 perp dex index of the `mkts` dex (USDC collateral)
    uint32 internal constant MKTS_PERP_DEX = 9;
    /// @dev HIP-3 perp dex index of the `io` dex (USDC collateral)
    uint32 internal constant IO_PERP_DEX = 10;
    /// @dev bit i set = HIP-3 perp dex index i is supported; bit 0 (native) is never part of the mask (0x742 = 1858)
    uint256 internal constant SUPPORTED_HIP3_DEX_MASK = (1 << 1) | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10);

    function supportedHip3DexMask() internal view returns (uint256) {
        return block.chainid == HYPEREVM_MAINNET_CHAIN_ID ? SUPPORTED_HIP3_DEX_MASK : 0;
    }

    function isSupportedPerpDex(uint32 dex_) internal view returns (bool) {
        if (dex_ == HyperCoreLib.NATIVE_PERP_DEX) return true;
        // Shifting by 256 or more would wrap to zero anyway; dex ids 240..255 have no bit in the mask.
        if (dex_ > type(uint8).max) return false;
        return supportedHip3DexMask() & (uint256(1) << dex_) != 0;
    }
}
