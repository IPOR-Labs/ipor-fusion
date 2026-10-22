// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {IFxPool} from "./ext/IFxPool.sol";
import {FxMintFuseLib} from "./lib/FxMintFuseLib.sol";

/// @notice Add collateral and borrow in one f(x) operate
/// @param pool The f(x) long pool (must be a granted substrate)
/// @param collateralAmount Max collateral to add (capped at the vault balance)
/// @param fxUsdAmount fxUSD to borrow
struct FxMintCollateralAndBorrowFuseEnterData {
    address pool;
    uint256 collateralAmount;
    uint256 fxUsdAmount;
}

/// @notice Repay and withdraw in one f(x) operate (atomic deleverage)
/// @param pool The f(x) long pool (must be a granted substrate)
/// @param collateralAmount Collateral to withdraw (>= position = all)
/// @param fxUsdAmount Debt to repay (>= debt = all); the vault must hold it plus the f(x) repay fee
struct FxMintCollateralAndBorrowFuseExitData {
    address pool;
    uint256 collateralAmount;
    uint256 fxUsdAmount;
}

/// @title FxMintCollateralAndBorrowFuse
/// @notice Both legs of the vault's f(x) Protocol v2 position in a single `operate`. f(x) allows one `operate` per
///         transaction, so "deposit and borrow" and "repay and withdraw" cannot be split across two fuse actions.
contract FxMintCollateralAndBorrowFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event FxMintCollateralAndBorrowFuseEnter(
        address version,
        address pool,
        uint256 positionId,
        uint256 collateralAmount,
        uint256 fxUsdAmount
    );
    event FxMintCollateralAndBorrowFuseExit(
        address version,
        address pool,
        uint256 positionId,
        uint256 collateralAmount,
        uint256 fxUsdAmount
    );

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Adds collateral and borrows fxUSD (opens the position if needed)
    function enter(FxMintCollateralAndBorrowFuseEnterData memory data_) public returns (uint256 positionId) {
        if (data_.collateralAmount == 0 && data_.fxUsdAmount == 0) return 0;
        FxMintFuseLib.checkPool(MARKET_ID, data_.pool, "enter");
        uint256 balance = IERC20(IFxPool(data_.pool).collateralToken()).balanceOf(address(this));
        uint256 collateral = data_.collateralAmount <= balance ? data_.collateralAmount : balance;
        positionId = FxMintFuseLib.operate(
            data_.pool,
            FxMintFuseLib.positiveDelta(collateral),
            FxMintFuseLib.positiveDelta(data_.fxUsdAmount)
        );
        emit FxMintCollateralAndBorrowFuseEnter(VERSION, data_.pool, positionId, collateral, data_.fxUsdAmount);
    }

    /// @notice Repays fxUSD and withdraws collateral
    function exit(FxMintCollateralAndBorrowFuseExitData memory data_) public returns (uint256 positionId) {
        if (data_.collateralAmount == 0 && data_.fxUsdAmount == 0) return 0;
        FxMintFuseLib.checkPool(MARKET_ID, data_.pool, "exit");
        uint256 rawColls;
        uint256 rawDebts;
        (positionId, rawColls, rawDebts) = FxMintFuseLib.position(data_.pool);
        uint256 current = FxMintFuseLib.collateralAmount(data_.pool, rawColls);
        int256 collDelta = data_.collateralAmount == 0
            ? int256(0)
            : FxMintFuseLib.negativeDelta(data_.collateralAmount, current);
        int256 debtDelta = data_.fxUsdAmount == 0 ? int256(0) : FxMintFuseLib.negativeDelta(data_.fxUsdAmount, rawDebts);
        FxMintFuseLib.operate(data_.pool, collDelta, debtDelta);
        emit FxMintCollateralAndBorrowFuseExit(
            VERSION,
            data_.pool,
            positionId,
            data_.collateralAmount >= current ? current : data_.collateralAmount,
            data_.fxUsdAmount >= rawDebts ? rawDebts : data_.fxUsdAmount
        );
    }
}
