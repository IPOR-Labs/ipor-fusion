// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IPYieldToken} from "@pendle/core-v2/contracts/interfaces/IPYieldToken.sol";
import {IPAllActionV3} from "@pendle/core-v2/contracts/interfaces/IPAllActionV3.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";
import {TokenInput, TokenOutput} from "@pendle/core-v2/contracts/interfaces/IPAllActionTypeV3.sol";
import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import {IPPrincipalToken} from "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";

/// @notice Data for entering (redeem PT and YT for token) to the Pendle protocol
/// @param market Market address to redeem from
/// @param exactPyIn Exact amount of PT/YT pair to redeem
/// @param output Token output parameters for the redemption
struct PendleRedeemPTFuseEnterData {
    address market;
    uint256 exactPyIn;
    TokenOutput output;
}

/// @title PendleRedeemPTFuse
/// @notice Fuse for redeeming PT/YT pairs for underlying tokens in the Pendle protocol
/// @dev Handles redeeming PT/YT pairs for underlying tokens using Pendle's redeemPyToToken
/// @dev Substrates in this fuse are the Pendle market addresses
contract PendleRedeemPTFuse is IFuseCommon {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    /// @notice Emitted when entering a position by redeeming PT/YT for tokens
    /// @param version Address of this contract version
    /// @param market Address of the Pendle market
    /// @param netTokenOut Amount of tokens received
    event PendleRedeemPTFuseEnter(address version, address market, uint256 netTokenOut);

    /// @notice Error thrown when an invalid market ID is provided
    error PendleRedeemPTFuseInvalidMarketId();
    /// @notice Error thrown when an invalid router address is provided
    error PendleRedeemPTFuseInvalidRouter();
    /// @notice Error thrown when an invalid token output is provided
    error PendleRedeemPTFuseInvalidTokenOut();
    /// @notice Error thrown when PT is not expired
    error PendleRedeemPTFusePTNotExpired();

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
        if (marketId_ == 0) revert PendleRedeemPTFuseInvalidMarketId();
        if (router_ == address(0)) revert PendleRedeemPTFuseInvalidRouter();

        MARKET_ID = marketId_;
        ROUTER = IPAllActionV3(router_);
    }

    /// @notice Redeems PT pairs for underlying tokens after maturity
    /// @param data_ Struct containing redemption parameters
    function enter(PendleRedeemPTFuseEnterData calldata data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.market)) {
            revert PendleRedeemPTFuseInvalidMarketId();
        }

        (IStandardizedYield sy, IPPrincipalToken pt, IPYieldToken yt) = IPMarket(data_.market).readTokens();

        if (!sy.isValidTokenOut(data_.output.tokenOut)) revert PendleRedeemPTFuseInvalidTokenOut();
        if (!pt.isExpired()) revert PendleRedeemPTFusePTNotExpired();

        ERC20(address(pt)).forceApprove(address(ROUTER), data_.exactPyIn);

        (uint256 netTokenOut, ) = ROUTER.redeemPyToToken(address(this), address(yt), data_.exactPyIn, data_.output);

        ERC20(address(pt)).forceApprove(address(ROUTER), 0);

        emit PendleRedeemPTFuseEnter(VERSION, data_.market, netTokenOut);
    }
}
