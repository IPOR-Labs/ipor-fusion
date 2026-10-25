// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {ICrosschainExecutor} from "../../crosschain/interfaces/ICrosschainExecutor.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {CrosschainSubstrateLib, IExecutorAssetView} from "./lib/CrosschainSubstrateLib.sol";
import {CrosschainRecoveryLib} from "./lib/CrosschainRecoveryLib.sol";

/// @notice Data for claiming idle executor assets from a crosschain executor back into the PlasmaVault.
/// @param executor The crosschain executor (Stargate or CCIP) to claim from (must be a granted EXECUTOR substrate).
/// @param amount Amount of the executor asset to claim (local ASSET decimals). The executor transfers
///        `min(amount, toLD(idleLedger))` floored to the shared-decimals unit — untracked donations/unreconciled
///        arrivals are rescue-only by design.
struct CrosschainClaimFuseEnterData {
    address executor;
    uint256 amount;
}

/// @title CrosschainClaimFuse
/// @notice Stateless fuse (delegatecall from PlasmaVault) that pulls settled idle executor assets
///         back to the vault. Mirrors `MidasClaimFromExecutorFuse`.
/// @dev Runs in the PlasmaVault storage context. MUST NOT declare storage variables; only `immutable`.
///      The executor's `claimAsset` transfers `min(amount, toLD(idleLedger))`, floored to the shared-decimals
///      unit, to the MANAGER (this vault).
/// @author IPOR Labs
contract CrosschainClaimFuse is IFuseCommon {
    /// @notice Emitted after a claim from the executor.
    /// @param version The address of this fuse contract version.
    /// @param executor The crosschain executor (Stargate or CCIP) claimed from.
    /// @param amount The amount actually received by the vault (measured balance delta), local ASSET decimals.
    event CrosschainClaimFuseClaimed(address version, address executor, uint256 amount);

    /// @notice Thrown when the executor's immutable MANAGER is not this PlasmaVault.
    error CrosschainClaimFuseExecutorManagerMismatch(address executor, address manager);

    /// @notice Thrown when the price oracle middleware is not configured in the PlasmaVault.
    error CrosschainClaimFuseInvalidPriceOracleMiddleware();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Claim `amount` (capped at the executor idle ledger) of the executor's asset back to the vault.
    /// @param data_ The enter data containing the executor and requested amount.
    function enter(CrosschainClaimFuseEnterData memory data_) external {
        if (data_.amount == 0) {
            return;
        }

        CrosschainSubstrateLib.validateExecutorGranted(MARKET_ID, data_.executor);
        // Supply and NAV intentionally support executor assets different from the vault underlying.
        // Claim therefore validates contract identity/manager below, but must not reintroduce an
        // underlying-asset restriction that would strand a recalled multi-asset position.
        if (data_.executor.code.length == 0) {
            revert CrosschainSubstrateLib.CrosschainFuseExecutorNoCode(data_.executor);
        }

        address manager = ICrosschainExecutor(data_.executor).MANAGER();
        if (manager != address(this)) {
            revert CrosschainClaimFuseExecutorManagerMismatch(data_.executor, manager);
        }

        // Measure what actually arrived: the executor caps the transfer at its idle ledger, so the
        // requested amount is an upper bound, not the delta. The measured delta is reported to the
        // recovery context so the balance fuse can remove it from the cached crosschain market value —
        // without that, these assets are counted both in the stale cache and in the vault's own balance
        // (audit H-1). The executor ASSET must transfer exactly (no fee-on-transfer, no rebasing): this
        // correction uses the net amount the vault measured, while the executor debits the gross amount, and
        // the two are equal only for an exact transfer. The asset is owner-configured (timelocked, then frozen) and must
        // not be configured with such tokens (IL-9133).
        address executorAsset = IExecutorAssetView(data_.executor).ASSET();
        uint256 balanceBefore = IERC20(executorAsset).balanceOf(address(this));
        ICrosschainExecutor(data_.executor).claimAsset(data_.amount);
        uint256 claimed = IERC20(executorAsset).balanceOf(address(this)) - balanceBefore;

        if (claimed != 0) {
            uint256 recoveredUsd = _valueInUsd(executorAsset, claimed);
            // A claim is entitled to the fail-closed cache fallback only after it proves that it moved
            // positive, priceable value out of the crosschain market. Arming recovery before the call
            // let an executor with no idle assets (or a zero-valued transfer) preserve an arbitrary stale
            // cache even though the batch recovered nothing (audit C-01).
            if (recoveredUsd != 0) {
                CrosschainRecoveryLib.markRecovery(MARKET_ID, data_.executor);
                CrosschainRecoveryLib.addRecoveredUsd(MARKET_ID, recoveredUsd);
            }
        }

        emit CrosschainClaimFuseClaimed(VERSION, data_.executor, claimed);
    }

    /// @dev Prices `amount_` of `asset_` in 18-decimal USD, matching how `CrosschainBalanceFuse` values
    ///      executor balances (own feed + own decimals, since the executor asset may differ from the
    ///      vault underlying).
    function _valueInUsd(address asset_, uint256 amount_) private view returns (uint256) {
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        if (priceOracleMiddleware == address(0)) revert CrosschainClaimFuseInvalidPriceOracleMiddleware();
        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(asset_);
        return IporMath.convertToWad(amount_ * price, IERC20Metadata(asset_).decimals() + priceDecimals);
    }
}
