// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    CcipClient,
    ICcipRouterClient,
    ICcipMessageReceiver
} from "../../../contracts/crosschain/ccip/interfaces/CcipClient.sol";

contract MockCcipRouter is ICcipRouterClient {
    mapping(address => uint64) public selectorOf;
    uint256 public fee;
    /// @dev Token-pool haircut: this share (bps) of every delivered token amount is withheld by the "pool".
    uint256 public poolHaircutBps;
    bool public autoDeliver = true;
    mapping(address => bool) public failSend;
    /// @dev Per-sender arbitrary revert data for TOKEN-BEARING `ccipSend`s only (a token pool's rate-limit custom
    ///      error never affects a token-less message). Use `failSend` to fail every send.
    mapping(address => bytes) public failSendWith;
    bytes public lastExtraArgs;
    uint256 private _nonce;

    /// @dev A token-less message sent while `autoDeliver` was off: one still in flight, or one FAILED on the
    ///      OffRamp and manually executable by anyone later. Delivered on demand through `deliverHeld`.
    struct HeldMessage {
        address receiver;
        bytes32 messageId;
        uint64 sourceChainSelector;
        address sender;
        bytes data;
    }

    HeldMessage[] internal _held;

    /// @dev When set, a single-token message sent while `autoDeliver` is off is held too (its tokens already
    ///      moved), modelling a token return that has left the sender but not yet executed on the receiver.
    bool public holdTokenMessages;
    mapping(uint256 index => CcipClient.EVMTokenAmount) internal _heldToken;

    function setSelector(address sender_, uint64 selector_) external {
        selectorOf[sender_] = selector_;
    }

    function setFee(uint256 fee_) external {
        fee = fee_;
    }

    function setPoolHaircutBps(uint256 bps_) external {
        poolHaircutBps = bps_;
    }

    function setAutoDeliver(bool autoDeliver_) external {
        autoDeliver = autoDeliver_;
    }

    function setHoldTokenMessages(bool hold_) external {
        holdTokenMessages = hold_;
    }

    function setFailSend(address sender_, bool fail_) external {
        failSend[sender_] = fail_;
    }

    /// @notice Make token-bearing `ccipSend`s revert with exactly `revertData_` for `sender_`; empty data clears it.
    function setFailSendWith(address sender_, bytes calldata revertData_) external {
        failSendWith[sender_] = revertData_;
    }

    function isChainSupported(uint64) external pure returns (bool) {
        return true;
    }

    function getFee(uint64, CcipClient.EVM2AnyMessage memory) external view returns (uint256) {
        return fee;
    }

    function ccipSend(uint64, CcipClient.EVM2AnyMessage calldata message_)
        external
        payable
        returns (bytes32 messageId)
    {
        bytes memory forced = failSendWith[msg.sender];
        if (forced.length != 0 && message_.tokenAmounts.length != 0) {
            assembly ("memory-safe") {
                revert(add(forced, 32), mload(forced))
            }
        }
        require(!failSend[msg.sender], "forced send failure");
        require(msg.value == (message_.feeToken == address(0) ? fee : 0), "fee");
        lastExtraArgs = message_.extraArgs;
        address receiver = abi.decode(message_.receiver, (address));
        CcipClient.EVMTokenAmount[] memory delivered = new CcipClient.EVMTokenAmount[](message_.tokenAmounts.length);
        for (uint256 i; i < message_.tokenAmounts.length; ++i) {
            CcipClient.EVMTokenAmount calldata tokenAmount = message_.tokenAmounts[i];
            uint256 withheld = tokenAmount.amount * poolHaircutBps / 10_000;
            IERC20(tokenAmount.token).transferFrom(msg.sender, receiver, tokenAmount.amount - withheld);
            if (withheld != 0) IERC20(tokenAmount.token).transferFrom(msg.sender, address(this), withheld);
            delivered[i] = CcipClient.EVMTokenAmount(tokenAmount.token, tokenAmount.amount - withheld);
        }
        if (message_.feeToken != address(0) && fee != 0) {
            IERC20(message_.feeToken).transferFrom(msg.sender, address(this), fee);
        }
        messageId = keccak256(abi.encode(address(this), msg.sender, receiver, ++_nonce));
        if (!autoDeliver) {
            if (message_.tokenAmounts.length == 0 || (holdTokenMessages && message_.tokenAmounts.length == 1)) {
                if (message_.tokenAmounts.length == 1) _heldToken[_held.length] = delivered[0];
                _held.push(HeldMessage(receiver, messageId, selectorOf[msg.sender], msg.sender, message_.data));
            }
        } else {
            ICcipMessageReceiver(receiver)
                .ccipReceive(
                    CcipClient.Any2EVMMessage({
                    messageId: messageId,
                    sourceChainSelector: selectorOf[msg.sender],
                    sender: abi.encode(msg.sender),
                    data: message_.data,
                    destTokenAmounts: delivered
                })
                );
        }
    }

    function heldCount() external view returns (uint256) {
        return _held.length;
    }

    /// @notice The raw CCIP payload (`CcipMessages.encode(type, data)`) of a held message.
    function heldData(uint256 index_) external view returns (bytes memory) {
        return _held[index_].data;
    }

    /// @notice Execute a held message now, as a late delivery or a permissionless manual execution would.
    /// @dev A receiver revert bubbles up, leaving the message executable again — the OffRamp's FAILED state.
    function deliverHeld(uint256 index_) external {
        HeldMessage storage held = _held[index_];
        CcipClient.EVMTokenAmount memory heldToken = _heldToken[index_];
        CcipClient.EVMTokenAmount[] memory tokens = new CcipClient.EVMTokenAmount[](heldToken.amount == 0 ? 0 : 1);
        if (heldToken.amount != 0) tokens[0] = heldToken;
        ICcipMessageReceiver(held.receiver)
            .ccipReceive(
                CcipClient.Any2EVMMessage({
                messageId: held.messageId,
                sourceChainSelector: held.sourceChainSelector,
                sender: abi.encode(held.sender),
                data: held.data,
                destTokenAmounts: tokens
            })
            );
    }

    /// @notice `deliverHeld` with the receiver called with EXACTLY `gasLimit_` gas, the way the real Router does
    ///         (`callWithExactGas(gasLimit)`): the receiver sees the message's gas limit and no more.
    function deliverHeldExact(uint256 index_, uint256 gasLimit_) external {
        HeldMessage storage held = _held[index_];
        CcipClient.EVMTokenAmount memory heldToken = _heldToken[index_];
        CcipClient.EVMTokenAmount[] memory tokens = new CcipClient.EVMTokenAmount[](heldToken.amount == 0 ? 0 : 1);
        if (heldToken.amount != 0) tokens[0] = heldToken;
        ICcipMessageReceiver(held.receiver).ccipReceive{gas: gasLimit_}(
            CcipClient.Any2EVMMessage({
                messageId: held.messageId,
                sourceChainSelector: held.sourceChainSelector,
                sender: abi.encode(held.sender),
                data: held.data,
                destTokenAmounts: tokens
            })
        );
    }
}
