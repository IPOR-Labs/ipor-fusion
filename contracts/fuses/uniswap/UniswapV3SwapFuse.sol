// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {IUniversalRouter} from "./ext/IUniversalRouter.sol";
import {IFuseCommon} from "../IFuseCommon.sol";

/**
 * @dev Data structure used for entering a swap operation through Uniswap V3.  https://docs.uniswap.org/contracts/universal-router/technical-reference
 * @param tokenInAmount The amount of input tokens to swap.
 * @param minOutAmount The minimum amount of output tokens expected from the swap.
 * @param path Encoded path for the swap, containing addresses and pool fees ([address, fee,address, fee,... ,  address ]).
 */
struct UniswapV3SwapFuseEnterData {
    uint256 tokenInAmount;
    uint256 minOutAmount;
    bytes path;
}

//@dev this value is from the UniversalRouter contract https://github.com/Uniswap/universal-router/blob/main/contracts/libraries/Commands.sol
uint256 constant V3_SWAP_EXACT_IN = 0x00;
/// @dev The length of the bytes encoded address
uint256 constant ADDR_SIZE = 20;
/// @dev The length of the bytes encoded fee
uint256 constant V3_FEE_SIZE = 3;
/// @dev The offset of a single token address (20) and pool fee (3)
uint256 constant NEXT_V3_POOL_OFFSET = ADDR_SIZE + V3_FEE_SIZE;
/// @dev The offset of an encoded pool key
/// Token (20) + Fee (3) + Token (20) = 43
uint256 constant V3_POP_OFFSET = NEXT_V3_POOL_OFFSET + ADDR_SIZE;
/// @dev The minimum length of an encoding that contains 2 or more pools
uint256 constant MULTIPLE_V3_POOLS_MIN_LENGTH = V3_POP_OFFSET + NEXT_V3_POOL_OFFSET;
// @dev if this value is send the universal router will use the msg sender as the sender
address constant INDICATOR_OF_SENDER_FROM_UNIVERSAL_ROUTER = address(1);

/**
 * @title UniswapV3SwapFuse.sol
 * @dev A smart contract for interacting with the Uniswap V3 protocol to swap tokens.
 *      This contract allows users to exchange tokens using Uniswap's liquidity pools by interfacing with a universal router.
 */
