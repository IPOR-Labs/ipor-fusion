// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IDolomiteMargin} from "./ext/IDolomiteMargin.sol";
import {DolomiteFuseLib} from "./DolomiteFuseLib.sol";

/// @dev Struct for borrowing assets from Dolomite protocol
struct DolomiteBorrowFuseEnterData {
    /// @notice asset address to borrow
    address asset;
    /// @notice amount to borrow
    uint256 amount;
    /// @notice minimum amount to receive (slippage protection)
    uint256 minAmountOut;
    /// @notice sub-account holding collateral
    uint8 subAccountId;
}

/// @dev Struct for repaying borrowed assets to Dolomite
struct DolomiteBorrowFuseExitData {
    /// @notice asset address to repay
    address asset;
    /// @notice amount to repay (use type(uint256).max for full repayment)
    uint256 amount;
    /// @notice minimum amount of debt to reduce (slippage protection)
    uint256 minDebtReduction;
    /// @notice sub-account with debt
    uint8 subAccountId;
}

/// @title DolomiteBorrowFuse
/// @notice Fuse for borrowing and repaying assets on Dolomite protocol
/// @author IPOR Labs
contract DolomiteBorrowFuse is IFuseCommon {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable DOLOMITE_MARGIN;

    event DolomiteBorrowFuseEnter(
        address version,
        address asset,
        uint256 dolomiteMarketId,
        uint256 amount,
        uint8 subAccountId
    );

    event DolomiteBorrowFuseExit(
        address version,
        address asset,
        uint256 dolomiteMarketId,
        uint256 amount,
        uint8 subAccountId
    );

    error DolomiteBorrowFuseInvalidMarketId();
    error DolomiteBorrowFuseInvalidDolomiteMargin();
    error DolomiteBorrowFuseUnsupportedBorrowAsset(address asset, uint8 subAccountId);
    error DolomiteBorrowFuseUnsupportedRepayAsset(address asset, uint8 subAccountId);
    error DolomiteBorrowFuseNoDebtToRepay(address asset, uint8 subAccountId);
    error DolomiteBorrowFuseSlippageExceeded(uint256 received, uint256 minRequired);
    error DolomiteBorrowFuseDebtReductionTooSmall(uint256 repaid, uint256 minRequired);

    constructor(uint256 marketId_, address dolomiteMargin_) {
        if (marketId_ == 0) {
            revert DolomiteBorrowFuseInvalidMarketId();
        }
        if (dolomiteMargin_ == address(0)) {
            revert DolomiteBorrowFuseInvalidDolomiteMargin();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        DOLOMITE_MARGIN = dolomiteMargin_;
    }

    /// @notice Borrows assets from Dolomite protocol
    /// @param data_ The borrow data
    /// @return asset The borrowed asset address
    /// @return amount The amount borrowed
    function enter(DolomiteBorrowFuseEnterData memory data_) public returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, 0);
        }

        if (!DolomiteFuseLib.canBorrow(MARKET_ID, data_.asset, data_.subAccountId)) {
            revert DolomiteBorrowFuseUnsupportedBorrowAsset(data_.asset, data_.subAccountId);
        }

        uint256 dolomiteMarketId = IDolomiteMargin(DOLOMITE_MARGIN).getMarketIdByTokenAddress(data_.asset);

        uint256 balanceBefore = ERC20(data_.asset).balanceOf(address(this));

        _executeWithdraw(uint256(data_.subAccountId), dolomiteMarketId, data_.amount, address(this));

        uint256 actualReceived = ERC20(data_.asset).balanceOf(address(this)) - balanceBefore;

        if (actualReceived < data_.minAmountOut) {
            revert DolomiteBorrowFuseSlippageExceeded(actualReceived, data_.minAmountOut);
        }

        emit DolomiteBorrowFuseEnter(VERSION, data_.asset, dolomiteMarketId, actualReceived, data_.subAccountId);

        return (data_.asset, actualReceived);
    }

    /// @notice Repays borrowed assets to Dolomite protocol
    /// @param data_ The repay data
    /// @return asset The repaid asset address
    /// @return amount The amount repaid
    function exit(DolomiteBorrowFuseExitData memory data_) public returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, 0);
        }

        if (
            !DolomiteFuseLib.canSupply(MARKET_ID, data_.asset, data_.subAccountId) &&
            !DolomiteFuseLib.canBorrow(MARKET_ID, data_.asset, data_.subAccountId)
        ) {
            revert DolomiteBorrowFuseUnsupportedRepayAsset(data_.asset, data_.subAccountId);
        }

        uint256 dolomiteMarketId = IDolomiteMargin(DOLOMITE_MARGIN).getMarketIdByTokenAddress(data_.asset);

        IDolomiteMargin.AccountInfo memory accountInfo = IDolomiteMargin.AccountInfo({
            owner: address(this),
            number: uint256(data_.subAccountId)
        });

        IDolomiteMargin.Wei memory balance = IDolomiteMargin(DOLOMITE_MARGIN).getAccountWei(
            accountInfo,
            dolomiteMarketId
        );

        if (balance.sign || balance.value == 0) {
            revert DolomiteBorrowFuseNoDebtToRepay(data_.asset, data_.subAccountId);
        }

        uint256 debtAmount = balance.value;
        uint256 availableBalance = ERC20(data_.asset).balanceOf(address(this));

        uint256 repayAmount;
        if (data_.amount == type(uint256).max) {
            repayAmount = IporMath.min(debtAmount, availableBalance);
        } else {
            repayAmount = IporMath.min(IporMath.min(data_.amount, debtAmount), availableBalance);
        }

        if (repayAmount == 0) {
            if (data_.minDebtReduction > 0) {
                revert DolomiteBorrowFuseDebtReductionTooSmall(0, data_.minDebtReduction);
            }
            return (data_.asset, 0);
        }

        uint256 balanceBefore = ERC20(data_.asset).balanceOf(address(this));

        ERC20(data_.asset).forceApprove(DOLOMITE_MARGIN, repayAmount);

        _executeDeposit(uint256(data_.subAccountId), dolomiteMarketId, repayAmount, address(this));

        ERC20(data_.asset).forceApprove(DOLOMITE_MARGIN, 0);

        uint256 actualRepaid = balanceBefore - ERC20(data_.asset).balanceOf(address(this));

        if (actualRepaid < data_.minDebtReduction) {
            revert DolomiteBorrowFuseDebtReductionTooSmall(actualRepaid, data_.minDebtReduction);
        }

        emit DolomiteBorrowFuseExit(VERSION, data_.asset, dolomiteMarketId, actualRepaid, data_.subAccountId);

        return (data_.asset, actualRepaid);
    }

    /// @notice Gets the current borrow balance (debt) for an asset in a sub-account
    /// @param asset_ The asset address
    /// @param subAccountId_ The sub-account ID
    /// @return debtAmount The current debt amount
    function getBorrowBalance(address asset_, uint8 subAccountId_) external view returns (uint256 debtAmount) {
        uint256 dolomiteMarketId = IDolomiteMargin(DOLOMITE_MARGIN).getMarketIdByTokenAddress(asset_);

        IDolomiteMargin.AccountInfo memory accountInfo = IDolomiteMargin.AccountInfo({
            owner: address(this),
            number: uint256(subAccountId_)
        });

        IDolomiteMargin.Wei memory balance = IDolomiteMargin(DOLOMITE_MARGIN).getAccountWei(
            accountInfo,
            dolomiteMarketId
        );

        if (!balance.sign && balance.value > 0) {
            return balance.value;
        }

        return 0;
    }

    function _executeWithdraw(uint256 accountNumber, uint256 marketId, uint256 amount, address to) internal {
        IDolomiteMargin.AccountInfo[] memory accounts = new IDolomiteMargin.AccountInfo[](1);
        accounts[0] = IDolomiteMargin.AccountInfo({owner: address(this), number: accountNumber});

        IDolomiteMargin.ActionArgs[] memory actions = new IDolomiteMargin.ActionArgs[](1);
        actions[0] = IDolomiteMargin.ActionArgs({
            actionType: IDolomiteMargin.ActionType.Withdraw,
            accountId: 0,
            amount: IDolomiteMargin.AssetAmount({
                sign: false,
                denomination: IDolomiteMargin.AssetDenomination.Wei,
                ref: IDolomiteMargin.AssetReference.Delta,
                value: amount
            }),
            primaryMarketId: marketId,
            secondaryMarketId: 0,
            otherAddress: to,
            otherAccountId: 0,
            data: bytes("")
        });

        IDolomiteMargin(DOLOMITE_MARGIN).operate(accounts, actions);
    }

    function _executeDeposit(uint256 accountNumber, uint256 marketId, uint256 amount, address from) internal {
        IDolomiteMargin.AccountInfo[] memory accounts = new IDolomiteMargin.AccountInfo[](1);
        accounts[0] = IDolomiteMargin.AccountInfo({owner: address(this), number: accountNumber});

        IDolomiteMargin.ActionArgs[] memory actions = new IDolomiteMargin.ActionArgs[](1);
        actions[0] = IDolomiteMargin.ActionArgs({
            actionType: IDolomiteMargin.ActionType.Deposit,
            accountId: 0,
            amount: IDolomiteMargin.AssetAmount({
                sign: true,
                denomination: IDolomiteMargin.AssetDenomination.Wei,
                ref: IDolomiteMargin.AssetReference.Delta,
                value: amount
            }),
            primaryMarketId: marketId,
            secondaryMarketId: 0,
            otherAddress: from,
            otherAccountId: 0,
            data: bytes("")
        });

        IDolomiteMargin(DOLOMITE_MARGIN).operate(accounts, actions);
    }
}
