// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {IExternalStateExecutor} from "./IExternalStateExecutor.sol";
import {ExternalStateErrors} from "./errors/ExternalStateErrors.sol";
import {ExternalStateExecutorStorageLib} from "./lib/ExternalStateExecutorStorageLib.sol";

/// @title ExternalStateRescueFuse
/// @notice Fuse for sweeping stuck or airdropped tokens from the ExternalState executor back to the vault.
///         Does not touch tracked balances — it only transfers the executor's current token balance.
/// @dev Runs via delegatecall from PlasmaVault. Only the vault can invoke `execute` on the executor,
///      so this fuse is the documented entry-point to perform the sweep in a governed way.
/// @author IPOR Labs
contract ExternalStateRescueFuse is IFuseCommon {
    /// @notice Deployment address captured at construction.
    address public immutable VERSION;

    /// @notice Market identifier bound to this fuse instance.
    uint256 public immutable override MARKET_ID;

    /// @notice Emitted after a rescue call successfully completes.
    event ExternalStateAssetRescued(address asset);

    /// @param marketId_ Market identifier this fuse serves (must be non-zero).
    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert ExternalStateErrors.ExternalStateZeroMarketId();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Sweep the executor's entire balance of `asset_` back to the vault.
    /// @dev Reverts with `ExternalStateZeroAddress` when `asset_ == address(0)` to surface a clear error
    ///      instead of the opaque EVM revert that would bubble up from
    ///      `IERC20(address(0)).balanceOf(...)`.
    /// @dev Reverts with `ExternalStateRescueOfTrackedAssetForbidden(asset_)` when `asset_` is currently
    ///      registered as an ASSET substrate on the executor. Rescue is intended for airdrops
    ///      and accidentally transferred tokens only — moving a tracked asset out-of-band would
    ///      desynchronize strategy state between custodian confirms.
    /// @param asset_ ERC20 asset to rescue (airdropped / untracked). MUST NOT be zero and MUST NOT
    ///        be a currently registered ASSET substrate.
    function rescue(address asset_) external {
        if (asset_ == address(0)) revert ExternalStateErrors.ExternalStateZeroAddress();
        address executor = ExternalStateExecutorStorageLib.getExecutor();
        if (executor == address(0)) revert ExternalStateErrors.ExternalStateRescueExecutorNotDeployed();

        IExternalStateExecutor executor_ = IExternalStateExecutor(executor);
        uint256 assetsLen = executor_.assetsLength();
        for (uint256 i; i < assetsLen; ++i) {
            if (executor_.assets(i) == asset_) {
                revert ExternalStateErrors.ExternalStateRescueOfTrackedAssetForbidden(asset_);
            }
        }

        executor_.withdrawAssetBalance(asset_);
        emit ExternalStateAssetRescued(asset_);
    }
}