contract UniswapV3SwapFuse is IFuseCommon {
    using SafeERC20 for IERC20;
    using SafeCast for int256;
    using SafeCast for uint256;

    error UniswapV3SwapFuseUnsupportedToken(address asset);
    error UnsupportedMethod();
    error SliceOutOfBounds();

    /**
     * @dev Emitted when a swap is successfully executed through the contract.
     * @param version The version of the contract executing the swap.
     * @param tokenInAmount The amount of input tokens used for the swap.
     * @param path The encoded path used for the swap.
     * @param minOutAmount The minimum amount of output tokens expected from the swap.
     */
    event UniswapV3SwapFuseEnter(address version, uint256 tokenInAmount, bytes path, uint256 minOutAmount);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable UNIVERSAL_ROUTER;

    /**
     * @dev Initializes the contract with the given market ID and universal router address.
     * @param marketId_ The unique identifier for the market configuration.
     * @param universalRouter_ The address of the universal router for executing swaps. https://github.com/Uniswap/universal-router/tree/main/deploy-addresses
     */
    constructor(uint256 marketId_, address universalRouter_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        UNIVERSAL_ROUTER = universalRouter_;
    }

    /**
     * @dev Public function to execute a token swap using Uniswap V3 protocol.
     *      This function verifies the token path, checks if the input amount is valid,
     *      and then proceeds to perform the token swap through the Uniswap V3 Universal Router.
     *
     * Requirements:
     * - The `tokenInAmount` must be greater than zero.
     * - The `path` must contain valid token addresses and fee information.
     * - Each token in the `path` must be a supported asset according to `PlasmaVaultConfigLib`.
     * - The contract must have enough balance of the input token to perform the swap.
     *
     * Emits an `UniswapV3SwapFuseEnter` event indicating the details of the swap.
     * @param data_ The swap data containing tokenInAmount, minOutAmount, and path
     * @return tokenInAmount The amount of input tokens used for the swap
     * @return path The encoded path used for the swap
     * @return minOutAmount The minimum amount of output tokens expected from the swap
     */
    function enter(
        UniswapV3SwapFuseEnterData memory data_
    ) public returns (uint256 tokenInAmount, bytes memory path, uint256 minOutAmount) {
        address[] memory tokens;
        bytes memory pathCalldata = data_.path;
        bytes memory memoryPath = data_.path;
        uint256 numberOfTokens;

        if (_hasMultiplePools(pathCalldata)) {
            numberOfTokens =
                ((pathCalldata.length.toInt256() - ADDR_SIZE.toInt256()).toUint256() / NEXT_V3_POOL_OFFSET) +
                1;
            tokens = new address[](numberOfTokens);
            for (uint256 i; i < numberOfTokens; ++i) {
                tokens[i] = _decodeFirstToken(pathCalldata);
                if (i != numberOfTokens - 1) {
                    pathCalldata = _skipTokenAndFee(pathCalldata);
                }
            }
        } else {
            numberOfTokens = 2;
            tokens = new address[](numberOfTokens);
            tokens[0] = _decodeFirstToken(pathCalldata);
            pathCalldata = _skipTokenAndFee(pathCalldata);
            tokens[1] = _decodeFirstToken(pathCalldata);
        }

        for (uint256 i; i < numberOfTokens; ++i) {
            if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, tokens[i])) {
                revert UniswapV3SwapFuseUnsupportedToken(tokens[i]);
            }
        }

        uint256 vaultBalance = IERC20(tokens[0]).balanceOf(address(this));

        uint256 inputAmount = data_.tokenInAmount <= vaultBalance ? data_.tokenInAmount : vaultBalance;

        if (inputAmount == 0) {
            return (data_.tokenInAmount, memoryPath, data_.minOutAmount);
        }

        IERC20(tokens[0]).safeTransfer(UNIVERSAL_ROUTER, inputAmount);

        bytes memory commands = abi.encodePacked(bytes1(uint8(V3_SWAP_EXACT_IN)));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            INDICATOR_OF_SENDER_FROM_UNIVERSAL_ROUTER,
            inputAmount,
            data_.minOutAmount,
            memoryPath,
            false
        );

        IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs);

        tokenInAmount = data_.tokenInAmount;
        path = memoryPath;
        minOutAmount = data_.minOutAmount;

        emit UniswapV3SwapFuseEnter(VERSION, tokenInAmount, path, minOutAmount);
    }

    /// @notice Returns true iff the path contains two or more pools
    /// @param path_ The encoded swap path
    /// @return True if path contains two or more pools, otherwise false
    function _hasMultiplePools(bytes memory path_) private pure returns (bool) {
        return path_.length >= MULTIPLE_V3_POOLS_MIN_LENGTH;
    }

    /// @notice Decodes the first token from a path
    /// @param path_ The encoded swap path
    /// @return tokenA The first token address
    function _decodeFirstToken(bytes memory path_) private pure returns (address tokenA) {
        tokenA = _toAddress(path_);
    }

    /// @notice Skips a token + fee element
    /// @param path_ The swap path
    /// @return The path with the first token and fee skipped
    function _skipTokenAndFee(bytes memory path_) private pure returns (bytes memory) {
        if (path_.length < NEXT_V3_POOL_OFFSET) revert SliceOutOfBounds();
        bytes memory result = new bytes(path_.length - NEXT_V3_POOL_OFFSET);
        for (uint256 i; i < result.length; ++i) {
            result[i] = path_[i + NEXT_V3_POOL_OFFSET];
        }
        return result;
    }

    /// @notice Returns the address starting at byte 0
    /// @dev length and overflow checks must be carried out before calling
    /// @param bytes_ The input bytes string to slice
    /// @return _address The address starting at byte 0
    function _toAddress(bytes memory bytes_) private pure returns (address _address) {
        if (bytes_.length < ADDR_SIZE) revert SliceOutOfBounds();
        assembly {
            _address := shr(96, mload(add(bytes_, 0x20)))
        }
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Reads inputs from transient storage: tokenInAmount (inputs[0]), minOutAmount (inputs[1]),
    ///      pathLength (inputs[2]), path chunks (inputs[3]...). Writes returned tokenInAmount, path length,
    ///      path chunks, and minOutAmount to transient storage outputs.
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        uint256 tokenInAmount_ = TypeConversionLib.toUint256(inputs[0]);
        uint256 minOutAmount_ = TypeConversionLib.toUint256(inputs[1]);
        uint256 pathLength = TypeConversionLib.toUint256(inputs[2]);

        bytes memory path_ = _buildBytesFromInputs(inputs, 3, pathLength);

        UniswapV3SwapFuseEnterData memory data_ = UniswapV3SwapFuseEnterData({
            tokenInAmount: tokenInAmount_,
            minOutAmount: minOutAmount_,
            path: path_
        });

        (uint256 returnedTokenInAmount, bytes memory returnedPath, uint256 returnedMinOutAmount) = enter(data_);

        _storeOutputs(returnedTokenInAmount, returnedPath, returnedMinOutAmount);
    }

    /// @notice Helper function to build bytes from transient storage inputs
    /// @param inputs_ Array of input values from transient storage
    /// @param startIndex_ Starting index where bytes data begins
    /// @param length_ Length of the bytes array to build
    /// @return The constructed bytes array
    function _buildBytesFromInputs(
        bytes32[] memory inputs_,
        uint256 startIndex_,
        uint256 length_
    ) private pure returns (bytes memory) {
        if (length_ == 0) {
            return "";
        }

        bytes memory result = new bytes(length_);
        uint256 chunksCount = (length_ + 31) / 32; // ceil(length_ / 32)

        for (uint256 i; i < chunksCount; ++i) {
            bytes32 chunk = inputs_[startIndex_ + i];
            uint256 chunkStart = i * 32;
            uint256 chunkEnd = chunkStart + 32;
            if (chunkEnd > length_) {
                chunkEnd = length_;
            }

            assembly {
                let dataPtr := add(add(result, 0x20), chunkStart)
                mstore(dataPtr, chunk)
            }
        }

        return result;
    }

    /// @notice Helper function to store outputs including bytes path to transient storage
    /// @param tokenInAmount_ The amount of input tokens used for the swap
    /// @param path_ The encoded path used for the swap
    /// @param minOutAmount_ The minimum amount of output tokens expected from the swap
    function _storeOutputs(uint256 tokenInAmount_, bytes memory path_, uint256 minOutAmount_) private {
        uint256 pathLength = path_.length;
        uint256 chunksCount = (pathLength + 31) / 32; // ceil(pathLength / 32)
        // Outputs: [tokenInAmount, pathLength, pathChunks..., minOutAmount]
        uint256 outputsLength = 2 + chunksCount + 1;
        bytes32[] memory outputs = new bytes32[](outputsLength);

        outputs[0] = TypeConversionLib.toBytes32(tokenInAmount_);
        outputs[1] = TypeConversionLib.toBytes32(pathLength);

        // Store path chunks
        for (uint256 i; i < chunksCount; ++i) {
            uint256 chunkStart = i * 32;
            bytes32 chunk;
            assembly {
                chunk := mload(add(add(path_, 0x20), chunkStart))
            }
            outputs[2 + i] = chunk;
        }

        outputs[outputsLength - 1] = TypeConversionLib.toBytes32(minOutAmount_);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
