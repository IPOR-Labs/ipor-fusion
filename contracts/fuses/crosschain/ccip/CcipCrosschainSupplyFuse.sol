// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFuseCommon} from "../../IFuseCommon.sol";
import {IporMath} from "../../../libraries/math/IporMath.sol";
import {ICrosschainExecutor} from "../../../crosschain/interfaces/ICrosschainExecutor.sol";
import {ICcipCrosschainExecutor} from "../../../crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {ICrosschainExecutorMetadata} from "../../../crosschain/common/ICrosschainExecutorMetadata.sol";
import {CrosschainTransportKind} from "../../../crosschain/common/CrosschainTransportTypes.sol";
import {CrosschainSubstrateLib} from "../lib/CrosschainSubstrateLib.sol";
import {CrosschainRecoveryLib} from "../lib/CrosschainRecoveryLib.sol";

/// @notice Data for entering the CROSSCHAIN market over CCIP: bridge capital out to a remote dispatcher.
/// @dev Field units: `amount`, `maxFee` and `minDelivered` are plain integers in the units named below; the
///      executor converts `amount` and `minDelivered` to shared decimals itself.
struct CcipSupplyFuseEnterData {
    /// @dev The CcipCrosschainExecutor to drive: must be a granted EXECUTOR substrate, its `MANAGER()` must be the
    ///      calling vault and its transport must be CHAINLINK_CCIP.
    address executor;
    /// @dev The asset to bridge; must be handled by the executor (`validateExecutorHandlesAsset`).
    address asset;
    /// @dev Destination EVM chainId of the dispatcher; it must be an enabled route of the executor.
    uint256 dstChainId;
    /// @dev Requested amount of `asset` in LOCAL asset decimals. Clamped to the vault balance of `asset`, then floored
    ///      to a multiple of the executor's `DECIMAL_CONVERSION_RATE()` (the shared-decimals unit); the sub-unit
    ///      remainder stays in the vault. Zero after the clamp and floor = no-op.
    uint256 amount;
    /// @dev Ceiling on the CCIP router fee, in units of `feeToken` (wei when `feeToken` is `address(0)`). The send
    ///      reverts when the quoted fee is above it, and `maxFee` itself must not exceed the route's `maxFee`.
    uint256 maxFee;
    /// @dev Fee token; must equal the route's `feeToken`. `address(0)` = the chain's native currency, paid from the
    ///      executor's own native balance; otherwise the ERC20 fee is pulled from the executor's balance of that token.
    address feeToken;
    /// @dev 0 = route policy; above policy is clamped; below policy reverts (`CcipGasLimitBelowRoutePolicy`).
    uint256 gasLimit;
    /// @dev Floor on the tokens the destination must receive, in local asset decimals; 0 = no floor, and it must
    ///      not exceed the amount actually sent (`amount` after the vault-balance clamp and dust floor; the executor
    ///      reverts `InvalidMinDelivered`). A CCIP token pool may charge a fee or apply a haircut, so the
    ///      destination can receive less than was sent. Must be an exact multiple of the executor's
    ///      `DECIMAL_CONVERSION_RATE()` (reverts `AmountHasDust`). The floor is NOT a revert guard:
    ///      the tokens have already left when the pool delivers, so a miss only surfaces at settlement as
    ///      `SettledBelowMinDelivered` (and the shortfall as `SettledCreditShortfall`); the value that arrived is
    ///      booked and the chain is not blocked. Trust assumption: the pool owner is a trusted external party who
    ///      can change the pool fee; this field lets the atomist detect that, it does not constrain it.
    uint256 minDelivered;
}

