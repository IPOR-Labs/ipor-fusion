// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IPAllActionV3} from "@pendle/core-v2/contracts/interfaces/IPAllActionV3.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";

import {TokenInput, TokenOutput, ApproxParams, LimitOrderData} from "@pendle/core-v2/contracts/interfaces/IPAllActionTypeV3.sol";
import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import {IPPrincipalToken} from "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";
import {IPYieldToken} from "@pendle/core-v2/contracts/interfaces/IPYieldToken.sol";
import {FillOrderParams} from "@pendle/core-v2/contracts/interfaces/IPAllActionTypeV3.sol";

/// @notice Structure for entering (add liquidity) to the Pendle protocol
struct PendleLiquidityFuseEnterData {
    // market address
    address market;
    // minimum LP tokens to receive
    uint256 minLpOut;
    // token input parameters
    TokenInput input;
    // approximation parameters for guessing PT received from SY
    ApproxParams guessPtReceivedFromSy;
}

/// @notice Structure for exiting (remove liquidity) from the Pendle protocol
struct PendleLiquidityFuseExitData {
    // market address
    address market;
    // amount of LP tokens to remove
    uint256 netLpToRemove;
    // token output parameters
    TokenOutput output;
}

/// @title Fuse Pendle Liquidity protocol responsible for adding and removing liquidity from Pendle markets
contract PendleLiquidityFuse is IFuseCommon {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    event PendleLiquidityFuseEnter(
        address version,
        address market,
        uint256 netLpOut,
        uint256 netSyFee,
        uint256 netSyInterm
    );

    event PendleLiquidityFuseExit(
        address version,
        address market,
        uint256 netTokenOut,
        uint256 netSyFee,
        uint256 netSyInterm
    );

    error PendleLiquidityFuseInvalidMarketId();
    error PendleLiquidityFuseInvalidRouter();
    error PendleLiquidityFuseInvalidTokenIn();
    error PendleLiquidityFuseInvalidTokenOut();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IPAllActionV3 public immutable ROUTER;

    constructor(uint256 marketId_, address router_) {
        VERSION = address(this);
        if (marketId_ == 0) revert PendleLiquidityFuseInvalidMarketId();
        if (router_ == address(0)) revert PendleLiquidityFuseInvalidRouter();

        MARKET_ID = marketId_;
        ROUTER = IPAllActionV3(router_);
    }

    function enter(PendleLiquidityFuseEnterData memory data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.market)) {
            revert PendleLiquidityFuseInvalidMarketId();
        }
        (IStandardizedYield sy, , ) = IPMarket(data_.market).readTokens();

        if (!sy.isValidTokenIn(data_.input.tokenIn)) revert PendleLiquidityFuseInvalidTokenIn();

        ERC20(data_.input.tokenIn).forceApprove(address(ROUTER), type(uint256).max);

        (uint256 netLpOut, uint256 netSyFee, uint256 netSyInterm) = ROUTER.addLiquiditySingleToken(
            address(this),
            data_.market,
            data_.minLpOut,
            data_.guessPtReceivedFromSy,
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

        emit PendleLiquidityFuseEnter(VERSION, data_.market, netLpOut, netSyFee, netSyInterm);
    }

    function exit(PendleLiquidityFuseExitData calldata data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.market)) {
            revert PendleLiquidityFuseInvalidMarketId();
        }

        (IStandardizedYield sy, , ) = IPMarket(data_.market).readTokens();

        if (!sy.isValidTokenOut(data_.output.tokenOut)) revert PendleLiquidityFuseInvalidTokenOut();

        (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm) = ROUTER.removeLiquiditySingleToken(
            address(this),
            data_.market,
            data_.netLpToRemove,
            data_.output,
            LimitOrderData({
                limitRouter: address(0),
                epsSkipMarket: 0,
                normalFills: new FillOrderParams[](0),
                flashFills: new FillOrderParams[](0),
                optData: bytes("")
            })
        );

        emit PendleLiquidityFuseExit(VERSION, data_.market, netTokenOut, netSyFee, netSyInterm);
    }
}
