// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {FxMintFuseLib} from "./lib/FxMintFuseLib.sol";

/// @notice Borrow fxUSD against the vault's f(x) position
/// @param pool The f(x) long pool (must be a granted substrate)
/// @param fxUsdAmount fxUSD to borrow (18 decimals; f(x) takes its borrow fee from it)
struct FxMintBorrowFuseEnterData {
    address pool;
    uint256 fxUsdAmount;
}

/// @notice Repay fxUSD debt of the vault's f(x) position
/// @param pool The f(x) long pool (must be a granted substrate)
/// @param fxUsdAmount Debt to repay (>= debt = repay all); the vault must hold it plus the f(x) repay fee
struct FxMintBorrowFuseExitData {
    address pool;
    uint256 fxUsdAmount;
}

/// @title FxMintBorrowFuse
/// @notice Borrows / repays fxUSD on the vault's existing f(x) Protocol v2 position.
/// @dev Repaying all debt while collateral remains breaches f(x)'s minimum debt ratio: close fully with
///      FxMintCollateralAndBorrowFuse (repay all + withdraw all in one operate).
contract FxMintBorrowFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event FxMintBorrowFuseEnter(address version, address pool, uint256 positionId, uint256 amount);
    event FxMintBorrowFuseExit(address version, address pool, uint256 positionId, uint256 amount);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Borrows fxUSD (requires an existing position)
    function enter(FxMintBorrowFuseEnterData memory data_) public returns (uint256 positionId) {
        if (data_.fxUsdAmount == 0) return 0;
        FxMintFuseLib.checkPool(MARKET_ID, data_.pool, "enter");
        (positionId, , ) = FxMintFuseLib.position(data_.pool);
        if (positionId == 0) revert FxMintFuseLib.FxMintFuseNoPosition(data_.pool);
        FxMintFuseLib.operate(data_.pool, 0, FxMintFuseLib.positiveDelta(data_.fxUsdAmount));
        emit FxMintBorrowFuseEnter(VERSION, data_.pool, positionId, data_.fxUsdAmount);
    }

    /// @notice Repays fxUSD debt
    function exit(FxMintBorrowFuseExitData memory data_) public returns (uint256 positionId, uint256 amount) {
        if (data_.fxUsdAmount == 0) return (0, 0);
        FxMintFuseLib.checkPool(MARKET_ID, data_.pool, "exit");
        uint256 rawDebts;
        (positionId, , rawDebts) = FxMintFuseLib.position(data_.pool);
        amount = data_.fxUsdAmount >= rawDebts ? rawDebts : data_.fxUsdAmount;
        FxMintFuseLib.operate(data_.pool, 0, FxMintFuseLib.negativeDelta(data_.fxUsdAmount, rawDebts));
        emit FxMintBorrowFuseExit(VERSION, data_.pool, positionId, amount);
    }
}
