// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
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
     */
    function enter(UniswapV2SwapFuseEnterData memory data_) public {
        uint256 pathLength = data_.path.length;
        if (data_.tokenInAmount == 0 || pathLength < 2) {
            return;
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
            return;
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

        emit UniswapV2SwapFuseEnter(VERSION, data_.tokenInAmount, data_.path, data_.minOutAmount);
    }
}
