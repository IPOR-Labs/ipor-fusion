// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {
    ILayerZeroEndpointV2,
    MessagingFee,
    MessagingParams,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import {BytesLib} from "solidity-bytes-utils/contracts/BytesLib.sol";

import {CrosschainErrors} from "../../lib/CrosschainErrors.sol";
import {MsgType} from "../../lib/CrosschainConstants.sol";
import {StargateNativeFeeCapLib} from "./StargateNativeFeeCapLib.sol";

/// @notice Linked LayerZero sender shared by factory, executor and dispatcher runtimes. Enforces the
///         factory's per-destination native fee ceiling (`StargateNativeFeeCapLib`) between the quote and
///         the solvency check; the ceiling applies to apps the factory lists in `isExecutor` and to the factory's
///         own sends (IL-8565 / IL-8605), never to dispatchers. Also
///         holds the shared enforced-options shape check used before a path is frozen (IL-8296).
library StargateLzSendLib {
    using BytesLib for bytes;

    /// @dev Type-3 header `0x0003`, executor worker `0x01`, TLV size `0x0011` (17), `lzReceive` `0x01`.
    bytes6 private constant LZ_RECEIVE_ONLY_PREFIX = 0x000301001101;

    uint256 private constant LZ_RECEIVE_ONLY_PREFIX_LENGTH = 6;

    /// @dev The prefix followed by a `uint128` gas and no value.
    uint256 private constant LZ_RECEIVE_ONLY_LENGTH = 22;

    /// @notice Lowest `lzReceive` gas accepted for the factory's CREATE_DISPATCHER / ACK / NACK path options.
    uint128 internal constant FACTORY_PATH_MIN_RECEIVE_GAS = 200_000;

    /// @notice Highest `lzReceive` gas accepted for the factory's path options, well above the 8,000,000
    ///         (dispatcher deployment) and 1,500,000 (ACK / NACK) the configuration script uses.
    uint128 internal constant FACTORY_PATH_MAX_RECEIVE_GAS = 20_000_000;

    /// @dev CREATE_DISPATCHER, DEPLOYMENT_ACK and DEPLOYMENT_NACK are message types 1, 2 and 3.
    uint16 private constant FACTORY_FIRST_MSG_TYPE = uint16(uint8(MsgType.CREATE_DISPATCHER));
    uint16 private constant FACTORY_LAST_MSG_TYPE = uint16(uint8(MsgType.DEPLOYMENT_NACK));

    /// @notice Same event as `StargateLzOAppBase.LzMessageSent`, emitted from the library (topic0 identical).
    /// @param dstChainId Destination chain id.
    /// @param optionType The enforced-options key the send was quoted under, NOT the wire `MsgType`: it is 1
    ///        for every executor/dispatcher message and the real `MsgType` (1-3) only for factory messages.
    ///        The real message type is in the payload envelope.
    /// @param guid LayerZero message guid.
    /// @param nativeFee Native fee paid.
    event LzMessageSent(uint256 dstChainId, uint16 optionType, bytes32 guid, uint256 nativeFee);

    /// @notice Quotes and sends one LayerZero message to this contract's own address on the destination chain,
    ///         paying the fee from this contract's native balance.
    /// @dev Order: quote, then the native fee ceiling (`StargateNativeFeeCapLib.enforce`; the ceiling applies only
    ///      to executors and the factory, dispatchers are not capped), then the budget check, then the endpoint send.
    ///      Reverts `InsufficientNativeBudget` when the balance is below the quoted fee.
    /// @param endpoint_ The LayerZero endpoint.
    /// @param dstChainId_ Destination chain id; the key of the fee ceiling.
    /// @param dstEid_ Destination LayerZero endpoint id.
    /// @param payload_ The message payload (envelope bytes).
    /// @param msgType_ The enforced-options key the send is reported under in `LzMessageSent`; it plays no other
    ///        role here, the options come from `options_`.
    /// @param options_ The full LayerZero options for the send.
    /// @return receipt The endpoint's messaging receipt (guid, nonce, fee).
    function send(
        ILayerZeroEndpointV2 endpoint_,
        uint256 dstChainId_,
        uint32 dstEid_,
        bytes memory payload_,
        uint16 msgType_,
        bytes memory options_
    ) public returns (MessagingReceipt memory receipt) {
        MessagingParams memory params = MessagingParams({
            dstEid: dstEid_,
            receiver: bytes32(uint256(uint160(address(this)))),
            message: payload_,
            options: options_,
            payInLzToken: false
        });
        MessagingFee memory fee = endpoint_.quote(params, address(this));
        StargateNativeFeeCapLib.enforce(dstChainId_, fee.nativeFee);
        uint256 balance = address(this).balance;
        if (balance < fee.nativeFee) revert CrosschainErrors.InsufficientNativeBudget(balance, fee.nativeFee);
        receipt = endpoint_.send{value: fee.nativeFee}(params, address(this));
        emit LzMessageSent(dstChainId_, msgType_, receipt.guid, fee.nativeFee);
    }

    /// @notice Early checks of the Stargate factory's `schedulePathConfig`, kept here for factory bytecode
    ///         size: the path shape, and the options of each CREATE_DISPATCHER / ACK / NACK message type,
    ///         which `_registerPath` freezes once the schedule executes (IL-8296).
    /// @param chainId_ The chain id of the path being scheduled.
    /// @param eid_ The endpoint id of the path being scheduled.
    /// @param enforcedOptions_ ABI-encoded `EnforcedOptionParam[]` for the path.
    function validatePathSchedule(uint256 chainId_, uint32 eid_, bytes calldata enforcedOptions_) public view {
        if (chainId_ == 0 || eid_ == 0 || chainId_ == block.chainid) {
            revert CrosschainErrors.InvalidChainRegistration(chainId_, eid_);
        }
        for (uint16 msgType = FACTORY_FIRST_MSG_TYPE; msgType <= FACTORY_LAST_MSG_TYPE; ++msgType) {
            if (
                !hasLzReceiveOnlyOptions(
                    enforcedOptions_,
                    msgType,
                    FACTORY_PATH_MIN_RECEIVE_GAS,
                    FACTORY_PATH_MAX_RECEIVE_GAS
                )
            ) revert CrosschainErrors.PathConfigOptionsInvalid(chainId_, msgType);
        }
    }

    /// @notice Tells whether the last `msgType_` entry of an ABI-encoded `EnforcedOptionParam[]` is exactly
    ///         the blob `OptionsBuilder.newOptions().addExecutorLzReceiveOption(gas, 0)` builds, with
    ///         `minGas_ <= gas <= maxGas_`. The last entry is judged because `_setEnforcedOptions` writes
    ///         entries in order and a later duplicate overwrites an earlier one (`OAppOptionsType3.sol:41-49`).
    ///         Every other shape is refused, even ones the endpoint would quote today (lzReceive value,
    ///         native drop, compose, ordered, DVN options): paths are append-only, and a value above the
    ///         destination executor's native cap or an unpayable gas amount bricks a path just like
    ///         missing options do (IL-8296).
    /// @dev Empty `enforcedOptions_` or no `msgType_` entry returns false; a malformed outer ABI encoding
    ///      reverts on `abi.decode`.
    /// @param enforcedOptions_ ABI-encoded `EnforcedOptionParam[]`, or empty.
    /// @param msgType_ The message type whose stored options are judged.
    /// @param minGas_ Lowest accepted `lzReceive` gas.
    /// @param maxGas_ Highest accepted `lzReceive` gas.
    /// @return True if the entry exists and has exactly the accepted shape.
    function hasLzReceiveOnlyOptions(
        bytes calldata enforcedOptions_,
        uint16 msgType_,
        uint128 minGas_,
        uint128 maxGas_
    ) public pure returns (bool) {
        (bool ok, uint128 gas) = lzReceiveOnlyGas(enforcedOptions_, msgType_);
        return ok && gas >= minGas_ && gas <= maxGas_;
    }

    /// @notice Parses the `lzReceive` gas of the last `msgType_` entry of an ABI-encoded `EnforcedOptionParam[]`
    ///         when that entry is exactly the `addExecutorLzReceiveOption(gas, 0)` blob (IL-8625).
    /// @param enforcedOptions_ ABI-encoded `EnforcedOptionParam[]`, or empty.
    /// @param msgType_ The message type whose stored options are read.
    /// @return ok True if the entry exists and has exactly the accepted shape.
    /// @return gas The `lzReceive` gas of that entry (0 when `ok` is false).
    function lzReceiveOnlyGas(
        bytes calldata enforcedOptions_,
        uint16 msgType_
    ) public pure returns (bool ok, uint128 gas) {
        if (enforcedOptions_.length == 0) return (false, 0);
        EnforcedOptionParam[] memory params = abi.decode(enforcedOptions_, (EnforcedOptionParam[]));
        uint256 len = params.length;
        bool found;
        bytes memory options;
        for (uint256 i; i < len; ++i) {
            if (params[i].msgType != msgType_) continue;
            found = true;
            options = params[i].options;
        }
        // casting to 'bytes6' is safe because only the first 6 bytes are compared on purpose
        // forge-lint: disable-next-line(unsafe-typecast)
        if (!found || options.length != LZ_RECEIVE_ONLY_LENGTH || bytes6(options) != LZ_RECEIVE_ONLY_PREFIX) {
            return (false, 0);
        }
        return (true, options.toUint128(LZ_RECEIVE_ONLY_PREFIX_LENGTH));
    }
}
