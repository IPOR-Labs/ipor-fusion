// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {OAppSender} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppSender.sol";
import {OAppReceiver} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppReceiver.sol";
import {OAppCore} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppCore.sol";
import {OAppOptionsType3} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OAppOptionsType3.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import {
    MessagingFee,
    MessagingReceipt,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {MsgType} from "../../lib/CrosschainConstants.sol";
import {CrosschainMessages} from "../../lib/CrosschainMessages.sol";
import {CrosschainErrors} from "../../lib/CrosschainErrors.sol";
import {RescueModule} from "../../lib/RescueModule.sol";
import {StargateLzSendLib} from "../lib/StargateLzSendLib.sol";
import {IStargateLzSendAbi} from "./IStargateLzSendAbi.sol";

/// @title StargateLzOAppBase
/// @notice Abstract LayerZero V2 **message channel** base for the crosschain layer. Owns the
///         `chainId <-> EID` bijection table, enforced-options storage, the same-address
///         peer model, native-budget fee quoting/payment and the
///         inbound message auth/dispatch. Also carries the shared `RescueModule`.
/// @dev The factory (message-only) inherits this directly; the executor and dispatcher inherit it via
///      `StargateOAppBase` which adds the Stargate value channel. Peer authentication is enforced by
///      the vendored `OAppReceiver.lzReceive` (endpoint + peer==origin.sender) before any subclass
///      logic runs. Because the peer is always this contract's own address on the remote chain, an
///      authenticated `origin.sender` is `bytes32(uint256(uint160(address(this))))`.
///
///      Owner-path config mutation (`setPeer`, `setEnforcedOptions`, `setDelegate` - the latter via a one-word
///      `virtual` patch to the vendored `OAppCore`, see contracts/vendor/README.md) is neutralized. Peers and
///      enforced options flow exclusively through `_registerPath`; endpoint library / DVN configuration follows
///      the endpoint defaults (LayerZero's, changeable by them).
/// @author IPOR Labs
abstract contract StargateLzOAppBase is OAppSender, OAppReceiver, OAppOptionsType3, RescueModule, IStargateLzSendAbi {
    /// @notice chainId => LayerZero endpoint id.
    mapping(uint256 chainId => uint32 eid) internal _chainToEid;

    /// @notice LayerZero endpoint id => chainId.
    mapping(uint32 eid => uint256 chainId) internal _eidToChain;

    /// @notice Emitted when a chainId<->EID path is registered and its same-address peer is set.
    event PathRegistered(uint256 chainId, uint32 eid, bytes32 peer);

    /// @notice Emitted when a plain LayerZero message is sent, paid from the native budget.
    /// @param dstChainId Destination chain id.
    /// @param optionType The enforced-options key the send was quoted under, NOT the wire `MsgType`: it is 1
    ///        for every executor/dispatcher message and the real `MsgType` (1-3) only for factory messages.
    ///        The real message type is in the payload envelope.
    /// @param guid LayerZero message guid.
    /// @param nativeFee Native fee paid.
    event LzMessageSent(uint256 dstChainId, uint16 optionType, bytes32 guid, uint256 nativeFee);

    /// @param endpoint_ LayerZero V2 endpoint address.
    /// @param owner_ OApp owner (OZ5 Ownable + OAppCore delegate); MUST be non-zero.
    /// @param admin_ Rescue admin (full delayed administrator).
    /// @param guardian_ Rescue guardian (veto only), distinct from admin_.
    /// @param rescueDelay_ Rescue timelock in seconds.
    /// @dev The vendored `OAppCore` constructor requires a non-zero `_delegate` and sets it on the
    ///      endpoint, so `owner_` is passed as the delegate and then immediately cleared to `address(0)`
    ///      in the body: clearing removes only the external delegate authority — the OApp
    ///      itself remains endpoint-authorized. The rescue path can no longer reconfigure it (generic rescue
    ///      refuses every endpoint call except inbound packet hygiene). The owner's `setDelegate` is disabled
    ///      as well (IL-8557 / IL-8558), so no route to change the endpoint (library / DVN) config exists after
    ///      deployment (peers and enforced options stay changeable through `_registerPath` / the factory's
    ///      `executePathConfig`): such a change means a redeploy.
    ///      OZ 5 requires the explicit `Ownable(owner_)` in the most-derived-through-here chain.
    constructor(address endpoint_, address owner_, address admin_, address guardian_, uint256 rescueDelay_)
        OAppCore(endpoint_, owner_)
        Ownable(owner_)
        RescueModule(admin_, guardian_, rescueDelay_)
    {
        // Fail fast on a zero endpoint rather than deferring to the `setDelegate` call below (§8 P3 item 4).
        if (endpoint_ == address(0)) revert CrosschainErrors.ZeroAddress();
        endpoint.setDelegate(address(0));
    }

    /// @notice Accept native funding for the LayerZero/Stargate fee budget.
    receive() external payable {}

    // ============================================================
    // OApp version (diamond override over sender + receiver)
    // ============================================================

    /// @inheritdoc OAppSender
    function oAppVersion()
        public
        pure
        override(OAppSender, OAppReceiver)
        returns (uint64 senderVersion, uint64 receiverVersion)
    {
        return (1, 2);
    }

    // ============================================================
    // Disabled owner-path config (all config via `_registerPath`)
    // ============================================================

    /// @notice Disabled: peers are set only through `_registerPath` (same-address model, §4.1).
    function setPeer(uint32, bytes32) public pure override {
        revert CrosschainErrors.ConfigViaAuthorizedPathOnly();
    }

    /// @notice Disabled: enforced options are set only through `_registerPath`.
    function setEnforcedOptions(EnforcedOptionParam[] calldata) public pure override {
        revert CrosschainErrors.ConfigViaAuthorizedPathOnly();
    }

    /// @notice Disabled: the endpoint delegate is cleared in the constructor and can never be re-appointed, so
    ///         LayerZero library / DVN configuration follows the endpoint defaults (LayerZero's,
    ///         changeable by them) for the life of the contract (IL-8557 / IL-8558). Changing the host's own
    ///         endpoint config requires a redeploy.
    function setDelegate(address) public pure override {
        revert CrosschainErrors.ConfigViaAuthorizedPathOnly();
    }

    // ============================================================
    // chainId <-> EID table + same-address peer registration (§4.1)
    // ============================================================

    /// @notice Public view: endpoint id registered for a chain id (reverts if unknown).
    function eidOf(uint256 chainId_) public view virtual returns (uint32) {
        uint32 eid = _chainToEid[chainId_];
        if (eid == 0) revert CrosschainErrors.UnknownChain(chainId_);
        return eid;
    }

    /// @notice Public view: chain id registered for an endpoint id (reverts if unknown).
    function chainIdOf(uint32 eid_) public view virtual returns (uint256) {
        uint256 chainId = _eidToChain[eid_];
        if (chainId == 0) revert CrosschainErrors.UnknownEid(eid_);
        return chainId;
    }

    /// @notice Register a chainId<->EID path, its same-address peer and its enforced options.
    /// @dev Internal spine used by the executor's `registerChain` and the factory's path config; those
    ///      wrappers own the manager/owner authorization and (for the executor) the hard equality check
    ///      against the factory's frozen path table (§4.1). Enforces a strict append-only bijection:
    ///      rejects zero chainId/EID, the local chain, and any duplicate in either direction. The peer
    ///      is always `bytes32(uint256(uint160(address(this))))` — the contract's own address on the
    ///      remote chain. `enforcedOptions_`, when non-empty, is the ABI-encoding of an
    ///      `EnforcedOptionParam[]`; every entry must target `eid_`.
    /// @param chainId_ EVM chain id of the remote chain.
    /// @param eid_ LayerZero endpoint id of the remote chain.
    /// @param enforcedOptions_ ABI-encoded `EnforcedOptionParam[]` for this path, or empty.
    function _registerPath(uint256 chainId_, uint32 eid_, bytes memory enforcedOptions_) internal {
        if (chainId_ == 0 || eid_ == 0 || chainId_ == block.chainid) {
            revert CrosschainErrors.InvalidChainRegistration(chainId_, eid_);
        }
        if (_chainToEid[chainId_] != 0 || _eidToChain[eid_] != 0) {
            revert CrosschainErrors.ChainAlreadyRegistered(chainId_, eid_);
        }

        _chainToEid[chainId_] = eid_;
        _eidToChain[eid_] = chainId_;

        bytes32 selfPeer = bytes32(uint256(uint160(address(this))));
        _setPeer(eid_, selfPeer);

        if (enforcedOptions_.length != 0) {
            EnforcedOptionParam[] memory options = abi.decode(enforcedOptions_, (EnforcedOptionParam[]));
            uint256 len = options.length;
            for (uint256 i; i < len; ++i) {
                if (options[i].eid != eid_) {
                    revert CrosschainErrors.EnforcedOptionsPathMismatch(eid_, options[i].eid);
                }
            }
            _setEnforcedOptions(options);
        }

        emit PathRegistered(chainId_, eid_, selfPeer);
    }

    // ============================================================
    // Inbound message dispatch (plain LayerZero channel)
    // ============================================================

    /// @notice Vendored `OAppReceiver` hook: peer/endpoint auth already passed. Decodes the envelope,
    ///         maps the source EID to a registered chain id and dispatches to `_handleLzMessage`.
    /// @dev Guarded with `nonReentrant`. Reverts on an unregistered source EID.
    function _lzReceive(
        Origin calldata origin_,
        bytes32, /* guid_ */
        bytes calldata message_,
        address, /* executor_ */
        bytes calldata /* extraData_ */
    )
        internal
        override
        nonReentrant
    {
        (MsgType msgType, bytes memory data) = CrosschainMessages.decodeEnvelope(message_);
        uint256 srcChainId = _eidToChain[origin_.srcEid];
        if (srcChainId == 0) revert CrosschainErrors.UnknownEid(origin_.srcEid);
        _handleLzMessage(msgType, srcChainId, origin_, data);
    }

    /// @notice Subclass hook handling a decoded, authenticated inbound plain message.
    /// @param msgType_ The decoded envelope message type (never `NONE`).
    /// @param srcChainId_ The registered source chain id (mapped from `origin_.srcEid`).
    /// @param origin_ The raw LayerZero origin (peer already verified by the vendored receiver).
    /// @param data_ The inner ABI-encoded payload for `msgType_`.
    function _handleLzMessage(MsgType msgType_, uint256 srcChainId_, Origin calldata origin_, bytes memory data_)
        internal
        virtual;

    // ============================================================
    // Outbound message send (native-budget paid)
    // ============================================================

    /// @notice Send a plain LayerZero message to a registered chain, paying the fee from self balance.
    /// @dev Resolves the EID, combines caller options with enforced options (reusing the vendored
    ///      `combineOptions` merge logic), then the linked `StargateLzSendLib.send` quotes, enforces the factory
    ///      fee ceiling on executors and the factory (`StargateNativeFeeCapLib`), checks the native budget, sends
    ///      and refunds to self.
    /// @param dstChainId_ Destination chain id (must be registered).
    /// @param payload_ The full envelope bytes (from `CrosschainMessages`).
    /// @param msgType_ Enforced-options key for this send (an app-level options discriminator).
    /// @param extraOptions_ Caller-supplied type-3 options merged with the path's enforced options.
    /// @return receipt The LayerZero messaging receipt (`guid`, `nonce`, `fee`).
    function _sendLzMessage(uint256 dstChainId_, bytes memory payload_, uint16 msgType_, bytes memory extraOptions_)
        internal
        returns (MessagingReceipt memory receipt)
    {
        uint32 eid = _chainToEid[dstChainId_];
        if (eid == 0) revert CrosschainErrors.UnknownChain(dstChainId_);

        bytes memory options = this.combineOptions(eid, msgType_, extraOptions_);
        return StargateLzSendLib.send(endpoint, dstChainId_, eid, payload_, msgType_, options);
    }
}
