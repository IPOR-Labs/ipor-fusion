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
import {IPYieldToken} from "@pendle/core-v2/contracts/interfaces/IPYieldToken.sol";
import {FillOrderParams} from "@pendle/core-v2/contracts/interfaces/IPAllActionTypeV3.sol";

/// @notice Structure for entering (swap token for PT) to the Pendle protocol
struct PendleSwapPTFuseEnterData {
    // market address
    address market;
    // minimum PT tokens to receive
    uint256 minPtOut;
    // approximation parameters for guessing PT output
    ApproxParams guessPtOut;
    // token input parameters
    TokenInput input;
}

/// @notice Structure for exiting (swap PT for token) from the Pendle protocol
struct PendleSwapPTFuseExitData {
    // market address
    address market;
    // exact amount of PT to swap
    uint256 exactPtIn;
    // token output parameters
    TokenOutput output;
}

/// @title Fuse Pendle Swap PT protocol responsible for swapping tokens for PT and PT for tokens in Pendle markets
contract PendelSwapPTFuse is IFuseCommon {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    event PendleSwapPTFuseEnter(
        address version,
        address market,
        uint256 netPtOut,
        uint256 netSyFee,
        uint256 netSyInterm
    );

    event PendleSwapPTFuseExit(
        address version,
        address market,
        uint256 netTokenOut,
        uint256 netSyFee,
        uint256 netSyInterm
    );

    error PendleSwapPTFuseInvalidMarketId();
    error PendleSwapPTFuseInvalidRouter();
    error PendleSwapPTFuseInvalidTokenIn();
    error PendleSwapPTFuseInvalidTokenOut();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IPActionSwapPTV3 public immutable ROUTER;

    constructor(uint256 marketId_, address router_) {
        VERSION = address(this);
        if (marketId_ == 0) revert PendleSwapPTFuseInvalidMarketId();
        if (router_ == address(0)) revert PendleSwapPTFuseInvalidRouter();

        MARKET_ID = marketId_;
        ROUTER = IPActionSwapPTV3(router_);
    }

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

    function exit(PendleSwapPTFuseExitData calldata data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.market)) {
            revert PendleSwapPTFuseInvalidMarketId();
        }

        (IStandardizedYield sy, , ) = IPMarket(data_.market).readTokens();

        if (!sy.isValidTokenOut(data_.output.tokenOut)) revert PendleSwapPTFuseInvalidTokenOut();

        ERC20(data_.output.tokenOut).forceApprove(address(ROUTER), type(uint256).max);

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

        ERC20(data_.output.tokenOut).forceApprove(address(ROUTER), 0);

        emit PendleSwapPTFuseExit(VERSION, data_.market, netTokenOut, netSyFee, netSyInterm);
    }
}
