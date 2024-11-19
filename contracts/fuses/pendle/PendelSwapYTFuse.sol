// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IPActionSwapYTV3} from "@pendle/core-v2/contracts/interfaces/IPActionSwapYTV3.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";

import {TokenInput, TokenOutput, ApproxParams, LimitOrderData} from "@pendle/core-v2/contracts/interfaces/IPAllActionTypeV3.sol";
import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import {IPPrincipalToken} from "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";
import {IPYieldToken} from "@pendle/core-v2/contracts/interfaces/IPYieldToken.sol";
import {FillOrderParams} from "@pendle/core-v2/contracts/interfaces/IPAllActionTypeV3.sol";

/// @notice Structure for entering (swap token for YT) to the Pendle protocol
struct PendleSwapYTFuseEnterData {
    // market address
    address market;
    // minimum YT tokens to receive
    uint256 minYtOut;
    // approximation parameters for guessing YT output
    ApproxParams guessYtOut;
    // token input parameters
    TokenInput input;
}

/// @notice Structure for exiting (swap YT for token) from the Pendle protocol
struct PendleSwapYTFuseExitData {
    // market address
    address market;
    // exact amount of YT to swap
    uint256 exactYtIn;
    // token output parameters
    TokenOutput output;
}

/// @title Fuse Pendle Swap YT protocol responsible for swapping tokens for YT and YT for tokens in Pendle markets
contract PendelSwapYTFuse is IFuseCommon {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    event PendleSwapYTFuseEnter(
        address version,
        address market,
        uint256 netYtOut,
        uint256 netSyFee,
        uint256 netSyInterm
    );

    event PendleSwapYTFuseExit(
        address version,
        address market,
        uint256 netTokenOut,
        uint256 netSyFee,
        uint256 netSyInterm
    );

    error PendleSwapYTFuseInvalidMarketId();
    error PendleSwapYTFuseInvalidRouter();
    error PendleSwapYTFuseInvalidTokenIn();
    error PendleSwapYTFuseInvalidTokenOut();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IPActionSwapYTV3 public immutable ROUTER;

    constructor(uint256 marketId_, address router_) {
        VERSION = address(this);
        if (marketId_ == 0) revert PendleSwapYTFuseInvalidMarketId();
        if (router_ == address(0)) revert PendleSwapYTFuseInvalidRouter();

        MARKET_ID = marketId_;
        ROUTER = IPActionSwapYTV3(router_);
    }

    function enter(PendleSwapYTFuseEnterData memory data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.market)) {
            revert PendleSwapYTFuseInvalidMarketId();
        }
        (IStandardizedYield sy, , ) = IPMarket(data_.market).readTokens();

        if (!sy.isValidTokenIn(data_.input.tokenIn)) revert PendleSwapYTFuseInvalidTokenIn();

        ERC20(data_.input.tokenIn).forceApprove(address(ROUTER), type(uint256).max);

        (uint256 netYtOut, uint256 netSyFee, uint256 netSyInterm) = ROUTER.swapExactTokenForYt(
            address(this),
            data_.market,
            data_.minYtOut,
            data_.guessYtOut,
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

        emit PendleSwapYTFuseEnter(VERSION, data_.market, netYtOut, netSyFee, netSyInterm);
    }

    function exit(PendleSwapYTFuseExitData calldata data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.market)) {
            revert PendleSwapYTFuseInvalidMarketId();
        }

        (IStandardizedYield sy, , ) = IPMarket(data_.market).readTokens();

        if (!sy.isValidTokenOut(data_.output.tokenOut)) revert PendleSwapYTFuseInvalidTokenOut();

        ERC20(data_.output.tokenOut).forceApprove(address(ROUTER), type(uint256).max);

        (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm) = ROUTER.swapExactYtForToken(
            address(this),
            data_.market,
            data_.exactYtIn,
            data_.output,
            LimitOrderData({
                limitRouter: address(0),
                epsSkipMarket: 0,
                normalFills: new FillOrderParams[](0),
                flashFills: new FillOrderParams[](0),
                optData: bytes("")
            })
        );

        ERC20(data_.output.tokenOut).forceApprove(address(ROUTER), 0);

        emit PendleSwapYTFuseExit(VERSION, data_.market, netTokenOut, netSyFee, netSyInterm);
    }
}
