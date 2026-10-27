// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IStargate} from "@stargatefinance/stg-evm-v2/src/interfaces/IStargate.sol";
import {SendParam, OFTReceipt, OFTLimit} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

import {CrosschainErrors} from "../../lib/CrosschainErrors.sol";
import {StargateNativeFeeCapLib} from "./StargateNativeFeeCapLib.sol";

/// @notice Linked Stargate taxi sender shared by executor and dispatcher runtimes. The ceiling check runs
///         before the scoped approval, so a rejected quote leaves no allowance behind.
library StargateAssetSendLib {
    using SafeERC20 for IERC20;

    /// @notice Parameters of one taxi send.
    /// @param pool The Stargate pool (or OFT) that sends `asset`.
    /// @param asset The ERC-20 sent; approved to `pool` only for the duration of the send.
    /// @param dstChainId Destination chain id; the key of the native fee ceiling (`StargateNativeFeeCapLib`).
    /// @param dstEid Destination LayerZero endpoint id.
    /// @param amountLD Amount to send, in local decimals.
    /// @param minAmountLD Slippage floor, in local decimals.
    /// @param composeMsg The compose payload delivered with the asset.
    /// @param options Combined options: the path's enforced options plus the caller's. The recipient is not a
    ///        parameter: it is always `address(this)` on the destination chain.
    struct SendAssetParams {
        IStargate pool;
        address asset;
        uint256 dstChainId;
        uint32 dstEid;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes composeMsg;
        bytes options;
    }

    /// @notice Emitted by the library for every completed send; same fields as `StargateOAppBase.AssetSent`.
    /// @param dstChainId Destination chain id.
    /// @param guid The Stargate/LayerZero message guid.
    /// @param amountSentLD The amount debited on the source, in local decimals.
    /// @param amountReceivedLD The amount the pool expects to credit on the destination, in local decimals.
    event AssetSent(uint256 dstChainId, bytes32 guid, uint256 amountSentLD, uint256 amountReceivedLD);

    /// @notice Sends `params_.amountLD` of the asset through the Stargate pool in taxi mode with a compose payload,
    ///         paying the fee from this contract's native balance.
    /// @dev Quotes the send, enforces the factory's native fee ceiling for executors (`StargateNativeFeeCapLib`),
    ///      checks the native budget, then sets a scoped approval around the send and resets it to zero.
    ///      Reverts if the pool would credit less than `minAmountLD` or the path has too little credit; the
    ///      skipping variant is `sendAssetUnlessShortCredit`.
    /// @param params_ The send parameters; see `SendAssetParams`.
    /// @return guid The Stargate/LayerZero message guid.
    /// @return amountSentLD The amount debited on the source, in local decimals.
    /// @return amountReceivedLD The amount the pool expects to credit on the destination, in local decimals.
    function sendAsset(SendAssetParams memory params_)
        public
        returns (bytes32 guid, uint256 amountSentLD, uint256 amountReceivedLD)
    {
        return _sendAsset(params_, false);
    }

    /// @notice `sendAsset`, except that a send the pool would credit below `minAmountLD`, or that exceeds the
    ///         path's live credit, is skipped instead of reverting inside `sendToken`: nothing is approved or sent,
    ///         and the guid is zero (IL-8452, IL-8616). A paused pool or FeeLib path still reverts (README, IL-8616).
    /// @dev `quoteOFT` runs the pool's own fee model on the same state `sendToken` uses in this call, so the
    ///      quoted credit is the credit `sendToken` checks against `minAmountLD`. It is NOT the credit
    ///      `sendToken` checks against the live path credit: `quoteOFT` silently CAPS the quote at
    ///      `OFTLimit.maxAmountLD` while `sendToken` reverts `Path_InsufficientCredit` on the full `amountLD`.
    ///      The pool charges path credit on the amount OUT (after fee or reward), so a reward can push a send
    ///      that fits the credit as an input (`amountLD <= credit`) over the cap (`amountReceivedLD > credit`).
    ///      A quote capped below `amountLD`, or an output above the cap, is therefore skipped too (IL-8616).
    ///      Returns `(0, amountLD, 0)` when skipped because of the cap and `(0, 0, 0)` when skipped because of
    ///      the floor, so the caller can tell the two apart without a second quote.
    function sendAssetUnlessShortCredit(SendAssetParams memory params_)
        public
        returns (bytes32 guid, uint256 amountSentLD, uint256 amountReceivedLD)
    {
        return _sendAsset(params_, true);
    }

    function _sendAsset(SendAssetParams memory params_, bool skipShortCredit_)
        private
        returns (bytes32 guid, uint256 amountSentLD, uint256 amountReceivedLD)
    {
        SendParam memory sendParam = SendParam({
            dstEid: params_.dstEid,
            to: bytes32(uint256(uint160(address(this)))),
            amountLD: params_.amountLD,
            minAmountLD: params_.minAmountLD,
            extraOptions: params_.options,
            composeMsg: params_.composeMsg,
            oftCmd: ""
        });
        if (skipShortCredit_) {
            (OFTLimit memory limit,, OFTReceipt memory quoted) = params_.pool.quoteOFT(sendParam);
            if (
                params_.amountLD > limit.maxAmountLD || quoted.amountReceivedLD > limit.maxAmountLD
                    || quoted.amountSentLD < params_.amountLD
            ) {
                return (bytes32(0), params_.amountLD, 0);
            }
            if (quoted.amountReceivedLD < params_.minAmountLD) return (bytes32(0), 0, 0);
        }
        MessagingFee memory fee = params_.pool.quoteSend(sendParam, false);
        StargateNativeFeeCapLib.enforce(params_.dstChainId, fee.nativeFee);
        uint256 balance = address(this).balance;
        if (balance < fee.nativeFee) revert CrosschainErrors.InsufficientNativeBudget(balance, fee.nativeFee);

        IERC20(params_.asset).forceApprove(address(params_.pool), params_.amountLD);
        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt,) =
            params_.pool.sendToken{value: fee.nativeFee}(sendParam, fee, address(this));
        IERC20(params_.asset).forceApprove(address(params_.pool), 0);

        guid = msgReceipt.guid;
        amountSentLD = oftReceipt.amountSentLD;
        amountReceivedLD = oftReceipt.amountReceivedLD;
        emit AssetSent(params_.dstChainId, guid, amountSentLD, amountReceivedLD);
    }
}
