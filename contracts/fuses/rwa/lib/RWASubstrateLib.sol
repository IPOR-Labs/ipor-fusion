// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../../libraries/PlasmaVaultConfigLib.sol";
import {RWAErrors} from "../errors/RWAErrors.sol";

/// @notice Type discriminator for RWA substrates. Encoded in the most significant byte
///         of the bytes32 substrate value.
/// @dev Matches the pattern used by UniversalTokenSwapperSubstrateLib:
///      `[type (8 bits) | payload (248 bits)]`.
enum RWASubstrateType {
    UNDEFINED, // 0 - invalid
    ASSET, // 1 - address payload (allowed asset for enter/exit accounting)
    TARGET, // 2 - address (160 bits) | bytes4 selector (32 bits) — allowed target+selector tuple
    CUSTODIAN, // 3 - address payload — authorized propose/confirm caller
    BALANCE_ACCOUNT, // 4 - address payload — balance account receiving add/remove operations
    STALENESS_MAX, // 5 - uint248 seconds — maximum staleness before user ops are blocked
    BIG_CHANGE_BPS, // 6 - uint248 basis points — threshold above which pause is triggered
    DUST_THRESHOLD, // 7 - uint248 percent of one token — dust check scaling
    MIN_UPDATE_INTERVAL // 8 - uint248 seconds — minimum delay between confirmed balance updates
}

