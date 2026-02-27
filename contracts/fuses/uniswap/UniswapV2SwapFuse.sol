// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IUniversalRouter} from "./ext/IUniversalRouter.sol";
import {IFuseCommon} from "../IFuseCommon.sol";

/**
 * @dev Data structure used for entering a swap operation through Uniswap V2. https://docs.uniswap.org/contracts/universal-router/technical-reference
 * @param tokenInAmount The amount of input tokens to swap, this token is first in path.
 * @param path The path of token addresses for the swap, including the input and output tokens.
 * @param minOutAmount The minimum amount of output tokens expected from the swap, this is last token in the path.
 */
struct UniswapV2SwapFuseEnterData {
    uint256 tokenInAmount;
    address[] path;
    uint256 minOutAmount;
}

///@dev this value is from the UniversalRouter contract https://github.com/Uniswap/universal-router/blob/main/contracts/libraries/Commands.sol
uint256 constant V2_SWAP_EXACT_IN = 0x08;
address constant INDICATOR_OF_SENDER_FROM_UNIVERSAL_ROUTER = address(1);

/**
 * @title UniswapV2SwapFuse
 * @dev A smart contract for interacting with the Uniswap V2 protocol to swap tokens.
 *      This contract allows users to exchange tokens using Uniswap's liquidity pools by interfacing with a universal router.
 */
contract UniswapV2SwapFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    error UniswapV2SwapFuseUnsupportedToken(address asset);
    error UnsupportedMethod();

    /**
     * @dev Emitted when a swap is successfully executed through the contract.
     * @param version The version of the contract executing the swap.
     * @param tokenInAmount The amount of input tokens used for the swap.
     * @param path The token path used for the swap.
     * @param minOutAmount The minimum amount of output tokens expected from the swap.
     */
    event UniswapV2SwapFuseEnter(address version, uint256 tokenInAmount, address[] path, uint256 minOutAmount);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable UNIVERSAL_ROUTER;

    /**
     * @dev Initializes the contract with the given market ID and universal router address.
     * @param marketId_ The unique identifier for IporFusionMarkets.sol.
     * @param universalRouter_ The address of the universal router for executing swaps.
     */
    constructor(uint256 marketId_, address universalRouter_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        UNIVERSAL_ROUTER = universalRouter_;
    }

    /**
     * @dev Public function to execute a token swap using Uniswap V2 protocol.
     *      This function verifies the token path and checks if the input amount is valid,
     *      then proceeds to perform the token swap through the Uniswap V2 Universal Router.
     *      The function also emits an event once the swap is successfully executed.
     *
     * Requirements:
     * - The `tokenInAmount` must be greater than zero.
     * - The `path` array must contain at least two addresses (input and output tokens).
     * - Each token in the `path` must be a supported asset according to `PlasmaVaultConfigLib`.
     * - The contract must have enough balance of the input token to perform the swap.
     *
     * Emits an `UniswapV2SwapFuseEnter` event indicating the details of the swap.
     * @param data_ The swap data containing tokenInAmount, path, and minOutAmount
     * @return tokenInAmount The amount of input tokens used for the swap
     * @return path The token path used for the swap
     * @return minOutAmount The minimum amount of output tokens expected from the swap
     */
    function enter(
        UniswapV2SwapFuseEnterData memory data_
    ) public returns (uint256 tokenInAmount, address[] memory path, uint256 minOutAmount) {
        uint256 pathLength = data_.path.length;
        if (data_.tokenInAmount == 0 || pathLength < 2) {
            return (data_.tokenInAmount, data_.path, data_.minOutAmount);
        }

        for (uint256 i; i < pathLength; ++i) {
            if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.path[i])) {
                revert UniswapV2SwapFuseUnsupportedToken(data_.path[i]);
            }
        }

        /// @dev the first token in the path is the input token to swap which has to be in the vault
        uint256 vaultBalance = IERC20(data_.path[0]).balanceOf(address(this));

        uint256 inputAmount = data_.tokenInAmount <= vaultBalance ? data_.tokenInAmount : vaultBalance;

        if (inputAmount == 0) {
            return (data_.tokenInAmount, data_.path, data_.minOutAmount);
        }

        IERC20(data_.path[0]).safeTransfer(UNIVERSAL_ROUTER, inputAmount);

        bytes memory commands = abi.encodePacked(bytes1(uint8(V2_SWAP_EXACT_IN)));

        bytes[] memory inputs = new bytes[](1);

        inputs[0] = abi.encode(
            INDICATOR_OF_SENDER_FROM_UNIVERSAL_ROUTER,
            inputAmount,
            data_.minOutAmount,
            data_.path,
            false
        );

        IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs);

        tokenInAmount = data_.tokenInAmount;
        path = data_.path;
        minOutAmount = data_.minOutAmount;

        emit UniswapV2SwapFuseEnter(VERSION, tokenInAmount, path, minOutAmount);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Reads inputs from transient storage: tokenInAmount (inputs[0]), pathLength (inputs[1]),
    ///      path addresses (inputs[2..2+pathLength-1]), minOutAmount (inputs[2+pathLength]).
    ///      Writes returned tokenInAmount, path length, path addresses, and minOutAmount to transient storage outputs.
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        uint256 tokenInAmount = TypeConversionLib.toUint256(inputs[0]);
        uint256 pathLength = TypeConversionLib.toUint256(inputs[1]);

        address[] memory path = _buildAddressArrayFromInputs(inputs, 2, pathLength);

        uint256 minOutAmount = TypeConversionLib.toUint256(inputs[2 + pathLength]);

        UniswapV2SwapFuseEnterData memory data = UniswapV2SwapFuseEnterData({
            tokenInAmount: tokenInAmount,
            path: path,
            minOutAmount: minOutAmount
        });

        (uint256 returnedTokenInAmount, address[] memory returnedPath, uint256 returnedMinOutAmount) = enter(data);

        _storeOutputs(returnedTokenInAmount, returnedPath, returnedMinOutAmount);
    }

    /// @notice Helper function to build address array from transient storage inputs
    /// @param inputs_ Array of input values from transient storage
    /// @param startIndex_ Starting index where address data begins
    /// @param length_ Number of addresses in the array
    /// @return The constructed address array
    function _buildAddressArrayFromInputs(
        bytes32[] memory inputs_,
        uint256 startIndex_,
        uint256 length_
    ) private pure returns (address[] memory) {
        address[] memory result = new address[](length_);
        for (uint256 i; i < length_; ++i) {
            result[i] = TypeConversionLib.toAddress(inputs_[startIndex_ + i]);
        }
        return result;
    }

    /// @notice Helper function to store outputs including address array path to transient storage
    /// @param tokenInAmount_ The amount of input tokens used for the swap
    /// @param path_ The token path used for the swap
    /// @param minOutAmount_ The minimum amount of output tokens expected from the swap
    function _storeOutputs(uint256 tokenInAmount_, address[] memory path_, uint256 minOutAmount_) private {
        uint256 pathLength = path_.length;
        // Outputs: [tokenInAmount, pathLength, pathAddresses..., minOutAmount]
        uint256 outputsLength = 2 + pathLength + 1;
        bytes32[] memory outputs = new bytes32[](outputsLength);

        outputs[0] = TypeConversionLib.toBytes32(tokenInAmount_);
        outputs[1] = TypeConversionLib.toBytes32(pathLength);

        // Store path addresses
        for (uint256 i; i < pathLength; ++i) {
            outputs[2 + i] = TypeConversionLib.toBytes32(path_[i]);
        }

        outputs[outputsLength - 1] = TypeConversionLib.toBytes32(minOutAmount_);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
