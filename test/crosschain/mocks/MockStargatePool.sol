// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SendParam,
    OFTReceipt,
    OFTLimit,
    OFTFeeDetail
} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Ticket} from "@stargatefinance/stg-evm-v2/src/interfaces/IStargate.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";

/// @title LzComposeBuilder
/// @notice Builds an OFT compose message (`OFTComposeMsgCodec` layout) the test can deliver to a receiver.
/// @dev Layout: nonce(8) | srcEid(4) | amountLD(32) | composeFrom(32) | envelope. The envelope is the
///      `CrosschainMessages` envelope carried as the compose payload.
library LzComposeBuilder {
    function build(address composeFrom_, uint32 srcEid_, uint256 amountLD_, bytes memory envelope_)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory inner = abi.encodePacked(bytes32(uint256(uint160(composeFrom_))), envelope_);
        return OFTComposeMsgCodec.encode(uint64(1), srcEid_, amountLD_, inner);
    }

    /// @notice Same as `build` but with an arbitrary raw `composeFrom_` (for forged-sender negatives).
    function buildRawFrom(bytes32 composeFrom_, uint32 srcEid_, uint256 amountLD_, bytes memory envelope_)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory inner = abi.encodePacked(composeFrom_, envelope_);
        return OFTComposeMsgCodec.encode(uint64(1), srcEid_, amountLD_, inner);
    }
}

