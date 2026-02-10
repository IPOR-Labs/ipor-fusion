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
import {IV4Router} from "./ext/IV4Router.sol";
import {Commands} from "./utils/Commands.sol";
import {LibExpiry} from "./utils/LibExpiry.sol";

import {NapierUniversalRouterFuse} from "./NapierUniversalRouterFuse.sol";

/// @param pool Address of the Napier V2 toki pool
/// @param amountIn Amount of currency1 token to deposit
/// @param minLiquidity Minimum amount of liquidity to receive
struct NapierZapDepositFuseEnterData {
    ITokiPoolToken pool;
    uint256 amountIn;
    uint256 minLiquidity;
}

/// @param pool Address of the Napier V2 toki pool
/// @param liquidity Amount of liquidity to withdraw
/// @param amount1OutMin Minimum amount of currency1 to receive
struct NapierZapDepositFuseExitData {
    ITokiPoolToken pool;
    uint256 liquidity;
    uint256 amount1OutMin;
}

/// @title NapierZapDepositFuse
/// @notice Fuse for zap depositing/withdrawing currency1 tokens
/// @dev Splits currency1, keeps YT, and adds liquidity with PT + remaining currency1
contract NapierZapDepositFuse is NapierUniversalRouterFuse {
    using SafeERC20 for ERC20;
    /// @param version Address of this contract version
    /// @param pool Address of the Napier V2 toki pool
    /// @param liquidity Amount of liquidity to deposit
    /// @param principals Amount of PTs minted
    event NapierZapDepositFuseEnter(address version, address pool, uint256 liquidity, uint256 principals);

    /// @param version Address of this contract version
    /// @param pool Address of the Napier V2 toki pool
    /// @param liquidity Amount of liquidity to withdraw
    /// @param underlyings Amount of currency1 tokens withdrawn
    event NapierZapDepositFuseExit(address version, address pool, uint256 liquidity, uint256 underlyings);

    constructor(uint256 marketId_, address router_) {
        VERSION = address(this);
        if (marketId_ == 0) revert NapierFuseInvalidMarketId();
        if (router_ == address(0)) revert NapierFuseInvalidRouter();

        MARKET_ID = marketId_;
        ROUTER = IUniversalRouter(router_);
    }

    /// @notice Zap deposits underlying tokens into the pool without price impact
    /// @notice The router spends some of the underlying tokens to mint PTs and YTs and deposits the rest of the underlying tokens and the PTs into the pool
    function enter(NapierZapDepositFuseEnterData calldata data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(data_.pool))) {
            revert NapierFuseInvalidMarketId();
        }

        PoolKey memory key = _getPoolKey(data_.pool);
        address underlying = Currency.unwrap(key.currency0);
        address pt = Currency.unwrap(key.currency1);

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, underlying)) {
            revert NapierFuseInvalidToken();
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, pt)) {
            revert NapierFuseInvalidToken();
        }

        address yt = IPrincipalToken(pt).i_yt();
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, yt)) {
            revert NapierFuseInvalidToken();
        }

        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.TP_SPLIT_UNDERLYING_TOKEN_LIQUIDITY_KEEP_YT)),
            bytes1(uint8(Commands.TP_ADD_LIQUIDITY))
        );

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(key, ActionConstants.CONTRACT_BALANCE, address(this)); // key, amount0In, yt receiver
        inputs[1] = abi.encode(
            key,
            ActionConstants.CONTRACT_BALANCE,
            ActionConstants.CONTRACT_BALANCE,
            data_.minLiquidity,
            address(this)
        );

        uint256 balanceBefore = data_.pool.balanceOf(address(this));
        uint256 principalsBefore = ERC20(yt).balanceOf(address(this));

        ERC20(underlying).safeTransfer(address(ROUTER), data_.amountIn);
        ROUTER.execute(commands, inputs);

        // The issued YTs are the same amount as the issued PTs
        uint256 liquidity = data_.pool.balanceOf(address(this)) - balanceBefore;
        uint256 principals = ERC20(yt).balanceOf(address(this)) - principalsBefore;
        if (liquidity < data_.minLiquidity) {
            revert NapierFuseInsufficientAmount();
        }

        emit NapierZapDepositFuseEnter(VERSION, address(data_.pool), liquidity, principals);
    }

    /// @notice Zap withdraws liquidity and converts the withdrawn PTs to underlying tokens
    /// @notice Pre-maturity: removes liquidity, swaps PT to currency1 via V4
    /// @notice Post-maturity: removes liquidity, redeems PT for currency1
    function exit(NapierZapDepositFuseExitData calldata data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(data_.pool))) {
            revert NapierFuseInvalidMarketId();
        }

        PoolKey memory key = _getPoolKey(data_.pool);
        address underlying = Currency.unwrap(key.currency0);
        address pt = Currency.unwrap(key.currency1);

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, underlying)) {
            revert NapierFuseInvalidToken();
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, pt)) {
            revert NapierFuseInvalidToken();
        }

        bytes memory commands;
        bytes[] memory inputs;

        if (LibExpiry.isExpired(IPrincipalToken(pt))) {
            // Post-maturity: Remove liquidity, redeem PT, sweep underlying token
            commands = abi.encodePacked(
                bytes1(uint8(Commands.TP_REMOVE_LIQUIDITY)),
                bytes1(uint8(Commands.PT_REDEEM)),
                bytes1(uint8(Commands.SWEEP))
            );

            inputs = new bytes[](3);
            inputs[0] = abi.encode(key, ActionConstants.CONTRACT_BALANCE, 0, 0, ActionConstants.ADDRESS_THIS);
            inputs[1] = abi.encode(IPrincipalToken(pt), ActionConstants.CONTRACT_BALANCE, ActionConstants.ADDRESS_THIS);
            inputs[2] = abi.encode(underlying, address(this), data_.amount1OutMin); // token, receiver, minAmountOut
        } else {
            // Pre-maturity: Remove liquidity, swap PT to underlying token, sweep underlying token
            commands = abi.encodePacked(
                bytes1(uint8(Commands.TP_REMOVE_LIQUIDITY)),
                bytes1(uint8(Commands.V4_SWAP)),
                bytes1(uint8(Commands.SWEEP))
            );

            bytes memory v4Actions = abi.encodePacked(
                bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
                bytes1(uint8(Actions.SETTLE)),
                bytes1(uint8(Actions.TAKE))
            );

            // Swap PT to underlying token
            bytes[] memory v4Params = new bytes[](3);
            v4Params[0] = abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: false, // PT -> currency1
                    amountIn: ActionConstants.CONTRACT_BALANCE,
                    amountOutMinimum: 0,
                    hookData: ""
                })
            );
            v4Params[1] = abi.encode(pt, ActionConstants.OPEN_DELTA, false);
            v4Params[2] = abi.encode(underlying, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA);

            inputs = new bytes[](3);
            inputs[0] = abi.encode(key, ActionConstants.CONTRACT_BALANCE, 0, 0, ActionConstants.ADDRESS_THIS);
            inputs[1] = abi.encode(v4Actions, v4Params);
            inputs[2] = abi.encode(underlying, address(this), data_.amount1OutMin); // token, receiver, minAmountOut
        }

        uint256 balanceBefore = data_.pool.balanceOf(address(this));
        uint256 underlyingsBefore = ERC20(underlying).balanceOf(address(this));

        ERC20(address(data_.pool)).safeTransfer(address(ROUTER), data_.liquidity);
        ROUTER.execute(commands, inputs);

        uint256 liquidity = balanceBefore - data_.pool.balanceOf(address(this));
        uint256 underlyings = ERC20(underlying).balanceOf(address(this)) - underlyingsBefore;
        if (underlyings < data_.amount1OutMin) {
            revert NapierFuseInsufficientAmount();
        }

        emit NapierZapDepositFuseExit(VERSION, address(data_.pool), liquidity, underlyings);
    }
}
