// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPAllActionV3} from "@pendle/core-v2/contracts/interfaces/IPAllActionV3.sol";
import {TokenOutput} from "@pendle/core-v2/contracts/interfaces/IPAllActionTypeV3.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";
import {IPPrincipalToken} from "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";
import {SwapData, SwapType} from "@pendle/core-v2/contracts/router/swap-aggregator/IPSwapAggregator.sol";
import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import {IPYieldToken} from "@pendle/core-v2/contracts/interfaces/IPYieldToken.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

/// @notice Data for entering (redeem PT and YT for token) to the Pendle protocol
/// @param market Market address to redeem from
/// @param netPyIn Exact amount of PT/YT pair to redeem
/// @param output Token output parameters for the redemption
struct PendleRedeemPTAfterMaturityFuseEnterData {
    address market;
    uint256 netPyIn;
    TokenOutput output;
}

/// @title PendleRedeemPTAfterMaturityFuse
/// @notice Fuse for redeeming PT/YT pairs for underlying tokens in the Pendle protocol
/// @dev Handles redeeming PT/YT pairs for underlying tokens using Pendle's redeemPyToToken
/// @dev Substrates in this fuse are the Pendle market addresses
contract PendleRedeemPTAfterMaturityFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    /// @notice Emitted when entering a position by redeeming PT/YT for tokens
    /// @param version Address of this contract version
    /// @param market Address of the Pendle market
    /// @param netTokenOut Amount of tokens received
    event PendleRedeemPTAfterMaturityFuseEnter(address version, address market, uint256 netTokenOut);

    /// @notice Error thrown when an invalid market ID is provided
    error PendleRedeemPTAfterMaturityFuseInvalidMarketId();
    /// @notice Error thrown when an invalid router address is provided
    error PendleRedeemPTAfterMaturityFuseInvalidRouter();
    /// @notice Error thrown when an invalid token output is provided
    error PendleRedeemPTAfterMaturityFuseInvalidTokenOut();
    /// @notice Error thrown when PT is not expired
    error PendleRedeemPTAfterMaturityFusePTNotExpired();

    /// @notice Version of this contract for tracking
    address public immutable VERSION;
    /// @notice Market ID this fuse is associated with
    uint256 public immutable MARKET_ID;
    /// @notice Pendle router contract used for redemptions
    IPAllActionV3 public immutable ROUTER;

    /// @notice Initializes the fuse with market ID and router address
    /// @param marketId_ Market ID for this fuse
    /// @param router_ Address of the Pendle router contract
    constructor(uint256 marketId_, address router_) {
        VERSION = address(this);
        if (marketId_ == 0) revert PendleRedeemPTAfterMaturityFuseInvalidMarketId();
        if (router_ == address(0)) revert PendleRedeemPTAfterMaturityFuseInvalidRouter();

        MARKET_ID = marketId_;
        ROUTER = IPAllActionV3(router_);
    }

    /// @notice Redeems PT pairs for underlying tokens after maturity
    /// @param data_ Struct containing redemption parameters
    /// @return market Address of the Pendle market
    /// @return netTokenOut Amount of tokens received
    function enter(
        PendleRedeemPTAfterMaturityFuseEnterData memory data_
    ) public returns (address market, uint256 netTokenOut) {
        market = data_.market;
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, market)) {
            revert PendleRedeemPTAfterMaturityFuseInvalidMarketId();
        }

        (IStandardizedYield sy, IPPrincipalToken pt, IPYieldToken yt) = IPMarket(market).readTokens();

        if (!sy.isValidTokenOut(data_.output.tokenOut)) revert PendleRedeemPTAfterMaturityFuseInvalidTokenOut();
        if (!pt.isExpired()) revert PendleRedeemPTAfterMaturityFusePTNotExpired();

        ERC20(address(pt)).forceApprove(address(ROUTER), data_.netPyIn);

        (netTokenOut, ) = ROUTER.redeemPyToToken(address(this), address(yt), data_.netPyIn, data_.output);

        ERC20(address(pt)).forceApprove(address(ROUTER), 0);

        emit PendleRedeemPTAfterMaturityFuseEnter(VERSION, market, netTokenOut);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Inputs order: market, netPyIn, tokenOut, minTokenOut, tokenRedeemSy, pendleSwap,
    ///      swapType, extRouter, extCalldataLength, extCalldataFirst32Bytes, needScale
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        // Construct data struct inline to reduce stack depth
        PendleRedeemPTAfterMaturityFuseEnterData memory data_ = PendleRedeemPTAfterMaturityFuseEnterData({
            market: TypeConversionLib.toAddress(inputs[0]),
            netPyIn: TypeConversionLib.toUint256(inputs[1]),
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

        (address returnedMarket, uint256 netTokenOut) = enter(data_);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedMarket);
        outputs[1] = TypeConversionLib.toBytes32(netTokenOut);
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
}
