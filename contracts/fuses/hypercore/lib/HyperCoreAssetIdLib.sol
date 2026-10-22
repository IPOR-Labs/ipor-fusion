// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title HyperCoreAssetIdLib
/// @notice Pure helpers for the HyperCore perp asset id space: native vs HIP-3 markets, owning dex and read index.
library HyperCoreAssetIdLib {
    /// @dev Native perp action assets and read indices are both below this value
    uint32 internal constant NATIVE_PERP_ASSET_LIMIT = 10_000;
    /// @dev HIP-3 action asset = HIP3_ASSET_OFFSET + read index; read index = dex * HIP3_DEX_MULTIPLIER + market index
    uint32 internal constant HIP3_ASSET_OFFSET = 100_000;
    /// @dev Number of market indices reserved per HIP-3 dex in the asset id space
    uint32 internal constant HIP3_DEX_MULTIPLIER = 10_000;
    /// @dev First HIP-3 action asset (dex 1, market index 0)
    uint32 internal constant HIP3_FIRST_ASSET = 110_000;
    /// @dev First id of the outcome-market family; ids at or above it are not perp assets
    uint32 internal constant OUTCOME_FIRST_ASSET = 100_000_000;

    error HyperCoreInvalidPerpAsset(uint32 asset);

    function isNativePerpAsset(uint32 asset_) internal pure returns (bool) {
        return asset_ < NATIVE_PERP_ASSET_LIMIT;
    }

    function isHip3Asset(uint32 asset_) internal pure returns (bool) {
        return asset_ >= HIP3_FIRST_ASSET && asset_ < OUTCOME_FIRST_ASSET;
    }

    function perpDexOf(uint32 asset_) internal pure returns (uint32) {
        if (isNativePerpAsset(asset_)) return 0;
        if (isHip3Asset(asset_)) return (asset_ - HIP3_ASSET_OFFSET) / HIP3_DEX_MULTIPLIER;
        revert HyperCoreInvalidPerpAsset(asset_);
    }

    function readIndexOf(uint32 asset_) internal pure returns (uint32) {
        if (isNativePerpAsset(asset_)) return asset_;
        if (isHip3Asset(asset_)) return asset_ - HIP3_ASSET_OFFSET;
        revert HyperCoreInvalidPerpAsset(asset_);
    }
}
