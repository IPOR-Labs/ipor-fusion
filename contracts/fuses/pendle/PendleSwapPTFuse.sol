// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IPActionSwapPTV3} from "@pendle/core-v2/contracts/interfaces/IPActionSwapPTV3.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";

import {TokenInput, TokenOutput, ApproxParams, LimitOrderData} from "@pendle/core-v2/contracts/interfaces/IPAllActionTypeV3.sol";
import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import {IPPrincipalToken} from "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";
import {FillOrderParams} from "@pendle/core-v2/contracts/interfaces/IPAllActionTypeV3.sol";

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
    function enter(PendleSwapPTFuseEnterData memory data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.market)) {
            revert PendleSwapPTFuseInvalidMarketId();
        }
        (IStandardizedYield sy, , ) = IPMarket(data_.market).readTokens();

        if (!sy.isValidTokenIn(data_.input.tokenIn)) revert PendleSwapPTFuseInvalidTokenIn();

        ERC20(data_.input.tokenIn).forceApprove(address(ROUTER), type(uint256).max);

        (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm) = ROUTER.swapExactTokenForPt(
            address(this),
            data_.market,
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

        emit PendleSwapPTFuseEnter(VERSION, data_.market, netPtOut, netSyFee, netSyInterm);
    }

    /// @notice Swaps PT for tokens in a Pendle market
    /// @param data_ Struct containing swap parameters
    function exit(PendleSwapPTFuseExitData calldata data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.market)) {
            revert PendleSwapPTFuseInvalidMarketId();
        }

        (IStandardizedYield sy, IPPrincipalToken pt, ) = IPMarket(data_.market).readTokens();

        if (!sy.isValidTokenOut(data_.output.tokenOut)) revert PendleSwapPTFuseInvalidTokenOut();

        ERC20(address(pt)).forceApprove(address(ROUTER), type(uint256).max);

        (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm) = ROUTER.swapExactPtForToken(
            address(this),
            data_.market,
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

        emit PendleSwapPTFuseExit(VERSION, data_.market, netTokenOut, netSyFee, netSyInterm);
    }
}
