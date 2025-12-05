// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

import {IPrincipalToken} from "./ext/IPrincipalToken.sol";
import {IUniversalRouter} from "./ext/IUniversalRouter.sol";
import {Commands} from "./utils/Commands.sol";
import {ActionConstants} from "./utils/ActionsConstants.sol";

import {NapierUniversalRouterFuse} from "./NapierUniversalRouterFuse.sol";

/// @notice Data for entering (redeem PT for token) to the Napier V2 protocol
/// @param principalToken Principal Token address to redeem from
/// @param principals Exact amount of PT to redeem
/// @param tokenOut Token output address for the redemption
struct NapierRedeemFuseEnterData {
    IPrincipalToken principalToken;
    address tokenOut;
    uint256 principals;
}

/// @title NapierRedeemFuse
/// @notice Fuse for redeeming PT for tokens in the Napier V2 protocol
/// @dev Handles redeeming PT for tokens using Napier V2's redeem command
/// @dev Substrates in this fuse are the Napier V2 Principal Token
contract NapierRedeemFuse is NapierUniversalRouterFuse {
    using SafeERC20 for ERC20;
    using SafeERC20 for IPrincipalToken;

    /// @notice Emitted when entering a position by redeeming PT/YT for tokens
    /// @param version Address of this contract version
    /// @param principalToken Address of the Napier V2 Principal Token
    /// @param amountOut Amount of tokens received
    event NapierRedeemFuseEnter(address version, address principalToken, address tokenOut, uint256 amountOut);

    constructor(uint256 marketId_, address router_) {
        VERSION = address(this);
        if (marketId_ == 0) revert NapierFuseIInvalidMarketId();
        if (router_ == address(0)) revert NapierFuseIInvalidRouter();

        MARKET_ID = marketId_;
        ROUTER = IUniversalRouter(router_);
    }

    /// @notice Redeems PTs for tokens after the maturity
    function enter(NapierRedeemFuseEnterData calldata data_) external {
        IPrincipalToken pt = data_.principalToken;

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(pt))) {
            revert NapierFuseIInvalidToken();
        }

        if (data_.principals == 0) {
            return;
        }

        address underlyingToken = pt.underlying();
        address asset = pt.i_asset();

        bytes memory commands;
        bytes[] memory inputs;

        if (data_.tokenOut == underlyingToken) {
            // Redeem PT for underlying token
            commands = abi.encodePacked(bytes1(uint8(Commands.PT_REDEEM)));
            inputs = new bytes[](1);
            inputs[0] = abi.encode(pt, ActionConstants.CONTRACT_BALANCE, address(this));
        } else if (data_.tokenOut == asset) {
            // Redeem PT for tokenOut through VaultConnector
            commands = abi.encodePacked(
                bytes1(uint8(Commands.PT_REDEEM)),
                bytes1(uint8(Commands.VAULT_CONNECTOR_REDEEM))
            );
            inputs = new bytes[](2);
            inputs[0] = abi.encode(pt, ActionConstants.CONTRACT_BALANCE, ActionConstants.ADDRESS_THIS);
            inputs[1] = abi.encode(
                underlyingToken,
                asset,
                data_.tokenOut,
                ActionConstants.CONTRACT_BALANCE,
                address(this)
            );
        } else {
            revert NapierFuseIInvalidToken();
        }

        uint256 balanceBefore = ERC20(data_.tokenOut).balanceOf(address(this));

        // Pre-transfer PT to the router
        ERC20(address(pt)).safeTransfer(address(ROUTER), data_.principals);
        ROUTER.execute(commands, inputs);

        uint256 amountOut = ERC20(data_.tokenOut).balanceOf(address(this)) - balanceBefore;

        emit NapierRedeemFuseEnter(VERSION, address(data_.principalToken), data_.tokenOut, amountOut);
    }
}
