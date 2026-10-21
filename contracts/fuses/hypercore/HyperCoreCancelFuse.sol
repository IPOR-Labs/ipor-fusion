// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {HyperCoreLib} from "./lib/HyperCoreLib.sol";
import {HyperCoreAssetIdLib} from "./lib/HyperCoreAssetIdLib.sol";
import {HyperCoreSupportedDexLib} from "./lib/HyperCoreSupportedDexLib.sol";
import {HyperCoreSubstrateLib} from "./lib/HyperCoreSubstrateLib.sol";
import {HyperCorePendingLib} from "./lib/HyperCorePendingLib.sol";

/// @dev Data structure for entering the HyperCore cancel-by-oid fuse (action 10)
struct HyperCoreCancelFuseCancelByOidData {
    /// @notice HyperCore perp asset index
    uint32 asset;
    /// @notice HyperCore order id to cancel
    uint64 oid;
}

/// @dev Data structure for entering the HyperCore cancel-by-cloid fuse (action 11)
struct HyperCoreCancelFuseCancelByCloidData {
    /// @notice HyperCore perp asset index
    uint32 asset;
    /// @notice Client order id to cancel
    uint128 cloid;
}

/// @title HyperCoreCancelFuse
/// @author IPOR Labs
/// @notice Cancels a resting perp order on HyperCore by oid or client order id
///         (CoreWriter actions 10 and 11).
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
///      Cancels create no pending record and touch no rate limit (IL-8527/IL-8543); the legacy
///      `Config{SettlementMode}` / `Config{WindowOrderSeconds}` keys are ignored.
contract HyperCoreCancelFuse is IFuseCommon {
    /// @notice The address of the version of the Fuse
    address public immutable VERSION;
    /// @notice The Market ID associated with the Fuse
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when entering the HyperCore cancel-by-oid fuse
    event HyperCoreCancelFuseCancelByOid(address version, uint32 asset, uint64 oid);

    /// @notice Emitted when entering the HyperCore cancel-by-cloid fuse
    event HyperCoreCancelFuseCancelByCloid(address version, uint32 asset, uint128 cloid);

    /// @notice Thrown when the market ID passed to the constructor is zero
    error HyperCoreCancelFuseInvalidMarketId();

    /// @notice Thrown when the vault's HyperCore account does not exist yet
    error HyperCoreCancelFuseAccountNotActivated();

    /// @notice Thrown when the perp asset is not granted as a PerpMarket substrate
    error HyperCoreCancelFuseMarketNotGranted(uint32 asset);

    /// @notice Thrown when the action asset belongs to an unsupported perp dex.
    error HyperCoreCancelFuseUnsupportedPerpDex(uint32 dex);

    /// @notice Thrown when the action asset dex is not enabled by this market.
    error HyperCoreCancelFusePerpDexNotConfigured(uint32 dex);

    /// @notice Thrown when `oid` is zero
    error HyperCoreCancelFuseOidRequired();

    /// @notice Thrown when `cloid` is zero
    error HyperCoreCancelFuseCloidRequired();

    /// @notice Constructor for HyperCoreCancelFuse
    /// @param marketId_ The Market ID associated with the Fuse
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert HyperCoreCancelFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Cancels a resting perp order by HyperCore order id
    /// @param data_ Enter data containing the perp asset and the order id
    function enterCancelByOid(HyperCoreCancelFuseCancelByOidData memory data_) public {
        if (data_.oid == 0) {
            revert HyperCoreCancelFuseOidRequired();
        }

        _validate(data_.asset);

        bytes memory payload = HyperCoreLib.encodeCancelByOid(data_.asset, data_.oid);
        HyperCoreLib.sendRawAction(payload);

        emit HyperCoreCancelFuseCancelByOid(VERSION, data_.asset, data_.oid);
    }

    /// @notice Cancels a resting perp order by client order id
    /// @param data_ Enter data containing the perp asset and the client order id
    function enterCancelByCloid(HyperCoreCancelFuseCancelByCloidData memory data_) public {
        if (data_.cloid == 0) {
            revert HyperCoreCancelFuseCloidRequired();
        }

        _validate(data_.asset);

        bytes memory payload = HyperCoreLib.encodeCancelByCloid(data_.asset, data_.cloid);
        HyperCoreLib.sendRawAction(payload);

        emit HyperCoreCancelFuseCancelByCloid(VERSION, data_.asset, data_.cloid);
    }

    /// @dev Requires the asset's dex to be supported on this chain and enabled for this market.
    function _validatePerpAssetDex(uint32 asset_) internal view {
        uint32 dex = HyperCoreAssetIdLib.perpDexOf(asset_);
        if (!HyperCoreSupportedDexLib.isSupportedPerpDex(dex)) {
            revert HyperCoreCancelFuseUnsupportedPerpDex(dex);
        }
        if (!HyperCoreSubstrateLib.isPerpDexConfigured(MARKET_ID, dex)) {
            revert HyperCoreCancelFusePerpDexNotConfigured(dex);
        }
    }

    /// @dev Shared validation for both cancel entry points.
    function _validate(uint32 asset_) internal view {
        HyperCorePendingLib.requireNotPendingAction();

        if (!HyperCoreLib.coreUserExists(address(this))) {
            revert HyperCoreCancelFuseAccountNotActivated();
        }

        (bool granted, , ) = HyperCoreSubstrateLib.getPerpMarket(MARKET_ID, asset_);
        if (!granted) {
            revert HyperCoreCancelFuseMarketNotGranted(asset_);
        }

        _validatePerpAssetDex(asset_);
    }
}
