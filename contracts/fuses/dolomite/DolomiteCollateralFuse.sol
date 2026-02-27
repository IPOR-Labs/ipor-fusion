// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IDolomiteMargin} from "./ext/IDolomiteMargin.sol";
import {DolomiteFuseLib} from "./DolomiteFuseLib.sol";

/// @dev Struct for transferring collateral between sub-accounts
struct DolomiteCollateralFuseEnterData {
    /// @notice asset address to transfer
    address asset;
    /// @notice amount to transfer
    uint256 amount;
    /// @notice minimum shares to receive (slippage protection)
    uint256 minSharesOut;
    /// @notice source sub-account
    uint8 fromSubAccountId;
    /// @notice destination sub-account
    uint8 toSubAccountId;
}

/// @dev Struct for returning collateral from a borrow sub-account
struct DolomiteCollateralFuseExitData {
    /// @notice asset address to transfer back
    address asset;
    /// @notice amount to transfer
    uint256 amount;
    /// @notice minimum collateral to receive (slippage protection)
    uint256 minCollateralOut;
    /// @notice source sub-account
    uint8 fromSubAccountId;
    /// @notice destination sub-account
    uint8 toSubAccountId;
}

/// @title DolomiteCollateralFuse
/// @notice Fuse for managing collateral transfers between Dolomite sub-accounts
/// @author IPOR Labs
contract DolomiteCollateralFuse is IFuseCommon {
    using SafeCast for uint256;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable DOLOMITE_MARGIN;

    event DolomiteCollateralFuseEnter(
        address version,
        address asset,
        uint256 dolomiteMarketId,
        uint256 amount,
        uint8 fromSubAccountId,
        uint8 toSubAccountId
    );

    event DolomiteCollateralFuseExit(
        address version,
        address asset,
        uint256 dolomiteMarketId,
        uint256 amount,
        uint8 fromSubAccountId,
        uint8 toSubAccountId
    );

    error DolomiteCollateralFuseInvalidMarketId();
    error DolomiteCollateralFuseInvalidDolomiteMargin();
    error DolomiteCollateralFuseUnsupportedEnterSource(address asset, uint8 subAccountId);
    error DolomiteCollateralFuseUnsupportedEnterDestination(address asset, uint8 subAccountId);
    error DolomiteCollateralFuseUnsupportedExitSource(address asset, uint8 subAccountId);
    error DolomiteCollateralFuseUnsupportedExitDestination(address asset, uint8 subAccountId);
    error DolomiteCollateralFuseInsufficientBalance(
        address asset,
        uint8 subAccountId,
        uint256 available,
        uint256 requested
    );
    error DolomiteCollateralFuseSlippageExceeded(uint256 received, uint256 minRequired);

    constructor(uint256 marketId_, address dolomiteMargin_) {
        if (marketId_ == 0) {
            revert DolomiteCollateralFuseInvalidMarketId();
        }
        if (dolomiteMargin_ == address(0)) {
            revert DolomiteCollateralFuseInvalidDolomiteMargin();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        DOLOMITE_MARGIN = dolomiteMargin_;
    }

    /// @notice Transfers collateral from one sub-account to another
    /// @param data_ The transfer data
    /// @return asset The transferred asset address
    /// @return amount The amount transferred
    function enter(DolomiteCollateralFuseEnterData memory data_) public returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, 0);
        }

        if (!DolomiteFuseLib.canSupply(MARKET_ID, data_.asset, data_.fromSubAccountId)) {
            revert DolomiteCollateralFuseUnsupportedEnterSource(data_.asset, data_.fromSubAccountId);
        }

        if (!DolomiteFuseLib.canSupply(MARKET_ID, data_.asset, data_.toSubAccountId)) {
            revert DolomiteCollateralFuseUnsupportedEnterDestination(data_.asset, data_.toSubAccountId);
        }

        uint256 dolomiteMarketId = IDolomiteMargin(DOLOMITE_MARGIN).getMarketIdByTokenAddress(data_.asset);

        IDolomiteMargin.AccountInfo memory sourceAccount = IDolomiteMargin.AccountInfo({
            owner: address(this),
            number: uint256(data_.fromSubAccountId)
        });

        IDolomiteMargin.Wei memory sourceBalance = IDolomiteMargin(DOLOMITE_MARGIN).getAccountWei(
            sourceAccount,
            dolomiteMarketId
        );

        if (!sourceBalance.sign || sourceBalance.value == 0) {
            revert DolomiteCollateralFuseInsufficientBalance(data_.asset, data_.fromSubAccountId, 0, data_.amount);
        }

        uint256 finalAmount = IporMath.min(sourceBalance.value, data_.amount);

        if (finalAmount == 0) {
            return (data_.asset, 0);
        }

        _executeTransfer(uint256(data_.fromSubAccountId), uint256(data_.toSubAccountId), dolomiteMarketId, finalAmount);

        if (finalAmount < data_.minSharesOut) {
            revert DolomiteCollateralFuseSlippageExceeded(finalAmount, data_.minSharesOut);
        }

        emit DolomiteCollateralFuseEnter(
            VERSION,
            data_.asset,
            dolomiteMarketId,
            finalAmount,
            data_.fromSubAccountId,
            data_.toSubAccountId
        );

        return (data_.asset, finalAmount);
    }

    /// @notice Returns collateral from a borrow sub-account
    /// @param data_ The transfer data
    /// @return asset The transferred asset address
    /// @return amount The amount transferred
    function exit(DolomiteCollateralFuseExitData memory data_) public returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, 0);
        }

        if (!DolomiteFuseLib.canSupply(MARKET_ID, data_.asset, data_.fromSubAccountId)) {
            revert DolomiteCollateralFuseUnsupportedExitSource(data_.asset, data_.fromSubAccountId);
        }

        if (!DolomiteFuseLib.canSupply(MARKET_ID, data_.asset, data_.toSubAccountId)) {
            revert DolomiteCollateralFuseUnsupportedExitDestination(data_.asset, data_.toSubAccountId);
        }

        uint256 dolomiteMarketId = IDolomiteMargin(DOLOMITE_MARGIN).getMarketIdByTokenAddress(data_.asset);

        IDolomiteMargin.AccountInfo memory sourceAccount = IDolomiteMargin.AccountInfo({
            owner: address(this),
            number: uint256(data_.fromSubAccountId)
        });

        IDolomiteMargin.Wei memory sourceBalance = IDolomiteMargin(DOLOMITE_MARGIN).getAccountWei(
            sourceAccount,
            dolomiteMarketId
        );

        if (!sourceBalance.sign || sourceBalance.value == 0) {
            return (data_.asset, 0);
        }

        uint256 finalAmount = IporMath.min(sourceBalance.value, data_.amount);

        if (finalAmount == 0) {
            return (data_.asset, 0);
        }

        _executeTransfer(uint256(data_.fromSubAccountId), uint256(data_.toSubAccountId), dolomiteMarketId, finalAmount);

        if (finalAmount < data_.minCollateralOut) {
            revert DolomiteCollateralFuseSlippageExceeded(finalAmount, data_.minCollateralOut);
        }

        emit DolomiteCollateralFuseExit(
            VERSION,
            data_.asset,
            dolomiteMarketId,
            finalAmount,
            data_.fromSubAccountId,
            data_.toSubAccountId
        );

        return (data_.asset, finalAmount);
    }

    /// @notice Gets the collateral balance for an asset in a sub-account
    /// @param asset_ The asset address
    /// @param subAccountId_ The sub-account ID
    /// @return collateralAmount The current collateral amount
    function getCollateralBalance(
        address asset_,
        uint8 subAccountId_
    ) external view returns (uint256 collateralAmount) {
        uint256 dolomiteMarketId = IDolomiteMargin(DOLOMITE_MARGIN).getMarketIdByTokenAddress(asset_);

        IDolomiteMargin.AccountInfo memory accountInfo = IDolomiteMargin.AccountInfo({
            owner: address(this),
            number: uint256(subAccountId_)
        });

        IDolomiteMargin.Wei memory balance = IDolomiteMargin(DOLOMITE_MARGIN).getAccountWei(
            accountInfo,
            dolomiteMarketId
        );

        if (balance.sign && balance.value > 0) {
            return balance.value;
        }

        return 0;
    }

    function _executeTransfer(
        uint256 fromAccountNumber,
        uint256 toAccountNumber,
        uint256 marketId,
        uint256 amount
    ) internal {
        IDolomiteMargin.AccountInfo[] memory accounts = new IDolomiteMargin.AccountInfo[](2);
        accounts[0] = IDolomiteMargin.AccountInfo({owner: address(this), number: fromAccountNumber});
        accounts[1] = IDolomiteMargin.AccountInfo({owner: address(this), number: toAccountNumber});

        IDolomiteMargin.ActionArgs[] memory actions = new IDolomiteMargin.ActionArgs[](1);
        actions[0] = IDolomiteMargin.ActionArgs({
            actionType: IDolomiteMargin.ActionType.Transfer,
            accountId: 0,
            amount: IDolomiteMargin.AssetAmount({
                sign: false,
                denomination: IDolomiteMargin.AssetDenomination.Wei,
                ref: IDolomiteMargin.AssetReference.Delta,
                value: amount
            }),
            primaryMarketId: marketId,
            secondaryMarketId: 0,
            otherAddress: address(0),
            otherAccountId: 1,
            data: bytes("")
        });

        IDolomiteMargin(DOLOMITE_MARGIN).operate(accounts, actions);
    }
}
