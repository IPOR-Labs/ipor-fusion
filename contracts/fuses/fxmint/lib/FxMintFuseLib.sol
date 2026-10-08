// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PlasmaVaultConfigLib} from "../../../libraries/PlasmaVaultConfigLib.sol";
import {IFxPoolManager} from "../ext/IFxPoolManager.sol";
import {IFxPool} from "../ext/IFxPool.sol";
import {FxMintStorageLib} from "./FxMintStorageLib.sol";

/// @title FxMintFuseLib
/// @notice Shared logic of the FxMint fuses: substrate check, one f(x) `operate` with exact approvals, position id
///         bookkeeping. f(x) allows a single `operate` per transaction, so every fuse action is one `operate`.
library FxMintFuseLib {
    using SafeERC20 for IERC20;

    error FxMintFuseUnsupportedPool(string action, address pool);
    error FxMintFuseNoPosition(address pool);
    error FxMintFuseAmountTooLarge(uint256 amount);

    /// @notice Reverts unless `pool_` is a granted substrate of `marketId_`
    function checkPool(uint256 marketId_, address pool_, string memory action_) internal view {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(marketId_, pool_)) {
            revert FxMintFuseUnsupportedPool(action_, pool_);
        }
    }

    /// @notice Current position (0s if none) of the vault in `pool_`
    function position(address pool_) internal view returns (uint256 positionId, uint256 rawColls, uint256 rawDebts) {
        positionId = FxMintStorageLib.getPositionId(pool_);
        if (positionId != 0) (rawColls, rawDebts) = IFxPool(pool_).getPosition(positionId);
    }

    /// @notice Position collateral in collateral token units (18-dec raw -> token decimals)
    function collateralAmount(address pool_, uint256 rawColls_) internal view returns (uint256) {
        if (rawColls_ == 0) return 0;
        address manager = IFxPool(pool_).poolManager();
        return (rawColls_ * 1e18) / IFxPoolManager(manager).getTokenScalingFactor(IFxPool(pool_).collateralToken());
    }

    /// @notice One f(x) operate. collDelta_ > 0 adds `collDelta_` collateral, < 0 withdraws; debtDelta_ > 0 borrows,
    ///         < 0 repays; type(int256).min = all. Approves exactly what f(x) may pull and resets to 0 afterwards.
    /// @return positionId The (possibly new) position id; cleared from storage once the position is fully closed.
    function operate(address pool_, int256 collDelta_, int256 debtDelta_) internal returns (uint256 positionId) {
        address manager = IFxPool(pool_).poolManager();
        address collateral = IFxPool(pool_).collateralToken();
        address fxUsd = IFxPool(pool_).fxUSD();
        positionId = FxMintStorageLib.getPositionId(pool_);
        if (positionId == 0 && (collDelta_ < 0 || debtDelta_ < 0)) revert FxMintFuseNoPosition(pool_);

        if (collDelta_ > 0) IERC20(collateral).forceApprove(manager, uint256(collDelta_));
        if (debtDelta_ < 0) {
            // repay (plus f(x)'s repay fee) is pulled from the vault: allow at most what it holds
            IERC20(fxUsd).forceApprove(manager, IERC20(fxUsd).balanceOf(address(this)));
        }

        uint256 returnedId = IFxPoolManager(manager).operate(pool_, positionId, collDelta_, debtDelta_);

        if (collDelta_ > 0) IERC20(collateral).forceApprove(manager, 0);
        if (debtDelta_ < 0) IERC20(fxUsd).forceApprove(manager, 0);

        if (positionId == 0) {
            positionId = returnedId;
            FxMintStorageLib.setPositionId(pool_, positionId);
        }
        (uint256 rawColls, uint256 rawDebts) = IFxPool(pool_).getPosition(positionId);
        if (rawColls == 0 && rawDebts == 0) FxMintStorageLib.setPositionId(pool_, 0);
    }

    /// @notice Signed delta for a withdraw / repay of `amount_`, using f(x)'s "all" sentinel when `amount_` covers
    ///         the whole `current_` balance
    function negativeDelta(uint256 amount_, uint256 current_) internal pure returns (int256) {
        if (amount_ >= current_) return type(int256).min;
        if (amount_ > uint256(type(int256).max)) revert FxMintFuseAmountTooLarge(amount_);
        return -int256(amount_);
    }

    /// @notice Signed delta for an add / borrow of `amount_`
    function positiveDelta(uint256 amount_) internal pure returns (int256) {
        if (amount_ > uint256(type(int256).max)) revert FxMintFuseAmountTooLarge(amount_);
        return int256(amount_);
    }
}
