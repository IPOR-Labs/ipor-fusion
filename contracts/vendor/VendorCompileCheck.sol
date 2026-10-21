// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

// LayerZero V2 OApp messaging
import {OApp} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {OAppSender} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppSender.sol";
import {OAppReceiver} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppReceiver.sol";
import {OAppOptionsType3} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OAppOptionsType3.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

// LayerZero V2 protocol interfaces + messaging structs
import {
    ILayerZeroEndpointV2,
    MessagingParams,
    MessagingReceipt,
    MessagingFee,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";

// OFT compose codec + OFT value types (used by Stargate)
import {SendParam, OFTReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";

// Stargate V2
import {IStargate, Ticket, StargateType} from "@stargatefinance/stg-evm-v2/src/interfaces/IStargate.sol";

// Solady CREATE3
import {CREATE3} from "solady/utils/CREATE3.sol";

/// @title VendorCompileCheck
/// @notice Compile-only smoke test that references a symbol from every vendored crosschain
///         transport dependency. It documents the working import paths and proves the vendor
///         tree builds under this repo's toolchain (solc 0.8.30 / OZ 5.0.2 / cancun).
/// @dev Never deployed. Exists solely to keep the vendored import graph compiling. All OApp
///      base contracts are abstract and are referenced as types only (never instantiated).
contract VendorCompileCheck {
    using OptionsBuilder for bytes;

    // --- Typed references to the abstract OApp base contracts & transport interfaces ---
    OApp public oApp;
    OAppSender public oAppSender;
    OAppReceiver public oAppReceiver;
    OAppOptionsType3 public oAppOptions;
    ILayerZeroEndpointV2 public endpoint;
    ILayerZeroComposer public composer;
    IStargate public stargate;

    /// @notice Touches OptionsBuilder: newOptions + executor lzReceive/lzCompose options.
    function buildOptions(uint128 gas, uint128 value, uint16 composeIndex) external pure returns (bytes memory) {
        bytes memory opts = OptionsBuilder.newOptions();
        opts = opts.addExecutorLzReceiveOption(gas, value);
        opts = opts.addExecutorLzComposeOption(composeIndex, gas, value);
        return opts;
    }

    /// @notice Touches OAppOptionsType3.combineOptions (enforced-options merge, security-critical).
    function combine(uint32 eid, uint16 msgType, bytes calldata extra) external view returns (bytes memory) {
        return oAppOptions.combineOptions(eid, msgType, extra);
    }

    /// @notice Touches OFTComposeMsgCodec (auth-critical compose-message decoders).
    function decodeCompose(bytes calldata composedMsg)
        external
        pure
        returns (bytes32 from, uint32 srcEid, uint256 amountLD, bytes memory inner, uint64 msgNonce)
    {
        from = OFTComposeMsgCodec.composeFrom(composedMsg);
        srcEid = OFTComposeMsgCodec.srcEid(composedMsg);
        amountLD = OFTComposeMsgCodec.amountLD(composedMsg);
        inner = OFTComposeMsgCodec.composeMsg(composedMsg);
        msgNonce = OFTComposeMsgCodec.nonce(composedMsg);
    }

    /// @notice Touches the LayerZero endpoint send/quote/setDelegate surface and the messaging structs.
    function endpointSurface(MessagingParams calldata p, address refund)
        external
        returns (MessagingReceipt memory receipt, MessagingFee memory fee)
    {
        receipt = endpoint.send{value: 0}(p, refund);
        fee = endpoint.quote(p, address(this));
        endpoint.setDelegate(address(0));
    }

    /// @notice Touches ILayerZeroComposer.lzCompose and the Origin struct.
    function composeSurface(
        Origin calldata origin,
        address from,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extra
    ) external payable returns (uint32) {
        composer.lzCompose{value: msg.value}(from, guid, message, executor, extra);
        return origin.srcEid;
    }

    /// @notice Touches IStargate.sendToken and the OFT value structs (Ticket, OFTReceipt).
    function stargateSend(SendParam calldata sp, MessagingFee calldata fee, address refund)
        external
        payable
        returns (MessagingReceipt memory r, OFTReceipt memory o, Ticket memory t)
    {
        (r, o, t) = stargate.sendToken{value: msg.value}(sp, fee, refund);
    }

    /// @notice Touches IStargate.quoteSend / token / stargateType (view surface).
    function stargateViews(SendParam calldata sp)
        external
        view
        returns (MessagingFee memory quote, address tok, StargateType st)
    {
        quote = stargate.quoteSend(sp, false);
        tok = stargate.token();
        st = stargate.stargateType();
    }

    /// @notice References the abstract OApp base types (OApp / OAppSender / OAppReceiver).
    function oappTypes() external view returns (address a, address b, address c) {
        a = address(oApp);
        b = address(oAppSender);
        c = address(oAppReceiver);
    }

    /// @notice Touches Solady CREATE3.deploy and both getDeployed overloads.
    function create3Surface(bytes32 salt, bytes memory initcode, address deployer)
        external
        returns (address deployed, address predictedByThis, address predictedByDeployer)
    {
        deployed = CREATE3.deploy(salt, initcode, 0);
        predictedByThis = CREATE3.getDeployed(salt);
        predictedByDeployer = CREATE3.getDeployed(salt, deployer);
    }
}
