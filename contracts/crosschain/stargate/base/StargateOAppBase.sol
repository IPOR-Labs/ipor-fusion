// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {IStargate} from "@stargatefinance/stg-evm-v2/src/interfaces/IStargate.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";

import {MsgType} from "../../lib/CrosschainConstants.sol";
import {CrosschainMessages} from "../../lib/CrosschainMessages.sol";
import {CrosschainErrors} from "../../lib/CrosschainErrors.sol";
import {StargateAssetSendLib} from "../lib/StargateAssetSendLib.sol";
import {StargateLzOAppBase} from "./StargateLzOAppBase.sol";
import {IStargateAssetSendAbi} from "./IStargateAssetSendAbi.sol";

/// @title StargateOAppBase
/// @notice Abstract transport base adding the Stargate V2 **value channel** on top of the LayerZero
///         message channel (`StargateLzOAppBase`). Inherited by the crosschain executor and dispatcher (both
///         speak message + value). Owns local<->shared decimal conversion, the taxi-mode
///         asset send and the four-fold `lzCompose` authentication.
/// @dev Taxi mode = empty `oftCmd` + non-empty `composeMsg`; every asset send carries a compose payload
///      so delivery-and-act semantics and the guid-bound accounting state machine hold. Amounts on the
///      external `_sendAsset` boundary are in LOCAL ASSET decimals; wire/accounting normalization to
///      shared decimals is done by subclasses via `_toSD`/`_toLD`.
/// @author IPOR Labs
abstract contract StargateOAppBase is StargateLzOAppBase, ILayerZeroComposer, IStargateAssetSendAbi {
    /// @notice Enforced-options key for asset (compose) sends; distinct from plain-message keys used by
    ///         `_sendLzMessage`. Register this path's compose lzReceive/lzCompose gas under this key.
    uint16 internal constant COMPOSE_OPTION_TYPE = 2;

    /// @notice The single local ERC20 asset bridged by this contract (resolved by the factory).
    address public immutable ASSET;

    /// @notice The local Stargate V2 pool for `ASSET` (its `token()` must equal `ASSET`).
    IStargate public immutable STARGATE_POOL;

    /// @notice Local decimals of `ASSET` (read at construction).
    uint8 public immutable LOCAL_DECIMALS;

    /// @notice Shared (OFT) decimals of the Stargate pool (6 for USDC).
    uint8 public immutable SHARED_DECIMALS;

    /// @dev `10 ** (LOCAL_DECIMALS - SHARED_DECIMALS)`; 1 when local == shared.
    uint256 internal immutable _decimalConversionRate;

    /// @notice Emitted when an asset is sent via Stargate taxi (compose) from the native budget.
    event AssetSent(uint256 dstChainId, bytes32 guid, uint256 amountSentLD, uint256 amountReceivedLD);

    /// @notice Emitted when an authenticated inbound compose is dispatched to the subclass.
    event ComposeReceived(uint256 srcChainId, bytes32 guid, uint256 amountLD, uint8 msgType);

    /// @param endpoint_ LayerZero V2 endpoint address.
    /// @param owner_ OApp owner (see `StargateLzOAppBase`).
    /// @param admin_ Rescue admin.
    /// @param guardian_ Rescue guardian (distinct from admin_).
    /// @param rescueDelay_ Rescue timelock (seconds).
    /// @param asset_ Local ERC20 asset; must be non-zero and equal `STARGATE_POOL.token()`.
    /// @param stargatePool_ Local Stargate pool for `asset_`; must be non-zero.
    constructor(
        address endpoint_,
        address owner_,
        address admin_,
        address guardian_,
        uint256 rescueDelay_,
        address asset_,
        address stargatePool_
    ) StargateLzOAppBase(endpoint_, owner_, admin_, guardian_, rescueDelay_) {
        if (asset_ == address(0) || stargatePool_ == address(0)) {
            revert CrosschainErrors.ZeroAddress();
        }

        address poolToken = IStargate(stargatePool_).token();
        if (poolToken != asset_) revert CrosschainErrors.StargatePoolAssetMismatch(asset_, poolToken);

        uint8 localDec = IERC20Metadata(asset_).decimals();
        uint8 sharedDec = IStargate(stargatePool_).sharedDecimals();
        if (localDec < sharedDec) revert CrosschainErrors.InvalidDecimals(localDec, sharedDec);

        ASSET = asset_;
        STARGATE_POOL = IStargate(stargatePool_);
        LOCAL_DECIMALS = localDec;
        SHARED_DECIMALS = sharedDec;
        _decimalConversionRate = 10 ** uint256(localDec - sharedDec);
    }

    // ============================================================
    // Decimal conversion (local <-> shared)
    // ============================================================

    /// @notice Convert a LOCAL-decimals amount to SHARED decimals, truncating sub-precision dust.
    /// @dev Dust below shared-decimals precision is dropped (never bridged) — the OFT rule. Identity
    ///      when local == shared.
    /// @param localAmount_ Amount in local ASSET decimals.
    /// @return Amount in shared decimals.
    function _toSD(uint256 localAmount_) internal view returns (uint256) {
        return localAmount_ / _decimalConversionRate;
    }

    /// @notice Convert a SHARED-decimals amount to LOCAL decimals. Identity when local == shared.
    /// @param sharedAmount_ Amount in shared decimals.
    /// @return Amount in local ASSET decimals.
    function _toLD(uint256 sharedAmount_) internal view returns (uint256) {
        return sharedAmount_ * _decimalConversionRate;
    }

    // ============================================================
    // Outbound asset send (Stargate taxi + compose, native-budget paid)
    // ============================================================

    /// @notice Send `amountLD_` of `ASSET` to this contract's own address on `dstChainId_` via Stargate
    ///         taxi mode with a mandatory compose payload, paying the fee from the native budget.
    /// @dev Recipient is always `bytes32(uint256(uint160(address(this))))` (same-address model). The body runs in
    ///      the linked `StargateAssetSendLib`: it quotes, enforces the factory fee ceiling on executors
    ///      (`StargateNativeFeeCapLib`), checks the budget, sets a scoped `forceApprove` around the send and resets
    ///      it to zero.
    /// @param dstChainId_ Destination chain id (must be registered).
    /// @param amountLD_ Amount to send in local decimals.
    /// @param minAmountLD_ Slippage floor in local decimals (Stargate may apply fee/reward deltas).
    /// @param composeMsg_ The compose payload (full envelope bytes); must be non-empty for taxi+compose.
    /// @param extraOptions_ Caller options merged with the path's `COMPOSE_OPTION_TYPE` enforced options.
    /// @return guid The Stargate/LayerZero message guid.
    /// @return amountSentLD The actual amount debited on the source (local decimals).
    /// @return amountReceivedLD The expected amount credited on the destination (local decimals).
    function _sendAsset(
        uint256 dstChainId_,
        uint256 amountLD_,
        uint256 minAmountLD_,
        bytes memory composeMsg_,
        bytes memory extraOptions_
    ) internal returns (bytes32 guid, uint256 amountSentLD, uint256 amountReceivedLD) {
        uint32 eid = _chainToEid[dstChainId_];
        if (eid == 0) revert CrosschainErrors.UnknownChain(dstChainId_);

        bytes memory options = this.combineOptions(eid, COMPOSE_OPTION_TYPE, extraOptions_);

        return StargateAssetSendLib.sendAsset(
            StargateAssetSendLib.SendAssetParams({
                pool: STARGATE_POOL,
                asset: ASSET,
                dstChainId: dstChainId_,
                dstEid: eid,
                amountLD: amountLD_,
                minAmountLD: minAmountLD_,
                composeMsg: composeMsg_,
                options: options
            })
        );
    }

    /// @notice `_sendAsset`, except that a send the pool would credit below `minAmountLD_` (IL-8452), or that
    ///         exceeds the path's live credit (IL-8616), is skipped and returns a zero guid instead of reverting
    ///         inside `sendToken`, so a handler on an inbound lane can reject cleanly rather than have LayerZero
    ///         retain its packet. A skip returns `(0, amountLD_, 0)` for the credit cap and `(0, 0, 0)` for the
    ///         floor (`StargateAssetSendLib.sendAssetUnlessShortCredit`). Same parameters as `_sendAsset`; kept as
    ///         a separate body so a runtime links only the variant it uses.
    function _sendAssetUnlessShortCredit(
        uint256 dstChainId_,
        uint256 amountLD_,
        uint256 minAmountLD_,
        bytes memory composeMsg_,
        bytes memory extraOptions_
    ) internal returns (bytes32 guid, uint256 amountSentLD, uint256 amountReceivedLD) {
        uint32 eid = _chainToEid[dstChainId_];
        if (eid == 0) revert CrosschainErrors.UnknownChain(dstChainId_);

        bytes memory options = this.combineOptions(eid, COMPOSE_OPTION_TYPE, extraOptions_);

        return StargateAssetSendLib.sendAssetUnlessShortCredit(
            StargateAssetSendLib.SendAssetParams({
                pool: STARGATE_POOL,
                asset: ASSET,
                dstChainId: dstChainId_,
                dstEid: eid,
                amountLD: amountLD_,
                minAmountLD: minAmountLD_,
                composeMsg: composeMsg_,
                options: options
            })
        );
    }

    // ============================================================
    // Inbound compose settlement (four-fold auth)
    // ============================================================

    /// @notice LayerZero compose entry point for inbound Stargate taxi deliveries (token + payload).
    /// @dev Enforces the four-fold check: (1) caller is the endpoint, (2) `_from` is the
    ///      Stargate pool, (3) the codec `composeFrom` is this contract's own address, (4) the codec
    ///      `srcEid` maps to a registered chain. Then decodes the envelope and dispatches to
    ///      `_handleCompose`. The additional executor-side constraint that `srcEid` must equal the chain
    ///      bound to the pending transfer/command id is enforced in the subclass. `nonReentrant`.
    function lzCompose(
        address from_,
        bytes32 guid_,
        bytes calldata message_,
        address, /* executor_ */
        bytes calldata /* extraData_ */
    )
        external
        payable
        override
        nonReentrant
    {
        if (msg.sender != address(endpoint)) revert CrosschainErrors.UnauthorizedEndpoint(msg.sender);
        if (from_ != address(STARGATE_POOL)) revert CrosschainErrors.UnauthorizedStargatePool(from_);

        bytes32 composeFrom = OFTComposeMsgCodec.composeFrom(message_);
        if (composeFrom != bytes32(uint256(uint160(address(this))))) {
            revert CrosschainErrors.UnauthorizedComposeFrom(composeFrom);
        }

        uint32 srcEid = OFTComposeMsgCodec.srcEid(message_);
        uint256 srcChainId = _eidToChain[srcEid];
        if (srcChainId == 0) revert CrosschainErrors.UnknownEid(srcEid);

        uint256 amountLD = OFTComposeMsgCodec.amountLD(message_);
        (MsgType msgType, bytes memory data) =
            CrosschainMessages.decodeEnvelope(OFTComposeMsgCodec.composeMsg(message_));

        _handleCompose(srcChainId, guid_, amountLD, msgType, data);
        emit ComposeReceived(srcChainId, guid_, amountLD, uint8(msgType));
    }

    /// @notice Subclass hook handling a decoded, four-fold-authenticated inbound compose.
    /// @dev The subclass MUST additionally bind `srcChainId_` to the pending transfer/command id it is
    ///      reconciling before mutating accounting.
    /// @param srcChainId_ The registered source chain id (mapped from the codec `srcEid`).
    /// @param guid_ The Stargate/LayerZero guid of the delivery.
    /// @param amountLD_ The destination-credited amount in LOCAL decimals (codec `amountLD`).
    /// @param msgType_ The decoded envelope message type of the compose payload.
    /// @param data_ The inner ABI-encoded payload for `msgType_`.
    function _handleCompose(uint256 srcChainId_, bytes32 guid_, uint256 amountLD_, MsgType msgType_, bytes memory data_)
        internal
        virtual;
}
