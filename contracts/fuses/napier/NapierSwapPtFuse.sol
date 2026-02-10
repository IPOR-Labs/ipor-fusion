// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

import {PoolKey, Currency} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "./utils/Actions.sol";
import {ActionConstants} from "./utils/ActionsConstants.sol";

import {ITokiPoolToken} from "./ext/ITokiPoolToken.sol";
import {IPrincipalToken} from "./ext/IPrincipalToken.sol";
import {IUniversalRouter} from "./ext/IUniversalRouter.sol";
import {Commands} from "./utils/Commands.sol";

import {NapierUniversalRouterFuse} from "./NapierUniversalRouterFuse.sol";
import {IV4Router} from "./ext/IV4Router.sol";

/// @param tokenIn Asset to issue PT/YT with
/// @param amountIn Amount of the asset to issue PT/YT with
struct NapierSwapPtFuseData {
    ITokiPoolToken pool;
    uint256 amountIn;
    uint256 minimumAmount;
}

/// @title NapierSwapPtFuse
/// @notice Fuse for swapping PT for tokens via the universal router
/// @dev Substrates in this fuse are the Napier V2 Principal Tokens
contract NapierSwapPtFuse is NapierUniversalRouterFuse {
    using SafeERC20 for ERC20;

    /// @notice Error thrown when amountIn is zero
    error NapierSwapPtFuseInvalidAmountIn();
    /// @param version Address of this contract version
    /// @param pool Address of the Napier V2 toki pool
    /// @param tokenIn Asset supplied into the router
    /// @param amountOut Amount of PTs/YTs issued to the vault
    event NapierSwapPtFuseEnter(address version, address pool, address tokenIn, uint256 amountOut);

    event NapierSwapPtFuseExit(address version, address pool, address tokenOut, uint256 amountOut);

    constructor(uint256 marketId_, address router_) {
        VERSION = address(this);
        if (marketId_ == 0) revert NapierFuseInvalidMarketId();
        if (router_ == address(0)) revert NapierFuseInvalidRouter();

        MARKET_ID = marketId_;
        ROUTER = IUniversalRouter(router_);
    }

    function enter(NapierSwapPtFuseData calldata data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(data_.pool))) {
            revert NapierFuseInvalidMarketId();
        }

        PoolKey memory key = _getPoolKey(data_.pool);
        address tokenIn = Currency.unwrap(key.currency0);
        address tokenOut = Currency.unwrap(key.currency1);

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, tokenIn)) {
            revert NapierFuseInvalidToken();
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, tokenOut)) {
            revert NapierFuseInvalidToken();
        }

        if (data_.amountIn == 0) {
            revert NapierSwapPtFuseInvalidAmountIn();
        }

        // Buy PT with the underlying token
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V4_SWAP)));
        bytes memory v4Actions = abi.encodePacked(
            bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
            bytes1(uint8(Actions.SETTLE)),
            bytes1(uint8(Actions.TAKE_ALL))
        );
        bytes[] memory v4Params = new bytes[](3);
        v4Params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: data_.amountIn,
                amountOutMinimum: 0,
                hookData: ""
            })
        );
        v4Params[1] = abi.encode(key.currency0, data_.amountIn, false); // payerIsUser=false
        v4Params[2] = abi.encode(key.currency1, data_.minimumAmount);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(v4Actions, v4Params);

        uint256 balanceBefore = key.currency1.balanceOf(address(this));

        key.currency0.transfer(address(ROUTER), data_.amountIn);
        ROUTER.execute(commands, inputs);

        uint256 amountOut = key.currency1.balanceOf(address(this)) - balanceBefore;
        if (amountOut < data_.minimumAmount) {
            revert NapierFuseInsufficientAmount();
        }

        emit NapierSwapPtFuseEnter(VERSION, address(data_.pool), Currency.unwrap(key.currency0), amountOut);
    }

    function exit(NapierSwapPtFuseData calldata data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(data_.pool))) {
            revert NapierFuseInvalidMarketId();
        }

        PoolKey memory key = _getPoolKey(data_.pool);
        address tokenIn = Currency.unwrap(key.currency1);
        address tokenOut = Currency.unwrap(key.currency0);

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, tokenIn)) {
            revert NapierFuseInvalidToken();
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, tokenOut)) {
            revert NapierFuseInvalidToken();
        }

        if (data_.amountIn == 0) {
            revert NapierSwapPtFuseInvalidAmountIn();
        }

        // Sell PT for the underlying token
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V4_SWAP)));
        bytes memory v4Actions = abi.encodePacked(
            bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
            bytes1(uint8(Actions.SETTLE)),
            bytes1(uint8(Actions.TAKE_ALL))
        );

        bytes[] memory v4Params = new bytes[](3);
        v4Params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: data_.amountIn,
                amountOutMinimum: 0,
                hookData: ""
            })
        );
        v4Params[1] = abi.encode(key.currency1, data_.amountIn, false); // payerIsUser=false
        v4Params[2] = abi.encode(key.currency0, data_.minimumAmount);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(v4Actions, v4Params);

        uint256 balanceBefore = key.currency0.balanceOf(address(this));

        key.currency1.transfer(address(ROUTER), data_.amountIn);
        ROUTER.execute(commands, inputs);

        uint256 amountOut = key.currency0.balanceOf(address(this)) - balanceBefore;
        if (amountOut < data_.minimumAmount) {
            revert NapierFuseInsufficientAmount();
        }

        emit NapierSwapPtFuseExit(VERSION, address(data_.pool), Currency.unwrap(key.currency0), amountOut);
    }
}