/// @notice Data for exiting the CROSSCHAIN market over CCIP: request a recall of assets from a remote dispatcher.
/// @dev `exit` only REQUESTS a recall; no tokens arrive in the same transaction. The returned tokens settle later
///      into the executor's idle ledger and are moved back to the vault by `CrosschainClaimFuse`. This fuse therefore
///      MUST NOT be placed in the vault's instant-withdraw fuse order; it deliberately does not implement
///      `IFuseInstantWithdraw`. The same holds for the Stargate supply fuse.
struct CcipSupplyFuseExitData {
    /// @dev The CcipCrosschainExecutor to drive (same requirements as in `CcipSupplyFuseEnterData`).
    address executor;
    /// @dev Destination EVM chainId of the dispatcher the assets are recalled from.
    uint256 dstChainId;
    /// @dev Amount of the executor's asset to request back, in LOCAL asset decimals. Zero = no-op. Must be an exact
    ///      multiple of the executor's `DECIMAL_CONVERSION_RATE()` (reverts `AmountHasDust`).
    uint256 amount;
    /// @dev Checked by the dispatcher against the GROSS amount it sends, before any CCIP token-pool fee on the
    ///      return leg; the net tokens received can be lower (`ReturnFinalized.sentSD - received` is the fee).
    ///      Must be an exact multiple of the executor's `DECIMAL_CONVERSION_RATE()` (reverts `AmountHasDust`).
    uint256 minReturn;
    /// @dev Ceiling on the CCIP router fee of the recall request, in units of `feeToken` (see enter data).
    uint256 maxFee;
    /// @dev Fee token; must equal the route's `feeToken`, `address(0)` = native currency (see enter data).
    address feeToken;
    /// @dev 0 = route policy; above policy is clamped; below policy reverts (`CcipGasLimitBelowRoutePolicy`).
    uint256 gasLimit;
}

/// @notice Local-to-shared decimals ratio of the executor (`10 ** (localDecimals - sharedDecimals)`).
interface ICcipConversionRate {
    function DECIMAL_CONVERSION_RATE() external view returns (uint256);
}

