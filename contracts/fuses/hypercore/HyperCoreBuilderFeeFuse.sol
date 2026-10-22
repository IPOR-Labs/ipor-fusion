// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {HyperCoreLib} from "./lib/HyperCoreLib.sol";
import {HyperCoreSubstrateLib} from "./lib/HyperCoreSubstrateLib.sol";
import {HyperCorePendingLib} from "./lib/HyperCorePendingLib.sol";
import {HyperCoreValuationLib} from "./lib/HyperCoreValuationLib.sol";

/// @dev Data structure for entering the HyperCore builder fee fuse (action 12)
struct HyperCoreBuilderFeeFuseEnterData {
    /// @notice Builder address (granted as a Builder substrate)
    address builder;
    /// @notice Maximum fee rate to approve, in decibasis points
    uint64 maxFeeRateDecibps;
}

/// @title HyperCoreBuilderFeeFuse
/// @author IPOR Labs
/// @notice Approves a maximum builder fee rate for a granted builder on HyperCore
///         (CoreWriter action 12, approveBuilderFee).
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
contract HyperCoreBuilderFeeFuse is IFuseCommon {
    /// @notice The address of the version of the Fuse
    address public immutable VERSION;
    /// @notice The Market ID associated with the Fuse
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when entering the HyperCore builder fee fuse
    event HyperCoreBuilderFeeFuseEnter(address version, address builder, uint64 maxFeeRateDecibps);

    /// @notice Thrown when the market ID passed to the constructor is zero
    error HyperCoreBuilderFeeFuseInvalidMarketId();

    /// @notice Thrown when the vault's HyperCore account does not exist yet
    error HyperCoreBuilderFeeFuseAccountNotActivated();

    /// @notice Thrown when the builder is not granted as a Builder substrate
    error HyperCoreBuilderFeeFuseBuilderNotGranted(address builder);

    /// @notice Thrown when the requested max fee rate exceeds the granted cap
    error HyperCoreBuilderFeeFuseExceedsMaxRate(uint64 requested, uint64 maxAllowed);

    /// @notice Thrown when the configured transfer-class window is zero or exceeds `type(uint64).max`
    error HyperCoreBuilderFeeFuseInvalidWindow(uint240 value);

    /// @notice Constructor for HyperCoreBuilderFeeFuse
    /// @param marketId_ The Market ID associated with the Fuse
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert HyperCoreBuilderFeeFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Approves a maximum builder fee rate for a granted builder
    /// @param data_ Enter data containing the builder address and the max fee rate to approve
    function enter(HyperCoreBuilderFeeFuseEnterData memory data_) public {
        HyperCorePendingLib.requireNotPendingAction();

        if (!HyperCoreLib.coreUserExists(address(this))) {
            revert HyperCoreBuilderFeeFuseAccountNotActivated();
        }

        (bool granted, uint64 maxRate) = HyperCoreSubstrateLib.getBuilder(MARKET_ID, data_.builder);
        if (!granted) {
            revert HyperCoreBuilderFeeFuseBuilderNotGranted(data_.builder);
        }

        if (data_.maxFeeRateDecibps > maxRate) {
            revert HyperCoreBuilderFeeFuseExceedsMaxRate(data_.maxFeeRateDecibps, maxRate);
        }

        uint256 s = HyperCoreValuationLib.liveValueWad(MARKET_ID);

        bytes memory payload = HyperCoreLib.encodeApproveBuilderFee(data_.maxFeeRateDecibps, data_.builder);
        HyperCoreLib.sendRawAction(payload);

        HyperCorePendingLib.enqueue(
            s,
            _windowTransfer(),
            HyperCoreLib.ACTION_APPROVE_BUILDER_FEE,
            keccak256(payload)
        );

        emit HyperCoreBuilderFeeFuseEnter(VERSION, data_.builder, data_.maxFeeRateDecibps);
    }

    /// @dev Reads the configured transfer-class settlement window; defaults to 2 seconds when unset.
    function _windowTransfer() internal view returns (uint64) {
        (bool set, uint240 value) = HyperCoreSubstrateLib.getConfig(
            MARKET_ID,
            HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds
        );
        if (!set) {
            return 2;
        }
        if (value == 0 || value > type(uint64).max) {
            revert HyperCoreBuilderFeeFuseInvalidWindow(value);
        }
        return uint64(value);
    }
}
