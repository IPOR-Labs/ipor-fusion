// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPActionSwapPTV3} from "@pendle/core-v2/contracts/interfaces/IPActionSwapPTV3.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";
import {TokenInput, TokenOutput, ApproxParams, LimitOrderData, FillOrderParams} from "@pendle/core-v2/contracts/interfaces/IPAllActionTypeV3.sol";
import {SwapData, SwapType} from "@pendle/core-v2/contracts/router/swap-aggregator/IPSwapAggregator.sol";
import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import {IPPrincipalToken} from "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

/// @notice Data for entering (swap token for PT) to the Pendle protocol
/// @param market Market address to swap in
/// @param minPtOut Minimum PT tokens to receive
/// @param guessPtOut Approximation parameters for guessing PT output
/// @param input Token input parameters for the swap
struct PendleSwapPTFuseEnterData {
    address market;
    uint256 minPtOut;
    ApproxParams guessPtOut;
    TokenInput input;
}

/// @notice Data for exiting (swap PT for token) from the Pendle protocol
/// @param market Market address to swap in
/// @param exactPtIn Exact amount of PT to swap
/// @param output Token output parameters for the swap
struct PendleSwapPTFuseExitData {
    address market;
    uint256 exactPtIn;
    TokenOutput output;
}

/// @title PendleSwapPTFuse
/// @notice Fuse for swapping between tokens and Principal Tokens (PT) in the Pendle protocol
/// @dev Handles swapping underlying tokens for PT tokens and vice versa using Pendle markets
/// @dev Substrates in this fuse are the Pendle market addresses
contract PendleSwapPTFuse is IFuseCommon {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    /// @notice Emitted when entering a position by swapping tokens for PT
    /// @param version Address of this contract version
    /// @param market Address of the Pendle market
    /// @param netPtOut Amount of PT tokens received
    /// @param netSyFee Fee paid in standardized yield tokens
    /// @param netSyInterm Intermediate standardized yield token amount
    event PendleSwapPTFuseEnter(
        address version,
        address market,
        uint256 netPtOut,
        uint256 netSyFee,
        uint256 netSyInterm
    );

    /// @notice Emitted when exiting a position by swapping PT for tokens
    /// @param version Address of this contract version
    /// @param market Address of the Pendle market
    /// @param netTokenOut Amount of tokens received
    /// @param netSyFee Fee paid in standardized yield tokens
    /// @param netSyInterm Intermediate standardized yield token amount
    event PendleSwapPTFuseExit(
        address version,
        address market,
        uint256 netTokenOut,
        uint256 netSyFee,
        uint256 netSyInterm
    );

    /// @notice Error thrown when an invalid market ID is provided
    error PendleSwapPTFuseInvalidMarketId();
    /// @notice Error thrown when an invalid router address is provided
    error PendleSwapPTFuseInvalidRouter();
    /// @notice Error thrown when an invalid token input is provided
    error PendleSwapPTFuseInvalidTokenIn();
    /// @notice Error thrown when an invalid token output is provided
    error PendleSwapPTFuseInvalidTokenOut();

    /// @notice Version of this contract for tracking
    address public immutable VERSION;
    /// @notice Market ID this fuse is associated with
    uint256 public immutable MARKET_ID;
    /// @notice Pendle router contract used for swaps
    IPActionSwapPTV3 public immutable ROUTER;

    /// @notice Initializes the fuse with market ID and router address
    /// @param marketId_ Market ID for this fuse
    /// @param router_ Address of the Pendle router contract
    constructor(uint256 marketId_, address router_) {
        VERSION = address(this);
        if (marketId_ == 0) revert PendleSwapPTFuseInvalidMarketId();
        if (router_ == address(0)) revert PendleSwapPTFuseInvalidRouter();

        MARKET_ID = marketId_;
        ROUTER = IPActionSwapPTV3(router_);
    }

    /// @notice Swaps tokens for PT in a Pendle market
    /// @param data_ Struct containing swap parameters
    /// @return market Address of the Pendle market
    /// @return netPtOut Amount of PT tokens received
    /// @return netSyFee Fee paid in standardized yield tokens
    /// @return netSyInterm Intermediate standardized yield token amount
    function enter(
        PendleSwapPTFuseEnterData memory data_
    ) public returns (address market, uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm) {
        market = data_.market;
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, market)) {
            revert PendleSwapPTFuseInvalidMarketId();
        }
        (IStandardizedYield sy, , ) = IPMarket(market).readTokens();

        if (!sy.isValidTokenIn(data_.input.tokenIn)) revert PendleSwapPTFuseInvalidTokenIn();

        ERC20(data_.input.tokenIn).forceApprove(address(ROUTER), type(uint256).max);

        (netPtOut, netSyFee, netSyInterm) = ROUTER.swapExactTokenForPt(
            address(this),
            market,
            data_.minPtOut,
            data_.guessPtOut,
            data_.input,
            LimitOrderData({
                limitRouter: address(0),
                epsSkipMarket: 0,
                normalFills: new FillOrderParams[](0),
                flashFills: new FillOrderParams[](0),
                optData: bytes("")
            })
        );

        ERC20(data_.input.tokenIn).forceApprove(address(ROUTER), 0);

        emit PendleSwapPTFuseEnter(VERSION, market, netPtOut, netSyFee, netSyInterm);
    }

    /// @notice Swaps PT for tokens in a Pendle market
    /// @param data_ Struct containing swap parameters
    /// @return market Address of the Pendle market
    /// @return netTokenOut Amount of tokens received
    /// @return netSyFee Fee paid in standardized yield tokens
    /// @return netSyInterm Intermediate standardized yield token amount
    function exit(
        PendleSwapPTFuseExitData memory data_
    ) public returns (address market, uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm) {
        market = data_.market;
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, market)) {
            revert PendleSwapPTFuseInvalidMarketId();
        }

        (IStandardizedYield sy, IPPrincipalToken pt, ) = IPMarket(market).readTokens();

        if (!sy.isValidTokenOut(data_.output.tokenOut)) revert PendleSwapPTFuseInvalidTokenOut();

        ERC20(address(pt)).forceApprove(address(ROUTER), type(uint256).max);

        (netTokenOut, netSyFee, netSyInterm) = ROUTER.swapExactPtForToken(
            address(this),
            market,
            data_.exactPtIn,
            data_.output,
            LimitOrderData({
                limitRouter: address(0),
                epsSkipMarket: 0,
                normalFills: new FillOrderParams[](0),
                flashFills: new FillOrderParams[](0),
                optData: bytes("")
            })
        );

        ERC20(address(pt)).forceApprove(address(ROUTER), 0);

        emit PendleSwapPTFuseExit(VERSION, market, netTokenOut, netSyFee, netSyInterm);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Inputs order: market, minPtOut, guessMin, guessMax, guessOffchain, maxIteration, eps,
    ///      tokenIn, netTokenIn, tokenMintSy, pendleSwap, swapType, extRouter, extCalldataLength, extCalldataFirst32Bytes, needScale
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        // Construct data struct inline to reduce stack depth
        PendleSwapPTFuseEnterData memory data_ = PendleSwapPTFuseEnterData({
            market: TypeConversionLib.toAddress(inputs[0]),
            minPtOut: TypeConversionLib.toUint256(inputs[1]),
            guessPtOut: ApproxParams({
                guessMin: TypeConversionLib.toUint256(inputs[2]),
                guessMax: TypeConversionLib.toUint256(inputs[3]),
                guessOffchain: TypeConversionLib.toUint256(inputs[4]),
                maxIteration: TypeConversionLib.toUint256(inputs[5]),
                eps: TypeConversionLib.toUint256(inputs[6])
            }),
            input: TokenInput({
                tokenIn: TypeConversionLib.toAddress(inputs[7]),
                netTokenIn: TypeConversionLib.toUint256(inputs[8]),
                tokenMintSy: TypeConversionLib.toAddress(inputs[9]),
                pendleSwap: TypeConversionLib.toAddress(inputs[10]),
                swapData: SwapData({
                    swapType: SwapType(uint8(TypeConversionLib.toUint256(inputs[11]))),
                    extRouter: TypeConversionLib.toAddress(inputs[12]),
                    extCalldata: _buildExtCalldata(inputs, 13),
                    needScale: TypeConversionLib.toUint256(inputs[15]) != 0
                })
            })
        });

        (address returnedMarket, uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm) = enter(data_);

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(returnedMarket);
        outputs[1] = TypeConversionLib.toBytes32(netPtOut);
        outputs[2] = TypeConversionLib.toBytes32(netSyFee);
        outputs[3] = TypeConversionLib.toBytes32(netSyInterm);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Helper function to build extCalldata from transient storage inputs
    /// @param inputs_ Array of input values from transient storage
    /// @param lengthIndex_ Index where extCalldata length is stored
    /// @return extCalldata The constructed bytes array
    function _buildExtCalldata(
        bytes32[] memory inputs_,
        uint256 lengthIndex_
    ) private pure returns (bytes memory extCalldata) {
        uint256 extCalldataLength = TypeConversionLib.toUint256(inputs_[lengthIndex_]);
        if (extCalldataLength == 0) {
            return extCalldata;
        }
        // For simplicity, handle up to 32 bytes
        if (extCalldataLength <= 32) {
            bytes32 firstBytes = inputs_[lengthIndex_ + 1];
            extCalldata = new bytes(extCalldataLength);
            assembly {
                mstore(add(extCalldata, 32), firstBytes)
                mstore(extCalldata, extCalldataLength)
            }
        }
    }

    /// @notice Exits the Fuse using transient storage for parameters
    /// @dev Inputs order: market, exactPtIn, tokenOut, minTokenOut, tokenRedeemSy, pendleSwap,
    ///      swapType, extRouter, extCalldataLength, extCalldataFirst32Bytes, needScale
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        // Construct data struct inline to reduce stack depth
        PendleSwapPTFuseExitData memory data_ = PendleSwapPTFuseExitData({
            market: TypeConversionLib.toAddress(inputs[0]),
            exactPtIn: TypeConversionLib.toUint256(inputs[1]),
            output: TokenOutput({
                tokenOut: TypeConversionLib.toAddress(inputs[2]),
                minTokenOut: TypeConversionLib.toUint256(inputs[3]),
                tokenRedeemSy: TypeConversionLib.toAddress(inputs[4]),
                pendleSwap: TypeConversionLib.toAddress(inputs[5]),
                swapData: SwapData({
                    swapType: SwapType(uint8(TypeConversionLib.toUint256(inputs[6]))),
                    extRouter: TypeConversionLib.toAddress(inputs[7]),
                    extCalldata: _buildExtCalldata(inputs, 8),
                    needScale: TypeConversionLib.toUint256(inputs[10]) != 0
                })
            })
        });

        (address returnedMarket, uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm) = exit(data_);

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(returnedMarket);
        outputs[1] = TypeConversionLib.toBytes32(netTokenOut);
        outputs[2] = TypeConversionLib.toBytes32(netSyFee);
        outputs[3] = TypeConversionLib.toBytes32(netSyInterm);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
