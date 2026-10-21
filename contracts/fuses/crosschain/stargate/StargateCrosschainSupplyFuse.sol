// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

import {IFuseCommon} from "../../IFuseCommon.sol";
import {IporMath} from "../../../libraries/math/IporMath.sol";
import {ICrosschainExecutor} from "../../../crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainSubstrateLib} from "../lib/CrosschainSubstrateLib.sol";

/// @notice Intrinsic marker of the Stargate transport: `StargateOAppBase` exposes the local Stargate
///         pool as a public immutable. A CCIP executor has no such getter, so a successful call
///         returning a non-zero pool proves the executor speaks this transport (audit M-5).
interface IStargateTransportProbe {
    function STARGATE_POOL() external view returns (address);
}

/// @notice Local and shared (OFT) decimals of the Stargate executor, from which its dust unit is derived.
interface IStargateDecimals {
    function LOCAL_DECIMALS() external view returns (uint8);

    function SHARED_DECIMALS() external view returns (uint8);
}

import {CrosschainRecoveryLib} from "../lib/CrosschainRecoveryLib.sol";

/// @notice Data for entering the CROSSCHAIN market: bridge capital out to a remote dispatcher.
/// @param executor The StargateCrosschainExecutor to drive (must be a granted EXECUTOR substrate).
/// @param asset The asset to bridge — must equal the executor's `ASSET()`; MAY differ from the vault underlying.
/// @param dstChainId Destination EVM chainId of the dispatcher the assets are sent to.
/// @param amount Amount of `asset` to bridge (local ASSET decimals). Clamped to the vault balance, then floored to
///        the shared-decimals unit (the remainder stays in the vault).
/// @param minAmountLD Minimum amount to be credited on the destination (Stargate slippage bound, local decimals).
/// @param options Transport (LayerZero) options forwarded to the executor's send.
struct StargateCrosschainSupplyFuseEnterData {
    address executor;
    address asset;
    uint256 dstChainId;
    uint256 amount;
    uint256 minAmountLD;
    bytes options;
}

/// @notice Data for exiting the CROSSCHAIN market: request a recall of assets from a remote dispatcher.
/// @dev `exit` only *requests* a recall — no tokens arrive in the same transaction. This fuse therefore
///      MUST NOT be placed in the vault's instant-withdrawal fuse order (plan §5.1 instant-withdraw
///      prohibition); it deliberately does not implement `IFuseInstantWithdraw`.
/// @param executor The StargateCrosschainExecutor to drive (must be a granted EXECUTOR substrate).
/// @param dstChainId Destination EVM chainId of the dispatcher the assets are recalled from.
/// @param amount Amount of the executor's asset to request back (local ASSET decimals).
/// @param minReturn Manager-chosen minimum-return slippage bound for the return leg (local ASSET decimals).
/// @param nativeDrop Native currency delivered to the same-address remote dispatcher before recall execution.
///      The executor's send is bounded by the factory's per-destination native fee ceiling; a native-drop
///      option, whether from this field or from `options`, is paid only within that ceiling.
/// @param options Transport (LayerZero) options forwarded to the executor's recall request.
struct StargateCrosschainSupplyFuseExitData {
    address executor;
    uint256 dstChainId;
    uint256 amount;
    uint256 minReturn;
    uint128 nativeDrop;
    bytes options;
}

