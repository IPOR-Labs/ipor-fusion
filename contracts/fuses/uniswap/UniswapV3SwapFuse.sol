// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
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
     * Emits an `UniswapV2SwapFuseEnter` event indicating the details of the swap.
     */
    function enter(UniswapV3SwapFuseEnterData calldata data_) external {
        address[] memory tokens;
        bytes calldata path = data_.path;
        bytes memory memoryPath = data_.path;
        uint256 numberOfTokens;

        if (_hasMultiplePools(path)) {
            numberOfTokens = ((path.length.toInt256() - ADDR_SIZE.toInt256()).toUint256() / NEXT_V3_POOL_OFFSET) + 1;
            tokens = new address[](numberOfTokens);
            for (uint256 i; i < numberOfTokens; ++i) {
                tokens[i] = _decodeFirstToken(path);
                if (i != numberOfTokens - 1) {
                    path = _skipTokenAndFee(path);
                }
            }
        } else {
            numberOfTokens = 2;
            tokens = new address[](numberOfTokens);
            tokens[0] = _decodeFirstToken(path);
            path = _skipTokenAndFee(path);
            tokens[1] = _decodeFirstToken(path);
        }

        for (uint256 i; i < numberOfTokens; ++i) {
            if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, tokens[i])) {
                revert UniswapV3SwapFuseUnsupportedToken(tokens[i]);
            }
        }

        uint256 vaultBalance = IERC20(tokens[0]).balanceOf(address(this));

        uint256 inputAmount = data_.tokenInAmount <= vaultBalance ? data_.tokenInAmount : vaultBalance;

        if (inputAmount == 0) {
            return;
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

        emit UniswapV3SwapFuseEnter(VERSION, data_.tokenInAmount, memoryPath, data_.minOutAmount);
    }

    /// @notice Returns true iff the path contains two or more pools
    /// @param path_ The encoded swap path
    /// @return True if path contains two or more pools, otherwise false
    function _hasMultiplePools(bytes calldata path_) private pure returns (bool) {
        return path_.length >= MULTIPLE_V3_POOLS_MIN_LENGTH;
    }

    function _decodeFirstToken(bytes calldata path_) private pure returns (address tokenA) {
        tokenA = _toAddress(path_);
    }

    /// @notice Skips a token + fee element
    /// @param path_ The swap path
    function _skipTokenAndFee(bytes calldata path_) private pure returns (bytes calldata) {
        return path_[NEXT_V3_POOL_OFFSET:];
    }

    /// @notice Returns the address starting at byte 0
    /// @dev length and overflow checks must be carried out before calling
    /// @param bytes_ The input bytes string to slice
    /// @return _address The address starting at byte 0
    function _toAddress(bytes calldata bytes_) private pure returns (address _address) {
        if (bytes_.length < ADDR_SIZE) revert SliceOutOfBounds();
        assembly {
            _address := shr(96, calldataload(bytes_.offset))
        }
    }
}
