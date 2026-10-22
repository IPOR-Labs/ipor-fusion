// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../../libraries/PlasmaVaultConfigLib.sol";
import {HyperCoreAssetIdLib} from "./HyperCoreAssetIdLib.sol";
import {HyperCoreSupportedDexLib} from "./HyperCoreSupportedDexLib.sol";

/// @title HyperCoreSubstrateLib
/// @notice Strict typed substrates for HyperCore grants on market 55.
/// @dev Type flag occupies bits 255..248. Config stores its key in bits 247..240
///      and its value in bits 239..0 as specified in chat/INTERFACES.md.
library HyperCoreSubstrateLib {
    enum SubstrateType {
        Undefined,
        SpotToken,
        PerpMarket,
        Destination,
        Builder,
        Config,
        SendCap,
        PerpPositionCap
    }
    /// @dev Key numbering is stable. `WindowOrderSeconds` and `SettlementMode` are RESERVED and ignored since IL-8543
    ///      (orders and cancels are TIMING-only; REPORTED mode was removed). They remain decodable so a vault that
    ///      already has them granted keeps a valid config; no fuse reads them.
    enum ConfigKey {
        Undefined,
        WindowTransferSeconds,
        WindowOrderSeconds,
        MaxUsdClassTransferUsd6,
        PerpDexIds,
        SettlementMode,
        SpotSendBridgeEnabled,
        TransferTimeoutSeconds,
        ActivationFeeAllowanceUsdcWei,
        MaxNavJumpBps,
        MaxMarkOracleDeviationBps,
        NavJumpFloorUsd6
    }

    /// @dev Width of the PerpDexIds config bitmap (uint240); dex indices at or above it are unsupported
    uint32 internal constant PERP_DEX_BITMAP_BITS = 240;
    uint256 private constant _FLAG_SHIFT = 248;
    uint256 private constant _DATA_MASK = (uint256(1) << 248) - 1;

    error HyperCoreInvalidSubstrate(bytes32 substrate);
    error HyperCoreInvalidConfigKey(uint8 key);
    error HyperCoreDuplicateConfig(ConfigKey key);
    error HyperCoreValueOutOfRange();
    error HyperCoreUnsupportedPerpDexConfig(uint240 bitmap);

    function encodeSpotToken(uint64 tokenIndex_, address evmAsset_) internal pure returns (bytes32) {
        return _word(SubstrateType.SpotToken, (uint256(tokenIndex_) << 160) | uint160(evmAsset_));
    }

    function decodeSpotToken(bytes32 substrate_) internal pure returns (uint64 tokenIndex_, address evmAsset_) {
        _checkType(substrate_, SubstrateType.SpotToken);
        uint256 data = uint256(substrate_) & _DATA_MASK;
        if (data >> 224 != 0) revert HyperCoreInvalidSubstrate(substrate_);
        tokenIndex_ = uint64(data >> 160);
        evmAsset_ = address(uint160(data));
    }

    function encodePerpMarket(
        uint32 asset_,
        uint88 maxNotionalUsd6_,
        bool reduceOnlyRequired_
    ) internal pure returns (bytes32) {
        uint256 data = (uint256(asset_) << 216) |
            (uint256(maxNotionalUsd6_) << 128) |
            ((reduceOnlyRequired_ ? uint256(1) : uint256(0)) << 120);
        return _word(SubstrateType.PerpMarket, data);
    }

    function decodePerpMarket(
        bytes32 substrate_
    ) internal pure returns (uint32 asset_, uint88 maxNotionalUsd6_, bool reduceOnlyRequired_) {
        _checkType(substrate_, SubstrateType.PerpMarket);
        uint256 data = uint256(substrate_) & _DATA_MASK;
        if ((data >> 248) != 0 || (data & ((uint256(1) << 120) - 1)) != 0) {
            revert HyperCoreInvalidSubstrate(substrate_);
        }
        asset_ = uint32(data >> 216);
        maxNotionalUsd6_ = uint88(data >> 128);
        uint8 reduceFlag = uint8(data >> 120);
        if (reduceFlag > 1) revert HyperCoreInvalidSubstrate(substrate_);
        reduceOnlyRequired_ = reduceFlag == 1;
    }

    /// @notice Encodes an aggregate position cap for one perp market (IL-8534).
    /// @dev Layout: asset in data bits 247..216, cap (USD6) in bits 215..128, low 128 bits zero.
    function encodePerpPositionCap(uint32 asset_, uint88 maxPositionNotionalUsd6_) internal pure returns (bytes32) {
        return
            _word(SubstrateType.PerpPositionCap, (uint256(asset_) << 216) | (uint256(maxPositionNotionalUsd6_) << 128));
    }

    function decodePerpPositionCap(
        bytes32 substrate_
    ) internal pure returns (uint32 asset_, uint88 maxPositionNotionalUsd6_) {
        _checkType(substrate_, SubstrateType.PerpPositionCap);
        uint256 data = uint256(substrate_) & _DATA_MASK;
        if ((data >> 248) != 0 || (data & ((uint256(1) << 128) - 1)) != 0) {
            revert HyperCoreInvalidSubstrate(substrate_);
        }
        asset_ = uint32(data >> 216);
        maxPositionNotionalUsd6_ = uint88(data >> 128);
    }

    function encodeDestination(address destination_) internal pure returns (bytes32) {
        return _word(SubstrateType.Destination, uint160(destination_));
    }

    function decodeDestination(bytes32 substrate_) internal pure returns (address destination_) {
        _checkType(substrate_, SubstrateType.Destination);
        uint256 data = uint256(substrate_) & _DATA_MASK;
        if (data >> 160 != 0) revert HyperCoreInvalidSubstrate(substrate_);
        destination_ = address(uint160(data));
    }

    function encodeBuilder(address builder_, uint64 maxFeeRateDecibps_) internal pure returns (bytes32) {
        return _word(SubstrateType.Builder, (uint256(maxFeeRateDecibps_) << 160) | uint160(builder_));
    }

    function decodeBuilder(bytes32 substrate_) internal pure returns (address builder_, uint64 maxFeeRateDecibps_) {
        _checkType(substrate_, SubstrateType.Builder);
        uint256 data = uint256(substrate_) & _DATA_MASK;
        if (data >> 224 != 0) revert HyperCoreInvalidSubstrate(substrate_);
        maxFeeRateDecibps_ = uint64(data >> 160);
        builder_ = address(uint160(data));
    }

    function encodeConfig(ConfigKey key_, uint240 value_) internal pure returns (bytes32) {
        if (key_ == ConfigKey.Undefined || uint8(key_) > uint8(ConfigKey.NavJumpFloorUsd6)) {
            revert HyperCoreInvalidConfigKey(uint8(key_));
        }
        return _word(SubstrateType.Config, (uint256(uint8(key_)) << 240) | uint240(value_));
    }

    function decodeConfig(bytes32 substrate_) internal pure returns (ConfigKey key_, uint240 value_) {
        _checkType(substrate_, SubstrateType.Config);
        uint256 data = uint256(substrate_) & _DATA_MASK;
        uint8 rawKey = uint8(data >> 240);
        if (rawKey == uint8(ConfigKey.Undefined) || rawKey > uint8(ConfigKey.NavJumpFloorUsd6)) {
            revert HyperCoreInvalidConfigKey(rawKey);
        }
        key_ = ConfigKey(rawKey);
        value_ = uint240(data);
    }

    function encodeSendCap(uint64 tokenIndex_, uint128 maxWei_) internal pure returns (bytes32) {
        return _word(SubstrateType.SendCap, (uint256(tokenIndex_) << 128) | uint128(maxWei_));
    }

    function decodeSendCap(bytes32 substrate_) internal pure returns (uint64 tokenIndex_, uint128 maxWei_) {
        _checkType(substrate_, SubstrateType.SendCap);
        uint256 data = uint256(substrate_) & _DATA_MASK;
        if (data >> 192 != 0) revert HyperCoreInvalidSubstrate(substrate_);
        tokenIndex_ = uint64(data >> 128);
        maxWei_ = uint128(data);
    }

    function substrateType(bytes32 substrate_) internal pure returns (SubstrateType) {
        uint8 flag = uint8(uint256(substrate_) >> _FLAG_SHIFT);
        if (flag > uint8(SubstrateType.PerpPositionCap)) return SubstrateType.Undefined;
        return SubstrateType(flag);
    }

    /// @notice Returns the validated configured HIP-3 dex bitmap; native dex zero is implicit.
    function getPerpDexBitmap(uint256 marketId_) internal view returns (uint240 bitmap_) {
        (, bitmap_) = getConfig(marketId_, ConfigKey.PerpDexIds);
        uint256 supportedMask = HyperCoreSupportedDexLib.supportedHip3DexMask();
        if ((uint256(bitmap_) & ~supportedMask) != 0) {
            revert HyperCoreUnsupportedPerpDexConfig(bitmap_);
        }
    }

    /// @notice Reports whether a dex is enabled, validating the entire bitmap first.
    function isPerpDexConfigured(uint256 marketId_, uint32 dex_) internal view returns (bool) {
        uint240 bitmap = getPerpDexBitmap(marketId_);
        if (dex_ == 0) return true;
        if (dex_ >= PERP_DEX_BITMAP_BITS || !HyperCoreSupportedDexLib.isSupportedPerpDex(dex_)) return false;
        return (bitmap & (uint240(1) << dex_)) != 0;
    }

    /// @notice Counts each granted PerpMarket substrate and summarizes its asset family.
    /// @dev `soleAsset_` is zero unless exactly one PerpMarket substrate is granted.
    function getPerpMarketStats(
        uint256 marketId_
    ) internal view returns (uint256 count_, bool hasHip3_, uint32 soleAsset_) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
        for (uint256 i; i < substrates.length; ++i) {
            if (substrateType(substrates[i]) != SubstrateType.PerpMarket) continue;
            (uint32 asset, , ) = decodePerpMarket(substrates[i]);
            ++count_;
            if (HyperCoreAssetIdLib.isHip3Asset(asset)) hasHip3_ = true;
            if (count_ == 1) soleAsset_ = asset;
            else soleAsset_ = 0;
        }
    }

    function getSpotToken(
        uint256 marketId_,
        uint64 tokenIndex_
    ) internal view returns (bool granted_, address evmAsset_) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
        for (uint256 i; i < substrates.length; ++i) {
            if (substrateType(substrates[i]) == SubstrateType.SpotToken) {
                (uint64 index, address asset) = decodeSpotToken(substrates[i]);
                if (index == tokenIndex_) return (true, asset);
            }
        }
    }

    function getPerpMarket(
        uint256 marketId_,
        uint32 asset_
    ) internal view returns (bool granted_, uint88 maxNotionalUsd6_, bool reduceOnlyRequired_) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
        for (uint256 i; i < substrates.length; ++i) {
            if (substrateType(substrates[i]) == SubstrateType.PerpMarket) {
                (uint32 asset, uint88 cap, bool reduceOnly) = decodePerpMarket(substrates[i]);
                if (asset == asset_) return (true, cap, reduceOnly);
            }
        }
    }

    function isDestinationGranted(uint256 marketId_, address destination_) internal view returns (bool) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
        for (uint256 i; i < substrates.length; ++i) {
            if (
                substrateType(substrates[i]) == SubstrateType.Destination &&
                decodeDestination(substrates[i]) == destination_
            ) return true;
        }
        return false;
    }

    function getBuilder(
        uint256 marketId_,
        address builder_
    ) internal view returns (bool granted_, uint64 maxFeeRateDecibps_) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
        for (uint256 i; i < substrates.length; ++i) {
            if (substrateType(substrates[i]) == SubstrateType.Builder) {
                (address builder, uint64 cap) = decodeBuilder(substrates[i]);
                if (builder == builder_) return (true, cap);
            }
        }
    }

    function getConfig(uint256 marketId_, ConfigKey key_) internal view returns (bool set_, uint240 value_) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
        for (uint256 i; i < substrates.length; ++i) {
            if (substrateType(substrates[i]) == SubstrateType.Config) {
                (ConfigKey key, uint240 value) = decodeConfig(substrates[i]);
                if (key == key_) {
                    if (set_) revert HyperCoreDuplicateConfig(key_);
                    (set_, value_) = (true, value);
                }
            }
        }
    }

    function getSendCap(uint256 marketId_, uint64 tokenIndex_) internal view returns (bool set_, uint128 maxWei_) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
        for (uint256 i; i < substrates.length; ++i) {
            if (substrateType(substrates[i]) == SubstrateType.SendCap) {
                (uint64 index, uint128 cap) = decodeSendCap(substrates[i]);
                if (index == tokenIndex_) {
                    if (set_) revert HyperCoreInvalidSubstrate(substrates[i]);
                    (set_, maxWei_) = (true, cap);
                }
            }
        }
    }

    /// @notice Returns the aggregate position cap granted for `asset_`, if any.
    /// @dev A duplicate cap for the same asset is rejected (same policy as `SendCap`). Not granted means only the
    ///      per-order `PerpMarket` cap applies.
    function getPerpPositionCap(uint256 marketId_, uint32 asset_) internal view returns (bool set_, uint88 cap_) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
        for (uint256 i; i < substrates.length; ++i) {
            if (substrateType(substrates[i]) == SubstrateType.PerpPositionCap) {
                (uint32 asset, uint88 cap) = decodePerpPositionCap(substrates[i]);
                if (asset == asset_) {
                    if (set_) revert HyperCoreInvalidSubstrate(substrates[i]);
                    (set_, cap_) = (true, cap);
                }
            }
        }
    }

    function getSpotTokens(
        uint256 marketId_
    ) internal view returns (uint64[] memory tokenIndexes_, address[] memory evmAssets_) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
        uint256 count;
        for (uint256 i; i < substrates.length; ++i) {
            if (substrateType(substrates[i]) != SubstrateType.SpotToken) continue;
            (uint64 tokenIndex, ) = decodeSpotToken(substrates[i]);
            bool seen;
            for (uint256 previous; previous < i; ++previous) {
                if (substrateType(substrates[previous]) == SubstrateType.SpotToken) {
                    (uint64 earlierIndex, ) = decodeSpotToken(substrates[previous]);
                    if (earlierIndex == tokenIndex) {
                        seen = true;
                        break;
                    }
                }
            }
            if (!seen) ++count;
        }
        tokenIndexes_ = new uint64[](count);
        evmAssets_ = new address[](count);
        uint256 j;
        for (uint256 i; i < substrates.length; ++i) {
            if (substrateType(substrates[i]) != SubstrateType.SpotToken) continue;
            (uint64 tokenIndex, address evmAsset) = decodeSpotToken(substrates[i]);
            bool seen;
            for (uint256 k; k < j; ++k) {
                if (tokenIndexes_[k] == tokenIndex) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                tokenIndexes_[j] = tokenIndex;
                evmAssets_[j] = evmAsset;
                ++j;
            }
        }
    }

    function _word(SubstrateType kind_, uint256 data_) private pure returns (bytes32) {
        if (data_ > _DATA_MASK) revert HyperCoreValueOutOfRange();
        return bytes32((uint256(uint8(kind_)) << _FLAG_SHIFT) | data_);
    }

    function _checkType(bytes32 substrate_, SubstrateType expected_) private pure {
        if (substrateType(substrate_) != expected_) revert HyperCoreInvalidSubstrate(substrate_);
    }
}