/// @title StargateCrosschainSupplyFuse
/// @notice Stateless fuse (delegatecall from PlasmaVault) that moves capital out to a remote chain via the
///         StargateCrosschainExecutor (`enter`) and requests it back (`exit`).
/// @dev Runs in the PlasmaVault storage context. MUST NOT declare storage variables; only `immutable`.
///      Deliberately does NOT implement `IFuseInstantWithdraw` (plan §5.1): `exit` only requests a recall,
///      no tokens settle in the same transaction, and concurrent recalls collide with the executor's
///      one-active-recall rule.
/// @author IPOR Labs
contract StargateCrosschainSupplyFuse is IFuseCommon {
    using SafeERC20 for ERC20;
    using OptionsBuilder for bytes;

    /// @notice Emitted after assets are transferred to the executor and a bridge send is initiated.
    /// @param version The address of this fuse contract version.
    /// @param executor The StargateCrosschainExecutor driven.
    /// @param asset The bridged asset (the executor's `ASSET()`).
    /// @param dstChainId Destination chainId the assets were bridged to.
    /// @param amount The amount actually sent (post vault-balance clamp and shared-decimals floor), local ASSET
    ///        decimals.
    /// @param minAmountLD The destination slippage bound forwarded to the executor.
    event CrosschainSupplyFuseEnter(
        address version, address executor, address asset, uint256 dstChainId, uint256 amount, uint256 minAmountLD
    );

    /// @notice Emitted after a recall of assets is requested from the dispatcher.
    /// @param version The address of this fuse contract version.
    /// @param executor The StargateCrosschainExecutor driven.
    /// @param dstChainId Destination chainId the assets were recalled from.
    /// @param amount The requested recall amount, local ASSET decimals.
    /// @param minReturn The return-leg slippage bound forwarded to the executor.
    event CrosschainSupplyFuseExit(
        address version, address executor, uint256 dstChainId, uint256 amount, uint256 minReturn
    );

    /// @notice Thrown when the executor's immutable MANAGER is not this PlasmaVault.
    error CrosschainSupplyFuseExecutorManagerMismatch(address executor, address manager);

    /// @notice Thrown when the granted executor does not speak the Stargate/LayerZero transport.
    error CrosschainSupplyFuseWrongTransport(address executor);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Transfer up to `amount` of `data_.asset` to the executor, then bridge it to the dispatcher.
    /// @param data_ Enter parameters.
    function enter(StargateCrosschainSupplyFuseEnterData memory data_) external {
        if (data_.amount == 0) {
            return;
        }
        CrosschainRecoveryLib.markNewExposure();

        _validateExecutor(data_.executor);
        // New remote exposure is forbidden while live NAV is fail-closed.
        ICrosschainExecutor(data_.executor).getBalance();
        // Denomination consistency: the bridged asset is chosen per call and must be exactly the asset
        // the executor handles; it MAY differ from the vault underlying.
        CrosschainSubstrateLib.validateExecutorHandlesAsset(data_.executor, data_.asset);

        address asset = data_.asset;

        uint256 amountToSend = IporMath.min(data_.amount, ERC20(asset).balanceOf(address(this)));

        // The executor rejects a send that is not an exact multiple of the shared-decimals unit
        // (`AmountBelowSharedDecimals`). The clamp above makes that reachable by anyone who donates 1 wei to the
        // vault, so floor the amount here; the sub-unit remainder stays in the vault.
        uint256 localDecimals = IStargateDecimals(data_.executor).LOCAL_DECIMALS();
        amountToSend -= amountToSend % (10 ** (localDecimals - IStargateDecimals(data_.executor).SHARED_DECIMALS()));

        if (amountToSend == 0) {
            return;
        }

        ERC20(asset).safeTransfer(data_.executor, amountToSend);

        ICrosschainExecutor(data_.executor)
            .sendAssetToDispatcher(data_.dstChainId, amountToSend, data_.minAmountLD, data_.options);

        emit CrosschainSupplyFuseEnter(
            VERSION, data_.executor, asset, data_.dstChainId, amountToSend, data_.minAmountLD
        );
    }

    /// @notice Request a recall of `amount` from the remote dispatcher back to the executor (idle ledger).
    /// @dev Assets do not arrive in this transaction — a later claim (see `CrosschainClaimFuse`) pulls them home.
    /// @param data_ Exit parameters.
    function exit(StargateCrosschainSupplyFuseExitData memory data_) external {
        if (data_.amount == 0) {
            return;
        }

        _validateExecutor(data_.executor);
        CrosschainRecoveryLib.markRecovery(MARKET_ID, data_.executor);

        bytes memory options = data_.options;
        if (data_.nativeDrop != 0) {
            if (options.length == 0) options = OptionsBuilder.newOptions();
            options = options.addExecutorNativeDropOption(data_.nativeDrop, bytes32(uint256(uint160(data_.executor))));
        }

        ICrosschainExecutor(data_.executor)
            .requestAssetsFromDispatcher(data_.dstChainId, data_.amount, data_.minReturn, options);

        emit CrosschainSupplyFuseExit(VERSION, data_.executor, data_.dstChainId, data_.amount, data_.minReturn);
    }

    /// @dev Substrate gate + chain-consistency check: the executor must be granted and its immutable
    ///      MANAGER must be this PlasmaVault (guards against driving a rogue executor, risk #9).
    function _validateExecutor(address executor_) internal view {
        CrosschainSubstrateLib.validateExecutorGranted(MARKET_ID, executor_);

        address manager = ICrosschainExecutor(executor_).MANAGER();
        if (manager != address(this)) {
            revert CrosschainSupplyFuseExecutorManagerMismatch(executor_, manager);
        }
        // Symmetric with the CCIP fuses, which assert `transportKind() == CHAINLINK_CCIP`: refuse a
        // cross-wired executor explicitly instead of relying on an incidental ABI selector mismatch
        // (audit M-5). Probed through `STARGATE_POOL()` rather than a self-declared transport label —
        // the pool is an intrinsic immutable of the Stargate transport base that no CCIP executor has,
        // and the check costs the (EIP-170-bound) executor no runtime bytes.
        (bool ok, bytes memory ret) =
            executor_.staticcall(abi.encodeWithSelector(IStargateTransportProbe.STARGATE_POOL.selector));
        if (!ok || ret.length != 32 || abi.decode(ret, (address)) == address(0)) {
            revert CrosschainSupplyFuseWrongTransport(executor_);
        }
    }
}