/// @title RWASubstrateLib
/// @notice Library for encoding, decoding, and validating RWA substrates as bytes32 values.
/// @dev Substrates are stored per market via `PlasmaVaultConfigLib`. The library is `internal pure`
///      and therefore inlined into callers; it never holds state.
/// @author IPOR Labs
library RWASubstrateLib {
    /// @dev Bit offset of the 8-bit type discriminator inside bytes32.
    uint256 private constant _TYPE_SHIFT = 248;

    /// @dev Mask covering the lowest 248 bits (payload area).
    uint256 private constant _PAYLOAD_MASK = type(uint248).max;

    /// @dev Mask covering the lowest 160 bits (address payload).
    uint256 private constant _ADDRESS_MASK = uint256(uint160(type(uint160).max));

    /// @dev Mask covering the 32 bits immediately above the address payload (bytes4 selector).
    uint256 private constant _SELECTOR_MASK = uint256(uint32(type(uint32).max));

    /// @dev Bit offset of the bytes4 selector inside TARGET encoding.
    uint256 private constant _SELECTOR_SHIFT = 160;

    // ============================================================
    // Encoders — single-address substrates
    // ============================================================

    /// @notice Encode an ASSET substrate (allowed asset address).
    /// @param asset_ The asset contract address (e.g. USDC).
    /// @return encoded The bytes32-encoded substrate with the ASSET type discriminator.
    function encodeAssetSubstrate(address asset_) internal pure returns (bytes32 encoded) {
        if (asset_ == address(0)) revert RWAErrors.RWAZeroAddress();
        encoded = bytes32((uint256(RWASubstrateType.ASSET) << _TYPE_SHIFT) | uint256(uint160(asset_)));
    }

    /// @notice Encode a CUSTODIAN substrate.
    /// @param custodian_ Authorized custodian address allowed to propose/confirm balance updates.
    /// @return encoded The bytes32-encoded substrate with the CUSTODIAN type discriminator.
    function encodeCustodianSubstrate(address custodian_) internal pure returns (bytes32 encoded) {
        if (custodian_ == address(0)) revert RWAErrors.RWAZeroAddress();
        encoded = bytes32((uint256(RWASubstrateType.CUSTODIAN) << _TYPE_SHIFT) | uint256(uint160(custodian_)));
    }

    /// @notice Encode a BALANCE_ACCOUNT substrate.
    /// @param balanceAccount_ Balance account address (logical bucket under the executor).
    /// @return encoded The bytes32-encoded substrate with the BALANCE_ACCOUNT type discriminator.
    function encodeBalanceAccountSubstrate(address balanceAccount_) internal pure returns (bytes32 encoded) {
        if (balanceAccount_ == address(0)) revert RWAErrors.RWAZeroAddress();
        encoded =
            bytes32((uint256(RWASubstrateType.BALANCE_ACCOUNT) << _TYPE_SHIFT) | uint256(uint160(balanceAccount_)));
    }

    // ============================================================
    // Encoders — TARGET substrate (address + selector)
    // ============================================================

    /// @notice Encode a TARGET substrate binding a target contract and a bytes4 selector.
    /// @param target_ Target contract address.
    /// @param selector_ Function selector allowed on the target.
    /// @return encoded The bytes32-encoded substrate with the TARGET type discriminator.
    function encodeTargetSubstrate(address target_, bytes4 selector_) internal pure returns (bytes32 encoded) {
        if (target_ == address(0)) revert RWAErrors.RWAZeroAddress();
        encoded = bytes32(
            (uint256(RWASubstrateType.TARGET) << _TYPE_SHIFT) | (uint256(uint32(selector_)) << _SELECTOR_SHIFT)
                | uint256(uint160(target_))
        );
    }

    // ============================================================
    // Encoders — uint248 singleton substrates
    // ============================================================

    /// @notice Encode a STALENESS_MAX substrate (seconds).
    /// @param secondsValue_ Maximum staleness in seconds before user operations are blocked.
    /// @return encoded The bytes32-encoded substrate with the STALENESS_MAX type discriminator.
    function encodeStalenessMaxSubstrate(uint256 secondsValue_) internal pure returns (bytes32 encoded) {
        if (secondsValue_ > type(uint248).max) {
            revert RWAErrors.RWASubstratePayloadOverflow(uint8(RWASubstrateType.STALENESS_MAX), secondsValue_);
        }
        encoded = bytes32((uint256(RWASubstrateType.STALENESS_MAX) << _TYPE_SHIFT) | secondsValue_);
    }

    /// @notice Encode a BIG_CHANGE_BPS substrate (basis points).
    /// @param bps_ Threshold in basis points at which the balance fuse triggers a pause.
    /// @return encoded The bytes32-encoded substrate with the BIG_CHANGE_BPS type discriminator.
    function encodeBigChangeBpsSubstrate(uint256 bps_) internal pure returns (bytes32 encoded) {
        if (bps_ > type(uint248).max) {
            revert RWAErrors.RWASubstratePayloadOverflow(uint8(RWASubstrateType.BIG_CHANGE_BPS), bps_);
        }
        encoded = bytes32((uint256(RWASubstrateType.BIG_CHANGE_BPS) << _TYPE_SHIFT) | bps_);
    }

    /// @notice Encode a DUST_THRESHOLD substrate.
    /// @param percent_ Percent of one token (scaled 1e0 == 1%, i.e. 100 == 1x the base token unit).
    /// @return encoded The bytes32-encoded substrate with the DUST_THRESHOLD type discriminator.
    function encodeDustThresholdSubstrate(uint256 percent_) internal pure returns (bytes32 encoded) {
        if (percent_ > type(uint248).max) {
            revert RWAErrors.RWASubstratePayloadOverflow(uint8(RWASubstrateType.DUST_THRESHOLD), percent_);
        }
        encoded = bytes32((uint256(RWASubstrateType.DUST_THRESHOLD) << _TYPE_SHIFT) | percent_);
    }

    /// @notice Encode a MIN_UPDATE_INTERVAL substrate (seconds).
    /// @param secondsValue_ Minimum time between confirmed custodian balance updates.
    /// @return encoded The bytes32-encoded substrate with the MIN_UPDATE_INTERVAL type discriminator.
    function encodeMinUpdateIntervalSubstrate(uint256 secondsValue_) internal pure returns (bytes32 encoded) {
        if (secondsValue_ > type(uint248).max) {
            revert RWAErrors.RWASubstratePayloadOverflow(uint8(RWASubstrateType.MIN_UPDATE_INTERVAL), secondsValue_);
        }
        encoded = bytes32((uint256(RWASubstrateType.MIN_UPDATE_INTERVAL) << _TYPE_SHIFT) | secondsValue_);
    }

    // ============================================================
    // Decoders
    // ============================================================

    /// @notice Decode the 8-bit substrate type discriminator.
    /// @param substrate_ The encoded substrate.
    /// @return substrateType The decoded `RWASubstrateType` enum value.
    function decodeSubstrateType(bytes32 substrate_) internal pure returns (RWASubstrateType substrateType) {
        uint8 raw = uint8(uint256(substrate_) >> _TYPE_SHIFT);
        // Any value past the enum range would revert on cast; we guard explicitly to produce a
        // more informative error and to stay within the documented type set.
        if (raw > uint8(RWASubstrateType.MIN_UPDATE_INTERVAL)) {
            revert RWAErrors.RWAUnsupportedSubstrate(raw, substrate_);
        }
        substrateType = RWASubstrateType(raw);
    }

    /// @notice Decode the 160-bit address payload (for ASSET / CUSTODIAN / BALANCE_ACCOUNT substrates).
    /// @param substrate_ The encoded substrate.
    /// @return decoded The decoded address.
    function decodeAddressPayload(bytes32 substrate_) internal pure returns (address decoded) {
        decoded = address(uint160(uint256(substrate_) & _ADDRESS_MASK));
    }

    /// @notice Decode the TARGET payload (address + selector).
    /// @param substrate_ The encoded substrate.
    /// @return target The target contract address.
    /// @return selector The bytes4 function selector.
    function decodeTargetPayload(bytes32 substrate_) internal pure returns (address target, bytes4 selector) {
        uint256 raw = uint256(substrate_);
        target = address(uint160(raw & _ADDRESS_MASK));
        selector = bytes4(uint32((raw >> _SELECTOR_SHIFT) & _SELECTOR_MASK));
    }

    /// @notice Decode the 248-bit scalar payload (for STALENESS_MAX, BIG_CHANGE_BPS, etc.).
    /// @param substrate_ The encoded substrate.
    /// @return value The decoded uint256 scalar (always within uint248 range).
    function decodeUint248Payload(bytes32 substrate_) internal pure returns (uint256 value) {
        value = uint256(substrate_) & _PAYLOAD_MASK;
    }

    // ============================================================
    // Classifiers
    // ============================================================

    function isAssetSubstrate(bytes32 substrate_) internal pure returns (bool) {
        return decodeSubstrateType(substrate_) == RWASubstrateType.ASSET;
    }

    function isTargetSubstrate(bytes32 substrate_) internal pure returns (bool) {
        return decodeSubstrateType(substrate_) == RWASubstrateType.TARGET;
    }

    function isCustodianSubstrate(bytes32 substrate_) internal pure returns (bool) {
        return decodeSubstrateType(substrate_) == RWASubstrateType.CUSTODIAN;
    }

    function isBalanceAccountSubstrate(bytes32 substrate_) internal pure returns (bool) {
        return decodeSubstrateType(substrate_) == RWASubstrateType.BALANCE_ACCOUNT;
    }

    function isStalenessMaxSubstrate(bytes32 substrate_) internal pure returns (bool) {
        return decodeSubstrateType(substrate_) == RWASubstrateType.STALENESS_MAX;
    }

    function isBigChangeBpsSubstrate(bytes32 substrate_) internal pure returns (bool) {
        return decodeSubstrateType(substrate_) == RWASubstrateType.BIG_CHANGE_BPS;
    }

    function isDustThresholdSubstrate(bytes32 substrate_) internal pure returns (bool) {
        return decodeSubstrateType(substrate_) == RWASubstrateType.DUST_THRESHOLD;
    }

    function isMinUpdateIntervalSubstrate(bytes32 substrate_) internal pure returns (bool) {
        return decodeSubstrateType(substrate_) == RWASubstrateType.MIN_UPDATE_INTERVAL;
    }

    // ============================================================
    // Grant validators — revert if not configured for marketId
    // ============================================================

    /// @notice Revert if the ASSET substrate for `asset_` is not granted to the market.
    /// @param marketId_ The market identifier whose substrates to inspect.
    /// @param asset_ The asset address to validate.
    function validateAssetGranted(uint256 marketId_, address asset_) internal view {
        bytes32 encoded = encodeAssetSubstrate(asset_);
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(marketId_, encoded)) {
            revert RWAErrors.RWAUnsupportedSubstrate(uint8(RWASubstrateType.ASSET), encoded);
        }
    }

    /// @notice Revert if the BALANCE_ACCOUNT substrate for `balanceAccount_` is not granted.
    /// @param marketId_ The market identifier whose substrates to inspect.
    /// @param balanceAccount_ The balance account address to validate.
    function validateBalanceAccountGranted(uint256 marketId_, address balanceAccount_) internal view {
        bytes32 encoded = encodeBalanceAccountSubstrate(balanceAccount_);
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(marketId_, encoded)) {
            revert RWAErrors.RWAUnsupportedSubstrate(uint8(RWASubstrateType.BALANCE_ACCOUNT), encoded);
        }
    }

    /// @notice Revert if the TARGET substrate for the target/selector tuple is not granted.
    /// @param marketId_ The market identifier whose substrates to inspect.
    /// @param target_ The target contract address.
    /// @param selector_ The function selector allowed on that target.
    function validateTargetSelectorGranted(uint256 marketId_, address target_, bytes4 selector_) internal view {
        bytes32 encoded = encodeTargetSubstrate(target_, selector_);
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(marketId_, encoded)) {
            revert RWAErrors.RWAUnsupportedSubstrate(uint8(RWASubstrateType.TARGET), encoded);
        }
    }
}
