// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

import {IPrincipalToken} from "./ext/IPrincipalToken.sol";
import {IUniversalRouter} from "./ext/IUniversalRouter.sol";
import {Commands} from "./utils/Commands.sol";
import {ActionConstants} from "./utils/ActionsConstants.sol";

import {NapierUniversalRouterFuse} from "./NapierUniversalRouterFuse.sol";

/// @notice Data for entering (Issue PT/YT with tokens) to the Napier V2 protocol
/// @param principalToken Principal Token address to supply to
/// @param tokenIn Asset to issue PT/YT with
/// @param amountIn Amount of the asset to issue PT/YT with
/// @param minPrincipalsAmount Minimum amount of PTs/YTs expected to receive
struct NapierSupplyFuseEnterData {
    IPrincipalToken principalToken;
    address tokenIn;
    uint256 amountIn;
    uint256 minPrincipalsAmount;
}

/// @title NapierSupplyFuse
/// @notice Fuse for supplying assets into Napier V2 Principal Tokens via the universal router
/// @dev Substrates in this fuse are the Napier V2 Principal Tokens
contract NapierSupplyFuse is NapierUniversalRouterFuse {
    using SafeERC20 for ERC20;

    /// @notice Emitted when supplying assets into Napier V2 PTs
    /// @param version Address of this contract version
    /// @param principalToken Address of the Napier V2 Principal Token
    /// @param tokenIn Asset supplied into the router
    /// @param principals Amount of PTs/YTs issued to the vault
    event NapierSupplyFuseEnter(address version, address principalToken, address tokenIn, uint256 principals);
    constructor(uint256 marketId_, address router_) {
        VERSION = address(this);
        if (marketId_ == 0) revert NapierFuseInvalidMarketId();
        if (router_ == address(0)) revert NapierFuseInvalidRouter();

        MARKET_ID = marketId_;
        ROUTER = IUniversalRouter(router_);
    }

    /// @notice Supplies assets into Napier PT, minting PT + YT into the vault
    function enter(NapierSupplyFuseEnterData calldata data_) external {
        IPrincipalToken pt = data_.principalToken;

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(pt))) {
            revert NapierFuseInvalidToken();
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.tokenIn)) {
            revert NapierFuseInvalidToken();
        }

        if (data_.amountIn == 0) {
            // NOTE: The following interaction relies on pre-transfer and CONTRACT_BALANCE.
            // Passing amountIn == 0 leaves the router free to sweep any residual balances (or to no-op silently).
            // Early return to keep behaviour predictable.
            return;
        }
        address underlying = pt.underlying(); // vault shares
        address asset = pt.i_asset();

        bytes memory commands;
        bytes[] memory inputs;

        if (data_.tokenIn == underlying) {
            // Supply PT for underlying token
            commands = abi.encodePacked(bytes1(uint8(Commands.PT_SUPPLY)));
            inputs = new bytes[](1);
            inputs[0] = abi.encode(pt, ActionConstants.CONTRACT_BALANCE, address(this));
        } else if (data_.tokenIn == asset) {
            // Supply PT for tokenIn through VaultConnector
            commands = abi.encodePacked(
                bytes1(uint8(Commands.VAULT_CONNECTOR_DEPOSIT)),
                bytes1(uint8(Commands.PT_SUPPLY))
            );

            inputs = new bytes[](2);
            inputs[0] = abi.encode(
                underlying,
                asset,
                data_.tokenIn,
                ActionConstants.CONTRACT_BALANCE,
                ActionConstants.ADDRESS_THIS
            );
            inputs[1] = abi.encode(pt, ActionConstants.CONTRACT_BALANCE, address(this));
        } else {
            revert NapierFuseInvalidToken();
        }

        uint256 balanceBefore = pt.balanceOf(address(this));

        // Pre-transfer PT to the router
        // Router might consume that more tokens than we transferred but this only benefits the vault (we receive more tokens than we requested)
        // This can only happen if someone deliberately donates tokens to the router or if a previous call left dust.
        ERC20(data_.tokenIn).safeTransfer(address(ROUTER), data_.amountIn);
        ROUTER.execute(commands, inputs);

        uint256 principals = pt.balanceOf(address(this)) - balanceBefore;
        if (principals < data_.minPrincipalsAmount) {
            revert NapierFuseInsufficientAmount();
        }

        emit NapierSupplyFuseEnter(VERSION, address(data_.principalToken), data_.tokenIn, principals);
    }
}
