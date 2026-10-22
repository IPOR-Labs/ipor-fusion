// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {
    Origin,
    MessagingParams,
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";

/// @notice Minimal LayerZero receiver surface an OApp exposes to the endpoint.
interface ILzReceiverLike {
    function lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) external payable;
}

/// @title MockLzEndpoint
/// @notice Lightweight stand-in for the LayerZero V2 endpoint used as the OApp `endpoint`. It records
///         every outbound `send`, returns a deterministic guid/nonce, quotes a settable native fee, and
///         lets a test drive inbound `lzReceive` / `lzCompose` AS the endpoint (msg.sender == endpoint).
/// @dev Not a full endpoint: only the selectors the vendored `OAppSender`/`OAppReceiver` actually call
///      (`setDelegate`, `quote`, `send`) plus test-only delivery helpers. No real packet transport.
contract MockLzEndpoint {
    struct SentMessage {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bytes options;
        uint256 nativeFee;
        bytes32 guid;
    }

    SentMessage[] internal _sent;
    uint64 public nonce;

    /// @notice Settable native fee returned by `quote` (and required by `send`).
    uint256 public messagingFee = 1e14;

    /// @notice Test-only: when set, `quote` rejects options of at most the type-3 header,
    ///         approximating the real send library's `LZ_ULN_InvalidWorkerOptions` /
    ///         `Executor_NoOptions` reverts (IL-8296). Default off so every other suite is untouched.
    bool public requireExecutorOptions;

    /// @notice Test-only: native fee per unit of the TOTAL executor `lzReceive` gas in the options (summed over every
    ///         lzReceive option, like the real executor), added to `messagingFee`. 0 (default) leaves every suite untouched.
    uint256 public feePerLzReceiveGas;

    event Delegated(address caller, address delegate);

    /// @notice Thrown by `quote` when `requireExecutorOptions` is on and `options` carries at most the
    ///         type-3 header. Approximates two of the reverts observed on a mainnet fork for these
    ///         option shapes: empty options -> `LZ_ULN_InvalidWorkerOptions(0)`, header-only options ->
    ///         `Executor_NoOptions()`. (A third observed shape, a zero-gas lzReceive option ->
    ///         `Executor_ZeroLzReceiveGasProvided()`, is not modeled here since this mock only inspects
    ///         `options.length <= 2`.)
    error MockOptionsRejected(bytes options);

    // ---------------------------------------------------------------------
    // Endpoint surface used by the OApp
    // ---------------------------------------------------------------------

    function setDelegate(address delegate_) external {
        emit Delegated(msg.sender, delegate_);
    }

    function quote(MessagingParams calldata params_, address) external view returns (MessagingFee memory) {
        if (requireExecutorOptions && params_.options.length <= 2) {
            revert MockOptionsRejected(params_.options);
        }
        return MessagingFee({nativeFee: messagingFee + feePerLzReceiveGas * lzReceiveGasOf(params_.options), lzTokenFee: 0});
    }

    /// @notice Sum of the executor `lzReceive` gas of every lzReceive option in type-3 `options_`
    ///         (`0x0003` header, then `[workerId(1) | size(2) | optionType(1) | data]` entries).
    function lzReceiveGasOf(bytes memory options_) public pure returns (uint256 total) {
        uint256 i = 2;
        while (i + 4 <= options_.length) {
            uint256 size = (uint256(uint8(options_[i + 1])) << 8) | uint256(uint8(options_[i + 2]));
            if (uint8(options_[i]) == 1 && uint8(options_[i + 3]) == 1 && size >= 17) {
                uint256 gas;
                for (uint256 j; j < 16; ++j) {
                    gas = (gas << 8) | uint256(uint8(options_[i + 4 + j]));
                }
                total += gas;
            }
            i += 3 + size;
        }
    }

    function send(MessagingParams calldata params_, address) external payable returns (MessagingReceipt memory) {
        uint64 n = ++nonce;
        bytes32 guid = keccak256(abi.encode(address(this), n, params_.dstEid, params_.message));
        _sent.push(
            SentMessage({
                dstEid: params_.dstEid,
                receiver: params_.receiver,
                message: params_.message,
                options: params_.options,
                nativeFee: msg.value,
                guid: guid
            })
        );
        return MessagingReceipt({guid: guid, nonce: n, fee: MessagingFee({nativeFee: msg.value, lzTokenFee: 0})});
    }

    /// @notice No-op inbound packet-hygiene entry points (real endpoint: IMessagingChannel / clear), so a
    ///         rescue that targets them can execute end to end in tests.
    function clear(address, Origin calldata, bytes32, bytes calldata) external {}

    function skip(address, uint32, bytes32, uint64) external {}

    function nilify(address, uint32, bytes32, uint64, bytes32) external {}

    function burn(address, uint32, bytes32, uint64, bytes32) external {}

    function lzToken() external pure returns (address) {
        return address(0);
    }

    // ---------------------------------------------------------------------
    // Test configuration
    // ---------------------------------------------------------------------

    function setMessagingFee(uint256 fee_) external {
        messagingFee = fee_;
    }

    function setFeePerLzReceiveGas(uint256 fee_) external {
        feePerLzReceiveGas = fee_;
    }

    /// @notice Test-only switch: see `requireExecutorOptions`.
    function setRequireExecutorOptions(bool require_) external {
        requireExecutorOptions = require_;
    }

    // ---------------------------------------------------------------------
    // Inbound delivery helpers (called by the TEST; msg.sender to the OApp == this endpoint)
    // ---------------------------------------------------------------------

    /// @notice Deliver a plain LayerZero message to `oapp` as the endpoint would.
    function deliverLz(address oapp_, uint32 srcEid_, bytes32 sender_, bytes32 guid_, bytes calldata message_)
        external
    {
        ILzReceiverLike(oapp_)
            .lzReceive(Origin({srcEid: srcEid_, sender: sender_, nonce: 1}), guid_, message_, address(0), "");
    }

    /// @notice Deliver an OFT compose (token + payload) to `oapp` as the endpoint would.
    function deliverCompose(address oapp_, address from_, bytes32 guid_, bytes calldata message_) external {
        ILayerZeroComposer(oapp_).lzCompose(from_, guid_, message_, address(0), "");
    }

    // ---------------------------------------------------------------------
    // Views over recorded outbound messages
    // ---------------------------------------------------------------------

    function sentCount() external view returns (uint256) {
        return _sent.length;
    }

    function sentAt(uint256 i_) external view returns (SentMessage memory) {
        return _sent[i_];
    }

    function lastSent() external view returns (SentMessage memory) {
        return _sent[_sent.length - 1];
    }

    function lastMessage() external view returns (bytes memory) {
        return _sent[_sent.length - 1].message;
    }

    receive() external payable {}
}