/// @title MockStargatePool
/// @notice `IStargate`-shaped pool: `token()`, `sharedDecimals()`, `quoteSend`, `sendToken`. `sendToken`
///         pulls the ERC20 via `transferFrom`, records the params, enforces the `minAmountLD` slippage
///         floor, and returns configurable `amountSent/amountReceived` + a deterministic guid.
/// @dev Not a real bridge — the destination credit is simulated by the test (mint tokens to the receiver
///      then deliver a compose). Selector-compatible with `IStargate`; does not inherit it.
contract MockStargatePool {
    uint256 private constant BPS = 10_000;

    address public immutable TOKEN;
    uint8 public immutable SHARED_DECIMALS;

    /// @notice Fee applied to the received amount, in bps (amountReceivedLD = amountLD * (BPS - feeBps) / BPS).
    uint256 public feeBps;
    /// @notice Settable native fee returned by `quoteSend` (and required by `sendToken`).
    uint256 public assetFee = 1e14;

    /// @notice Optional exact overrides for the next `sendToken` (0 = derive from amount/feeBps).
    uint256 public nextAmountSentLD;
    uint256 public nextAmountReceivedLD;

    /// @notice Live path credit, mirroring Stargate's `OFTLimit.maxAmountLD` / `Path_InsufficientCredit`.
    ///         Ignored until `setPathCredit` is called (then unlimited). `sendToken` checks the credit against the
    ///         amount OUT (`amountReceivedLD`), like the real pool; a reward is expressed via `setNextAmounts`.
    bool public pathCreditSet;
    uint256 public pathCredit;

    uint64 public nonce;
    bytes32 public lastGuid;

    struct Send {
        uint32 dstEid;
        bytes32 to;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes composeMsg;
        bytes extraOptions;
        bytes32 guid;
    }

    Send[] internal _sends;

    error SlippageExceeded(uint256 amountReceivedLD, uint256 minAmountLD);
    error Path_InsufficientCredit();

    constructor(address token_, uint8 sharedDecimals_) {
        TOKEN = token_;
        SHARED_DECIMALS = sharedDecimals_;
    }

    // ---------------------------------------------------------------------
    // IStargate-shaped surface
    // ---------------------------------------------------------------------

    function token() external view returns (address) {
        return TOKEN;
    }

    function sharedDecimals() external view returns (uint8) {
        return SHARED_DECIMALS;
    }

    function quoteSend(SendParam calldata, bool) external view returns (MessagingFee memory) {
        return MessagingFee({nativeFee: assetFee, lzTokenFee: 0});
    }

    /// @notice Quotes the credit `sendToken` would apply in the same state: the same overrides and `feeBps`.
    function quoteOFT(SendParam calldata sendParam_)
        external
        view
        returns (OFTLimit memory limit, OFTFeeDetail[] memory feeDetails, OFTReceipt memory receipt)
    {
        receipt = OFTReceipt({
            amountSentLD: nextAmountSentLD != 0 ? nextAmountSentLD : sendParam_.amountLD,
            amountReceivedLD: nextAmountReceivedLD != 0
                ? nextAmountReceivedLD
                : (sendParam_.amountLD * (BPS - feeBps)) / BPS
        });
        limit = OFTLimit({minAmountLD: 0, maxAmountLD: type(uint256).max});
        if (pathCreditSet) {
            // Real Stargate V2 caps the quote at the live path credit instead of reverting.
            limit.maxAmountLD = pathCredit;
            if (receipt.amountSentLD > pathCredit) receipt.amountSentLD = pathCredit;
            // `amountReceivedLD` is NOT capped: the real pool charges credit on the amount OUT, so a reward
            // above the credit stays visible to the caller as `amountReceivedLD > maxAmountLD`.
        }
    }

    function sendToken(SendParam calldata sendParam_, MessagingFee calldata, address)
        external
        payable
        returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt, Ticket memory ticket)
    {
        // Pull the tokens from the caller (executor/dispatcher forceApproved this pool for amountLD).
        IERC20(TOKEN).transferFrom(msg.sender, address(this), sendParam_.amountLD);

        uint256 amountSentLD = nextAmountSentLD != 0 ? nextAmountSentLD : sendParam_.amountLD;
        uint256 amountReceivedLD =
            nextAmountReceivedLD != 0 ? nextAmountReceivedLD : (sendParam_.amountLD * (BPS - feeBps)) / BPS;
        nextAmountSentLD = 0;
        nextAmountReceivedLD = 0;

        // Real Stargate decreases path credit by the amount OUT (after fee or reward), not the amount in.
        if (pathCreditSet && amountReceivedLD > pathCredit) revert Path_InsufficientCredit();

        if (amountReceivedLD < sendParam_.minAmountLD) {
            revert SlippageExceeded(amountReceivedLD, sendParam_.minAmountLD);
        }

        uint64 n = ++nonce;
        bytes32 guid = keccak256(abi.encode("STG", address(this), n, sendParam_.dstEid));
        lastGuid = guid;
        _sends.push(
            Send({
                dstEid: sendParam_.dstEid,
                to: sendParam_.to,
                amountLD: sendParam_.amountLD,
                minAmountLD: sendParam_.minAmountLD,
                composeMsg: sendParam_.composeMsg,
                extraOptions: sendParam_.extraOptions,
                guid: guid
            })
        );

        msgReceipt = MessagingReceipt({guid: guid, nonce: n, fee: MessagingFee({nativeFee: msg.value, lzTokenFee: 0})});
        oftReceipt = OFTReceipt({amountSentLD: amountSentLD, amountReceivedLD: amountReceivedLD});
        ticket = Ticket({ticketId: 0, passengerBytes: ""});
    }

    // ---------------------------------------------------------------------
    // Test configuration & views
    // ---------------------------------------------------------------------

    function setFeeBps(uint256 feeBps_) external {
        feeBps = feeBps_;
    }

    /// @notice Cap the live path credit: `quoteOFT` clamps to it, `sendToken` reverts above it.
    function setPathCredit(uint256 creditLD_) external {
        pathCreditSet = true;
        pathCredit = creditLD_;
    }

    function setAssetFee(uint256 assetFee_) external {
        assetFee = assetFee_;
    }

    /// @notice Force the exact `amountSent`/`amountReceived` returned by the next `sendToken`.
    function setNextAmounts(uint256 amountSentLD_, uint256 amountReceivedLD_) external {
        nextAmountSentLD = amountSentLD_;
        nextAmountReceivedLD = amountReceivedLD_;
    }

    function sendCount() external view returns (uint256) {
        return _sends.length;
    }

    function sendAt(uint256 i_) external view returns (Send memory) {
        return _sends[i_];
    }

    function lastSend() external view returns (Send memory) {
        return _sends[_sends.length - 1];
    }

    receive() external payable {}
}
