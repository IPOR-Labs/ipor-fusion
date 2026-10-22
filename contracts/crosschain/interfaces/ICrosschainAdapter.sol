// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title ICrosschainAdapter
/// @notice Transport abstraction, kept as documentation of the internal transport API that
///         `StargateOAppBase` realizes. See `contracts/crosschain/stargate/README.md` and
///         `contracts/crosschain/ccip/README.md` for the transports themselves.
/// @dev POC decision: the adapter is NOT an external contract. Executor/dispatcher
///      are the direct LayerZero receivers (the same-address identity invariants rely on it), so this shape is
///      implemented as the internal API `_sendMessage`/`_sendAsset`/`_onMessage`/`_onAssetReceived`
///      (here: `_sendLzMessage`/`_sendAsset` + the `_handleLzMessage`/`_handleCompose` hooks). Nothing
///      implements or imports this interface: the CCIP transport did not adopt it either (`CcipAppBase` has its
///      own internal `_sendCcip` / `_handleCcipMessage` API).
interface ICrosschainAdapter {
    /// @notice Quote the native fee to send a plain message to `dstChainId_`.
    /// @param dstChainId_ Destination EVM chain id.
    /// @param payload_ The message payload (versioned envelope bytes).
    /// @param options_ Transport options (e.g. LayerZero type-3 options).
    /// @return fee The native fee required.
    function quoteMessage(uint256 dstChainId_, bytes calldata payload_, bytes calldata options_)
        external
        view
        returns (uint256 fee);

    /// @notice Send a plain message to `dstChainId_`.
    /// @param dstChainId_ Destination EVM chain id.
    /// @param payload_ The message payload (versioned envelope bytes).
    /// @param options_ Transport options.
    /// @return guid The transport message id.
    function sendMessage(uint256 dstChainId_, bytes calldata payload_, bytes calldata options_)
        external
        payable
        returns (bytes32 guid);

    /// @notice Quote the native fee and minimum received amount for an asset send to `dstChainId_`.
    /// @param dstChainId_ Destination EVM chain id.
    /// @param amount_ Amount to send in local ASSET decimals.
    /// @param options_ Transport options.
    /// @return fee The native fee required.
    /// @return minReceived The minimum destination-credited amount (local decimals).
    function quoteAsset(uint256 dstChainId_, uint256 amount_, bytes calldata options_)
        external
        view
        returns (uint256 fee, uint256 minReceived);

    /// @notice Send `amount_` of the asset (with an optional compose payload) to `dstChainId_`.
    /// @param dstChainId_ Destination EVM chain id.
    /// @param to_ Destination recipient (same-address model uses `address(this)`).
    /// @param amount_ Amount to send in local ASSET decimals.
    /// @param minAmountLD_ Slippage floor in local decimals.
    /// @param composeMsg_ The compose payload accompanying the token delivery.
    /// @param options_ Transport options.
    /// @return guid The transport message id.
    /// @return amountSentLD The actual source-debited amount (local decimals).
    /// @return amountReceivedLD The expected destination-credited amount (local decimals).
    function sendAsset(
        uint256 dstChainId_,
        address to_,
        uint256 amount_,
        uint256 minAmountLD_,
        bytes calldata composeMsg_,
        bytes calldata options_
    ) external payable returns (bytes32 guid, uint256 amountSentLD, uint256 amountReceivedLD);
}
