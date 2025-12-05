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

/// @notice Data for entering (Early redeem PT/YT for tokens) to the Napier V2 protocol
/// @param principalToken Principal Token address to redeem from
/// @param tokenOut Asset to redeem PT/YT for
/// @param principals Amount of the PTs/YTs to redeem
struct NapierCombineFuseEnterData {
    IPrincipalToken principalToken;
    address tokenOut;
    uint256 principals;
}

/// @title NapierCombineFuse
/// @notice Fuse for supplying assets into Napier V2 Principal Tokens via the universal router
/// @dev Substrates in this fuse are the Napier V2 Principal Tokens
contract NapierCombineFuse is NapierUniversalRouterFuse {
    using SafeERC20 for ERC20;

    /// @notice Emitted when supplying assets into Napier V2 PTs
    /// @param version Address of this contract version
    /// @param principalToken Address of the Napier V2 Principal Token
    /// @param tokenOut Asset supplied into the router
    /// @param amountOut Amount of tokens received
    event NapierCombineFuseEnter(address version, address principalToken, address tokenOut, uint256 amountOut);

    constructor(uint256 marketId_, address router_) {
        VERSION = address(this);
        if (marketId_ == 0) revert NapierFuseIInvalidMarketId();
        if (router_ == address(0)) revert NapierFuseIInvalidRouter();

        MARKET_ID = marketId_;
        ROUTER = IUniversalRouter(router_);
    }

    /// @notice Early redeem PT and YT into the tokenOut (before/after the maturity)
    function enter(NapierCombineFuseEnterData calldata data_) external {
        IPrincipalToken pt = data_.principalToken;

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(pt))) {
            revert NapierFuseIInvalidToken();
        }

        address yt = pt.i_yt();
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, yt)) {
            revert NapierFuseIInvalidToken();
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.tokenOut)) {
            revert NapierFuseIInvalidToken();
        }

        if (data_.principals == 0) {
            return;
        }

        address underlying = pt.underlying();
        address asset = pt.i_asset();

        bytes memory commands;
        bytes[] memory inputs;
        if (data_.tokenOut == underlying) {
            // Combine PT and YT for underlying token
            commands = abi.encodePacked(bytes1(uint8(Commands.PT_COMBINE)));
            inputs = new bytes[](1);
            inputs[0] = abi.encode(pt, ActionConstants.CONTRACT_BALANCE, address(this));
        } else if (data_.tokenOut == asset) {
            // Combine PT and YT for tokenOut through VaultConnector
            commands = abi.encodePacked(
                bytes1(uint8(Commands.PT_COMBINE)),
                bytes1(uint8(Commands.VAULT_CONNECTOR_REDEEM))
            );

            inputs = new bytes[](2);
            inputs[0] = abi.encode(pt, ActionConstants.CONTRACT_BALANCE, ActionConstants.ADDRESS_THIS);
            inputs[1] = abi.encode(underlying, asset, data_.tokenOut, ActionConstants.CONTRACT_BALANCE, address(this));
        } else {
            revert NapierFuseIInvalidToken();
        }

        uint256 balanceBefore = ERC20(data_.tokenOut).balanceOf(address(this));

        // Pre-transfer PT and YT to the router
        ERC20(address(pt)).safeTransfer(address(ROUTER), data_.principals);
        ERC20(yt).safeTransfer(address(ROUTER), data_.principals);

        ROUTER.execute(commands, inputs);

        uint256 amountOut = ERC20(data_.tokenOut).balanceOf(address(this)) - balanceBefore;

        emit NapierCombineFuseEnter(VERSION, address(data_.principalToken), data_.tokenOut, amountOut);
    }
}