/// @title CcipCrosschainSupplyFuse
/// @notice Stateless fuse (delegatecall from PlasmaVault) that moves capital out to a remote chain via the
///         CcipCrosschainExecutor (`enter`) and requests it back (`exit`).
/// @dev Runs in the PlasmaVault storage context. MUST NOT declare storage variables; only `immutable`.
///      The executor must be a granted EXECUTOR substrate of `MARKET_ID`, have this vault as `MANAGER()` and report
///      the CHAINLINK_CCIP transport; otherwise `enter` and `exit` revert.
///      Deliberately does NOT implement `IFuseInstantWithdraw`: `exit` only requests a recall, no tokens settle in
///      the same transaction, so this fuse must not be in the instant-withdraw order. Recalled tokens are claimed
///      later with `CrosschainClaimFuse`. The Stargate twin (`StargateCrosschainSupplyFuse`) has the same shape.
///      `enter` marks new exposure and does a live `getBalance()` NAV read (fail-closed); `exit` is recovery-marked
///      (`CrosschainRecoveryLib.markRecovery`), so it stays usable while live NAV is fail-closed.
/// @author IPOR Labs
contract CcipCrosschainSupplyFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice Thrown when the executor's immutable MANAGER is not this PlasmaVault.
    error CcipSupplyFuseExecutorManagerMismatch(address executor, address manager);
    /// @notice Thrown when the granted executor does not report the CHAINLINK_CCIP transport.
    error CcipSupplyFuseWrongTransport(address executor);

    /// @notice The address of this fuse contract version.
    address public immutable VERSION;
    /// @notice The market id the fuse operates on (the CROSSCHAIN market).
    uint256 public immutable MARKET_ID;

    /// @notice Emitted after assets are transferred to the executor and a CCIP send is initiated.
    /// @param version The address of this fuse contract version.
    /// @param executor The CcipCrosschainExecutor driven.
    /// @param chainId Destination chainId the assets were sent to.
    /// @param amount The amount actually sent (post vault-balance clamp and shared-decimals floor), local asset
    ///        decimals.
    /// @param minDelivered The delivered-amount floor the keeper set for this send, in local `asset` decimals
    ///        (`0` = no floor), emitted so monitoring can check the floor before it is missed (IL-8581).
    event CcipSupplyFuseEnter(
        address version, address executor, uint256 chainId, uint256 amount, uint256 minDelivered
    );
    /// @notice Emitted after a recall of assets is requested from the dispatcher.
    /// @param version The address of this fuse contract version.
    /// @param executor The CcipCrosschainExecutor driven.
    /// @param chainId Destination chainId the assets are recalled from.
    /// @param amount The requested recall amount, local asset decimals.
    event CcipSupplyFuseExit(address version, address executor, uint256 chainId, uint256 amount);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Bridges capital to the remote dispatcher: transfers up to `amount` of `asset` to the executor and
    ///         starts the CCIP send.
    /// @dev No-op when `data_.amount` is zero or the clamped and floored amount is zero. Reverts when the executor
    ///      is not granted, has another MANAGER or another transport, or does not handle `asset`.
    /// @param data_ The send parameters; see `CcipSupplyFuseEnterData`.
    function enter(CcipSupplyFuseEnterData calldata data_) external {
        if (data_.amount == 0) return;
        _validate(data_.executor);
        CrosschainRecoveryLib.markNewExposure();
        ICrosschainExecutor(data_.executor).getBalance();
        CrosschainSubstrateLib.validateExecutorHandlesAsset(data_.executor, data_.asset);
        uint256 amount = IporMath.min(data_.amount, IERC20(data_.asset).balanceOf(address(this)));
        // The executor rejects a send that is not an exact multiple of the shared-decimals unit (`AmountHasDust`).
        // The clamp above makes that reachable by anyone who donates 1 wei to the vault, so floor the amount here;
        // the sub-unit remainder stays in the vault.
        amount -= amount % ICcipConversionRate(data_.executor).DECIMAL_CONVERSION_RATE();
        if (amount == 0) return;
        IERC20(data_.asset).safeTransfer(data_.executor, amount);
        ICcipCrosschainExecutor(data_.executor)
            .sendAssetToDispatcher(
                data_.dstChainId, amount, data_.maxFee, data_.feeToken, data_.gasLimit, data_.minDelivered
            );
        emit CcipSupplyFuseEnter(VERSION, data_.executor, data_.dstChainId, amount, data_.minDelivered);
    }

    /// @notice Requests a recall of `amount` from the remote dispatcher. Only the request is sent; no tokens arrive
    ///         in this transaction.
    /// @dev No-op when `data_.amount` is zero. Marks the executor as a recovery (so the call stays usable while live
    ///      NAV is fail-closed). The returned tokens settle into the executor's idle ledger and are claimed with
    ///      `CrosschainClaimFuse`.
    /// @param data_ The recall parameters; see `CcipSupplyFuseExitData`.
    function exit(CcipSupplyFuseExitData calldata data_) external {
        if (data_.amount == 0) return;
        _validate(data_.executor);
        CrosschainRecoveryLib.markRecovery(MARKET_ID, data_.executor);
        ICcipCrosschainExecutor(data_.executor)
            .requestAssetsFromDispatcher(
                data_.dstChainId, data_.amount, data_.minReturn, data_.maxFee, data_.feeToken, data_.gasLimit
            );
        emit CcipSupplyFuseExit(VERSION, data_.executor, data_.dstChainId, data_.amount);
    }

    function _validate(address executor_) private view {
        CrosschainSubstrateLib.validateExecutorGranted(MARKET_ID, executor_);
        address manager = ICrosschainExecutor(executor_).MANAGER();
        if (manager != address(this)) revert CcipSupplyFuseExecutorManagerMismatch(executor_, manager);
        if (ICrosschainExecutorMetadata(executor_).transportKind() != CrosschainTransportKind.CHAINLINK_CCIP) {
            revert CcipSupplyFuseWrongTransport(executor_);
        }
    }
}
