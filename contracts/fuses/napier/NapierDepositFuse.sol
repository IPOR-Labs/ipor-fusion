// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

import {PoolKey, Currency} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ActionConstants} from "./utils/ActionsConstants.sol";

import {ITokiPoolToken} from "./ext/ITokiPoolToken.sol";
import {IUniversalRouter} from "./ext/IUniversalRouter.sol";
import {Commands} from "./utils/Commands.sol";

import {NapierUniversalRouterFuse} from "./NapierUniversalRouterFuse.sol";

/// @param pool Address of the Napier V2 toki pool
/// @param amount0In Amount of the currency0 to deposit
/// @param amount1In Amount of the currency1 to deposit
/// @param minLiquidity Minimum amount of liquidity to receive
struct NapierDepositFuseEnterData {
    ITokiPoolToken pool;
    uint256 amount0In;
    uint256 amount1In;
    uint256 minLiquidity;
}

/// @param pool Address of the Napier V2 toki pool
/// @param liquidity Amount of liquidity to withdraw
/// @param amount0OutMin Minimum amount of currency0 to receive
/// @param amount1OutMin Minimum amount of token1 to receive
struct NapierDepositFuseExitData {
    ITokiPoolToken pool;
    uint256 liquidity;
    uint256 amount0OutMin;
    uint256 amount1OutMin;
}

/// @title NapierDepositFuse
/// @notice Fuse for depositing/withdrawing assets proportional to the pool's liquidity proportions
/// @dev Substrates in this fuse are the Napier V2 Principal Tokens
contract NapierDepositFuse is NapierUniversalRouterFuse {
    using SafeERC20 for ERC20;
    /// @param version Address of this contract version
    /// @param pool Address of the Napier V2 toki pool
    /// @param liquidity Amount of liquidity to deposit
    event NapierDepositFuseEnter(address version, address pool, uint256 liquidity);

    event NapierDepositFuseExit(address version, address pool, uint256 liquidity);

    constructor(uint256 marketId_, address router_) {
        VERSION = address(this);
        if (marketId_ == 0) revert NapierFuseIInvalidMarketId();
        if (router_ == address(0)) revert NapierFuseIInvalidRouter();

        MARKET_ID = marketId_;
        ROUTER = IUniversalRouter(router_);
    }

    function enter(NapierDepositFuseEnterData calldata data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(data_.pool))) {
            revert NapierFuseIInvalidMarketId();
        }

        PoolKey memory key = _getPoolKey(data_.pool);
        address underlying = Currency.unwrap(key.currency0);
        address pt = Currency.unwrap(key.currency1);

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, underlying)) {
            revert NapierFuseIInvalidToken();
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, pt)) {
            revert NapierFuseIInvalidToken();
        }

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.TP_ADD_LIQUIDITY)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            key,
            ActionConstants.CONTRACT_BALANCE,
            ActionConstants.CONTRACT_BALANCE,
            data_.minLiquidity,
            address(this)
        );

        uint256 balanceBefore = data_.pool.balanceOf(address(this));

        ERC20(underlying).safeTransfer(address(ROUTER), data_.amount0In);
        ERC20(pt).safeTransfer(address(ROUTER), data_.amount1In);
        ROUTER.execute(commands, inputs);

        uint256 liquidity = data_.pool.balanceOf(address(this)) - balanceBefore;
        if (liquidity < data_.minLiquidity) {
            revert NapierFuseInsufficientAmount();
        }

        emit NapierDepositFuseEnter(VERSION, address(data_.pool), liquidity);
    }

    function exit(NapierDepositFuseExitData calldata data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(data_.pool))) {
            revert NapierFuseIInvalidMarketId();
        }

        PoolKey memory key = _getPoolKey(data_.pool);
        address underlying = Currency.unwrap(key.currency0);
        address pt = Currency.unwrap(key.currency1);

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, underlying)) {
            revert NapierFuseIInvalidToken();
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, pt)) {
            revert NapierFuseIInvalidToken();
        }

        // Withdraw liquidity from the pool
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.TP_REMOVE_LIQUIDITY)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            key,
            ActionConstants.CONTRACT_BALANCE,
            data_.amount0OutMin,
            data_.amount1OutMin,
            address(this)
        );

        uint256 balanceBefore = data_.pool.balanceOf(address(this));
        uint256 underlyingBalanceBefore = ERC20(underlying).balanceOf(address(this));
        uint256 ptBalanceBefore = ERC20(pt).balanceOf(address(this));

        ERC20(address(data_.pool)).safeTransfer(address(ROUTER), data_.liquidity);
        ROUTER.execute(commands, inputs);

        uint256 liquidity = balanceBefore - data_.pool.balanceOf(address(this));
        uint256 amount0Out = ERC20(underlying).balanceOf(address(this)) - underlyingBalanceBefore;
        uint256 amount1Out = ERC20(pt).balanceOf(address(this)) - ptBalanceBefore;

        if (amount0Out < data_.amount0OutMin || amount1Out < data_.amount1OutMin) {
            revert NapierFuseInsufficientAmount();
        }

        emit NapierDepositFuseExit(VERSION, address(data_.pool), liquidity);
    }
}
