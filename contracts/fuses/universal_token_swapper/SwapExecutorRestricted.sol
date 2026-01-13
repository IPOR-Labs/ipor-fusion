// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SwapExecutorData
/// @notice Contains all data required for executing token swaps across DEXes
struct SwapExecutorData {
    /// @notice The input token address to be swapped
    address tokenIn;
    /// @notice The output token address to receive
    address tokenOut;
    /// @notice Array of DEX contract addresses to call
    address[] dexs;
    /// @notice Array of encoded function call data for each DEX
    bytes[] dexsData;
}

/// @title SwapExecutorRestricted
/// @notice Executes token swaps across multiple DEX protocols with caller restriction.
///         This contract acts as an intermediary for executing arbitrary swap calls to DEX contracts,
///         ensuring that only a designated RESTRICTED address can initiate swaps.
///         IMPORTANT: This contract is designed to work with ERC20 tokens only and intentionally
///         does NOT accept native ETH. Any direct ETH transfer will be rejected.
/// @dev Architecture and Security:
///      - Uses ReentrancyGuard to prevent reentrancy attacks during external DEX calls.
///      - Only the RESTRICTED address (set at deployment) can call execute() and sweepNative().
///      - After executing swaps, any remaining tokenIn/tokenOut balances are returned to the caller.
///
///      Native ETH Handling (Intentionally Not Supported):
///      - This contract is designed for ERC20 token swaps only and does NOT support native ETH operations.
///      - Direct ETH transfers are explicitly rejected via receive() - this is intentional by design.
///      - ETH can still be force-sent to this contract via selfdestruct (deprecated but still functional).
///      - The sweepNative() function exists solely to recover ETH that was force-sent, not for normal operations.
///
///      Trust Assumptions:
///      - The RESTRICTED address is trusted to provide valid DEX addresses and call data.
///      - External DEX calls are made without value transfer (no msg.value forwarding).
/// @author IPOR Labs
contract SwapExecutorRestricted is ReentrancyGuard {
    using Address for address;
    using SafeERC20 for IERC20;

    /// @notice Error thrown when the restricted address provided in constructor is zero
    error SwapExecutorRestrictedInvalidRestrictedAddress();
    /// @notice Error thrown when caller is not the RESTRICTED address
    error SwapExecutorRestrictedInvalidSender();
    /// @notice Error thrown when dexs and dexsData arrays have different lengths
    error ArrayLengthMismatch();
    /// @notice Error thrown when native ETH is sent directly to this contract
    error SwapExecutorRestrictedReceiveNotSupported();
    /// @notice Error thrown when native ETH transfer fails
    error SwapExecutorRestrictedNativeTransferFailed();

    /// @notice Address of the restricted contract
    address public immutable RESTRICTED;

    /// @notice Deploys the restricted swap executor with a designated caller
    /// @param restricted_ The address authorized to call execute() (must not be zero address)
    /// @custom:revert SwapExecutorRestrictedInvalidRestrictedAddress When restricted_ is zero address
    constructor(address restricted_) {
        if (restricted_ == address(0)) {
            revert SwapExecutorRestrictedInvalidRestrictedAddress();
        }
        RESTRICTED = restricted_;
    }

    /**
     * @notice Rejects any direct native ETH transfers to this contract.
     * @dev This contract intentionally does not accept direct ETH transfers to prevent accidental
     *      ETH loss from users or integrations that mistakenly send ETH to this address.
     *
     *      However, ETH can still arrive at this contract through:
     *      - selfdestruct from another contract (deprecated in Ethereum but still functional)
     *      - Block rewards (if this contract is a coinbase recipient)
     *
     *      Any ETH that arrives through these mechanisms can be recovered using the sweepNative()
     *      function, which is restricted to the RESTRICTED address.
     *
     * @custom:revert SwapExecutorRestrictedReceiveNotSupported Always reverts when ETH is sent directly
     */
    receive() external payable {
        revert SwapExecutorRestrictedReceiveNotSupported();
    }

    /**
     * @notice Modifier that restricts function access to the RESTRICTED address only.
     * @dev Reverts with SwapExecutorRestrictedInvalidSender if msg.sender is not the RESTRICTED address.
     *      This modifier is applied to execute() and sweepNative() functions.
     */
    modifier restricted() {
        if (msg.sender != RESTRICTED) {
            revert SwapExecutorRestrictedInvalidSender();
        }
        _;
    }

    /**
     * @notice Executes a series of token swaps across multiple decentralized exchanges (DEXes). Can only be called by the RESTRICTED address.
     *
     * @dev This function iterates over a list of DEXes and executes a swap on each using provided swap data.
     * After the swaps, the function checks the token balances of both the input token (`tokenIn`) and the output token (`tokenOut`)
     * in the contract. Any remaining tokens of either type are transferred back to the caller.
     * The function will revert if called by any address other than RESTRICTED.
     * Protected against reentrancy via nonReentrant modifier.
     *
     * @param data_ The `SwapExecutorData` struct which contains all the necessary data for executing swaps.
     * It includes:
     * - `dexs`: An array of DEX contract addresses.
     * - `dexsData`: An array of encoded function call data corresponding to each DEX.
     * - `tokenIn`: The address of the input token.
     * - `tokenOut`: The address of the output token.
     * @custom:revert ArrayLengthMismatch When dexs and dexsData arrays have different lengths
     * @custom:revert SwapExecutorRestrictedInvalidSender When caller is not the RESTRICTED address
     * @custom:security External calls to DEX addresses are protected by nonReentrant modifier
     * @custom:security RESTRICTED address must provide valid and trusted DEX addresses
     * @custom:access Only callable by RESTRICTED address
     */
    function execute(SwapExecutorData calldata data_) external restricted nonReentrant {
        uint256 len = data_.dexs.length;
        if (len != data_.dexsData.length) {
            revert ArrayLengthMismatch();
        }
        for (uint256 i; i < len; ) {
            data_.dexs[i].functionCall(data_.dexsData[i]);
            unchecked {
                ++i;
            }
        }

        // Handle tokenIn == tokenOut case to avoid double transfer revert
        if (data_.tokenIn == data_.tokenOut) {
            uint256 balance = IERC20(data_.tokenIn).balanceOf(address(this));
            if (balance > 0) {
                IERC20(data_.tokenIn).safeTransfer(msg.sender, balance);
            }
        } else {
            uint256 balanceTokenIn = IERC20(data_.tokenIn).balanceOf(address(this));
            uint256 balanceTokenOut = IERC20(data_.tokenOut).balanceOf(address(this));

            if (balanceTokenIn > 0) {
                IERC20(data_.tokenIn).safeTransfer(msg.sender, balanceTokenIn);
            }

            if (balanceTokenOut > 0) {
                IERC20(data_.tokenOut).safeTransfer(msg.sender, balanceTokenOut);
            }
        }
    }

    /**
     * @notice Sweeps (recovers) native ETH from the contract to a specified recipient address.
     * @dev This function provides a recovery mechanism for native ETH that may have been
     *      force-sent to this contract through mechanisms that bypass the receive() function.
     *      This is NOT intended for normal operations - only for emergency recovery of stuck ETH.
     *
     *      ETH can be force-sent via:
     *      - selfdestruct: Another contract can force-send its ETH balance to any address
     *        when it self-destructs, regardless of whether the recipient has a payable receive().
     *      - Block rewards: If this contract address is set as a coinbase recipient.
     *
     *      Security considerations:
     *      - Only the RESTRICTED address can call this function to prevent unauthorized sweeps.
     *      - Uses low-level call to transfer ETH, which forwards all available gas.
     *      - Reverts if the ETH transfer fails (e.g., if recipient is a contract that rejects ETH).
     *
     * @param to_ The recipient address for the native ETH sweep. Can be an EOA or a contract
     *            that accepts ETH (has a payable receive/fallback function).
     * @param amount_ The amount of native ETH to sweep in wei. Must not exceed the contract's
     *                current ETH balance.
     * @custom:revert SwapExecutorRestrictedInvalidSender When caller is not the RESTRICTED address
     * @custom:revert SwapExecutorRestrictedNativeTransferFailed When ETH transfer fails (e.g., recipient rejects ETH)
     * @custom:access Only callable by RESTRICTED address
     */
    function sweepNative(address to_, uint256 amount_) external restricted {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = to_.call{value: amount_}("");
        if (!success) {
            revert SwapExecutorRestrictedNativeTransferFailed();
        }
    }
}
