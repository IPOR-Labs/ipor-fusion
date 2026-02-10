// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

import {PoolKey, Currency} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ITokiPoolToken} from "./ext/ITokiPoolToken.sol";
import {IPrincipalToken} from "./ext/IPrincipalToken.sol";
import {IUniversalRouter} from "./ext/IUniversalRouter.sol";
import {Commands} from "./utils/Commands.sol";
import {ApproximationParams} from "./ext/ApproximationParams.sol";
import {NapierUniversalRouterFuse} from "./NapierUniversalRouterFuse.sol";
import {LibPermit2} from "./utils/LibPermit2.sol";

/// @param tokenIn Asset to issue PT/YT with
/// @param amountIn Amount of the asset to issue PT/YT with
/// @param minimumAmount Minimum amount of the asset to receive
/// @param approxParams Approximation parameters for the binary search
/// @dev If approxParams.eps is zero, the binary search will use default binary search configuration.
struct NapierSwapYtEnterFuseData {
    ITokiPoolToken pool;
    uint256 amountIn;
    uint256 minimumAmount;
    ApproximationParams approxParams;
}

struct NapierSwapYtExitFuseData {
    ITokiPoolToken pool;
    uint256 amountIn;
    uint256 minimumAmount;
}

/// @title NapierSwapYtFuse
/// @notice Fuse for swapping PT for tokens via the universal router
/// @dev Substrates in this fuse are the Napier V2 Principal Tokens
contract NapierSwapYtFuse is NapierUniversalRouterFuse {
    using SafeERC20 for ERC20;

    /// @notice Error thrown when amountIn is zero
    error NapierSwapYtFuseInvalidAmountIn();
    /// @param version Address of this contract version
    /// @param pool Address of the Napier V2 toki pool
    /// @param tokenIn Asset supplied into the router
    /// @param amountOut Amount of PTs/YTs issued to the vault
    event NapierSwapYtFuseEnter(address version, address pool, address tokenIn, uint256 amountOut);

    event NapierSwapYtFuseExit(address version, address pool, address tokenOut, uint256 amountOut);

    constructor(uint256 marketId_, address router_) {
        VERSION = address(this);
        if (marketId_ == 0) revert NapierFuseInvalidMarketId();
        if (router_ == address(0)) revert NapierFuseInvalidRouter();

        MARKET_ID = marketId_;
        ROUTER = IUniversalRouter(router_);
    }

    function enter(NapierSwapYtEnterFuseData calldata data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(data_.pool))) {
            revert NapierFuseInvalidMarketId();
        }

        PoolKey memory key = _getPoolKey(data_.pool);
        address tokenIn = Currency.unwrap(key.currency0);
        address yt = IPrincipalToken(Currency.unwrap(key.currency1)).i_yt();

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, tokenIn)) {
            revert NapierFuseInvalidToken();
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, yt)) {
            revert NapierFuseInvalidToken();
        }

        if (data_.amountIn == 0) {
            revert NapierSwapYtFuseInvalidAmountIn();
        }

        // Buy YT with the underlying token
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.YT_SWAP_UNDERLYING_FOR_YT)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            key,
            data_.amountIn,
            data_.minimumAmount,
            address(this), // receiver=this
            address(this), // refundRecipient=this
            data_.approxParams
        );

        uint256 balanceBefore = ERC20(yt).balanceOf(address(this));

        LibPermit2.setupPermit2Approval(tokenIn, address(ROUTER));
        ROUTER.execute(commands, inputs);
        LibPermit2.resetPermit2Approval(tokenIn, address(ROUTER));

        uint256 amountOut = ERC20(yt).balanceOf(address(this)) - balanceBefore;
        if (amountOut < data_.minimumAmount) {
            revert NapierFuseInsufficientAmount();
        }

        emit NapierSwapYtFuseEnter(VERSION, address(data_.pool), yt, amountOut);
    }

    function exit(NapierSwapYtExitFuseData calldata data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(data_.pool))) {
            revert NapierFuseInvalidMarketId();
        }

        PoolKey memory key = _getPoolKey(data_.pool);
        address tokenOut = Currency.unwrap(key.currency0);
        address yt = IPrincipalToken(Currency.unwrap(key.currency1)).i_yt();

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, yt)) {
            revert NapierFuseInvalidToken();
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, tokenOut)) {
            revert NapierFuseInvalidToken();
        }

        if (data_.amountIn == 0) {
            revert NapierSwapYtFuseInvalidAmountIn();
        }

        // Sell PT for the underlying token
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.YT_SWAP_YT_FOR_UNDERLYING)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(key, data_.amountIn, data_.minimumAmount, address(this)); // receiver=this

        uint256 balanceBefore = key.currency0.balanceOf(address(this));

        LibPermit2.setupPermit2Approval(yt, address(ROUTER));
        ROUTER.execute(commands, inputs);
        LibPermit2.resetPermit2Approval(yt, address(ROUTER));

        uint256 amountOut = key.currency0.balanceOf(address(this)) - balanceBefore;
        if (amountOut < data_.minimumAmount) {
            revert NapierFuseInsufficientAmount();
        }

        emit NapierSwapYtFuseExit(VERSION, address(data_.pool), tokenOut, amountOut);
    }
}
