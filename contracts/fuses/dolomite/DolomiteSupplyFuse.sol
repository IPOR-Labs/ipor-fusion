// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {IDolomiteMargin} from "./ext/IDolomiteMargin.sol";
import {IDepositWithdrawalRouter} from "./ext/IDepositWithdrawalRouter.sol";
import {DolomiteFuseLib} from "./DolomiteFuseLib.sol";

/// @dev Struct for supplying assets to Dolomite protocol
struct DolomiteSupplyFuseEnterData {
    /// @notice asset address to supply
    address asset;
    /// @notice amount to supply
    uint256 amount;
    /// @notice minimum balance increase in Dolomite after supply (slippage protection)
    uint256 minBalanceIncrease;
    /// @notice sub-account to deposit into
    uint8 subAccountId;
    /// @notice isolation mode market id (0 for non-isolation mode)
    uint256 isolationModeMarketId;
}

/// @dev Struct for withdrawing assets from Dolomite protocol
struct DolomiteSupplyFuseExitData {
    /// @notice asset address to withdraw
    address asset;
    /// @notice amount to withdraw (use type(uint256).max for full withdrawal)
    uint256 amount;
    /// @notice minimum amount received from Dolomite (slippage protection)
    uint256 minAmountOut;
    /// @notice sub-account to withdraw from
    uint8 subAccountId;
    /// @notice isolation mode market id (0 for non-isolation mode)
    uint256 isolationModeMarketId;
}

/// @title DolomiteSupplyFuse
/// @notice Fuse for supplying and withdrawing assets to/from Dolomite protocol
/// @author IPOR Labs
contract DolomiteSupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable DOLOMITE_MARGIN;
    address public immutable DEPOSIT_WITHDRAWAL_ROUTER;

    event DolomiteSupplyFuseEnter(
        address version,
        address asset,
        uint256 dolomiteMarketId,
        uint256 amount,
        uint8 subAccountId
    );

    event DolomiteSupplyFuseExit(
        address version,
        address asset,
        uint256 dolomiteMarketId,
        uint256 amount,
        uint8 subAccountId
    );

    event DolomiteSupplyFuseExitFailed(address version, address asset, uint256 dolomiteMarketId, uint256 amount);

    error DolomiteSupplyFuseInvalidMarketId();
    error DolomiteSupplyFuseInvalidDolomiteMargin();
    error DolomiteSupplyFuseInvalidRouter();
    error DolomiteSupplyFuseUnsupportedAsset(string action, address asset, uint8 subAccountId);
    error DolomiteSupplyFuseBalanceIncreaseTooSmall(uint256 increased, uint256 minRequired);
    error DolomiteSupplyFuseWithdrawAmountTooSmall(uint256 received, uint256 minRequired);

    constructor(uint256 marketId_, address dolomiteMargin_, address depositWithdrawalRouter_) {
        if (marketId_ == 0) {
            revert DolomiteSupplyFuseInvalidMarketId();
        }
        if (dolomiteMargin_ == address(0)) {
            revert DolomiteSupplyFuseInvalidDolomiteMargin();
        }
        if (depositWithdrawalRouter_ == address(0)) {
            revert DolomiteSupplyFuseInvalidRouter();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        DOLOMITE_MARGIN = dolomiteMargin_;
        DEPOSIT_WITHDRAWAL_ROUTER = depositWithdrawalRouter_;
    }

    /// @notice Supplies assets to Dolomite protocol
    /// @param data_ The supply data
    /// @return asset The supplied asset address
    /// @return amount The amount supplied
    function enter(DolomiteSupplyFuseEnterData memory data_) public returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            if (data_.minBalanceIncrease > 0) {
                revert DolomiteSupplyFuseBalanceIncreaseTooSmall(0, data_.minBalanceIncrease);
            }
            return (data_.asset, 0);
        }

        if (!DolomiteFuseLib.canSupply(MARKET_ID, data_.asset, data_.subAccountId)) {
            revert DolomiteSupplyFuseUnsupportedAsset("enter", data_.asset, data_.subAccountId);
        }

        uint256 finalAmount = IporMath.min(ERC20(data_.asset).balanceOf(address(this)), data_.amount);

        if (finalAmount == 0) {
            if (data_.minBalanceIncrease > 0) {
                revert DolomiteSupplyFuseBalanceIncreaseTooSmall(0, data_.minBalanceIncrease);
            }
            return (data_.asset, 0);
        }

        // @dev getMarketIdByTokenAddress reverts if token is not registered in Dolomite.
        // dolomiteMarketId == 0 is valid (it's WETH on Dolomite).
        uint256 dolomiteMarketId = IDolomiteMargin(DOLOMITE_MARGIN).getMarketIdByTokenAddress(data_.asset);
        int256 balanceBeforeSigned;
        IDolomiteMargin.AccountInfo memory accountInfo;
        if (data_.minBalanceIncrease > 0) {
            accountInfo = IDolomiteMargin.AccountInfo({owner: address(this), number: uint256(data_.subAccountId)});

            IDolomiteMargin.Wei memory balanceBefore = IDolomiteMargin(DOLOMITE_MARGIN).getAccountWei(
                accountInfo,
                dolomiteMarketId
            );

            balanceBeforeSigned = balanceBefore.sign ? balanceBefore.value.toInt256() : -balanceBefore.value.toInt256();
        }

        ERC20(data_.asset).forceApprove(DEPOSIT_WITHDRAWAL_ROUTER, finalAmount);

        IDepositWithdrawalRouter(DEPOSIT_WITHDRAWAL_ROUTER).depositWei(
            data_.isolationModeMarketId,
            uint256(data_.subAccountId),
            dolomiteMarketId,
            finalAmount,
            IDepositWithdrawalRouter.EventFlag.None
        );

        ERC20(data_.asset).forceApprove(DEPOSIT_WITHDRAWAL_ROUTER, 0);

        if (data_.minBalanceIncrease > 0) {
            IDolomiteMargin.Wei memory balanceAfter = IDolomiteMargin(DOLOMITE_MARGIN).getAccountWei(
                accountInfo,
                dolomiteMarketId
            );

            int256 balanceAfterSigned = balanceAfter.sign
                ? balanceAfter.value.toInt256()
                : -balanceAfter.value.toInt256();

            int256 increaseSigned = balanceAfterSigned - balanceBeforeSigned;
            uint256 increase = increaseSigned > 0 ? uint256(increaseSigned) : 0;

            if (increase < data_.minBalanceIncrease) {
                revert DolomiteSupplyFuseBalanceIncreaseTooSmall(increase, data_.minBalanceIncrease);
            }
        }

        emit DolomiteSupplyFuseEnter(VERSION, data_.asset, dolomiteMarketId, finalAmount, data_.subAccountId);

        return (data_.asset, finalAmount);
    }

    /// @notice Withdraws assets from Dolomite protocol
    /// @param data_ The withdrawal data
    /// @return asset The withdrawn asset address
    /// @return amount The amount withdrawn
    function exit(DolomiteSupplyFuseExitData calldata data_) public returns (address asset, uint256 amount) {
        return _exit(data_, false);
    }

    /// @notice Performs instant withdrawal with exception handling
    /// @param params_ Parameters: [0]=amount, [1]=asset, [2]=subAccountId (optional), [3]=isolationModeMarketId (optional), [4]=minAmountOut (optional)
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);
        address asset = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);
        uint8 subAccountId = params_.length > 2 ? uint8(uint256(params_[2])) : 0;
        uint256 isolationModeMarketId = params_.length > 3 ? uint256(params_[3]) : 0;
        uint256 minAmountOut = params_.length > 4 ? uint256(params_[4]) : 0;

        _exit(DolomiteSupplyFuseExitData(asset, amount, minAmountOut, subAccountId, isolationModeMarketId), true);
    }

    function _exit(
        DolomiteSupplyFuseExitData memory data_,
        bool catchExceptions_
    ) internal returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            if (data_.minAmountOut > 0) {
                revert DolomiteSupplyFuseWithdrawAmountTooSmall(0, data_.minAmountOut);
            }
            return (data_.asset, 0);
        }

        if (!DolomiteFuseLib.canSupply(MARKET_ID, data_.asset, data_.subAccountId)) {
            revert DolomiteSupplyFuseUnsupportedAsset("exit", data_.asset, data_.subAccountId);
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

        if (!balance.sign || balance.value == 0) {
            if (data_.minAmountOut > 0) {
                revert DolomiteSupplyFuseWithdrawAmountTooSmall(0, data_.minAmountOut);
            }
            return (data_.asset, 0);
        }

        uint256 finalAmount = IporMath.min(balance.value, data_.amount);

        if (finalAmount == 0) {
            if (data_.minAmountOut > 0) {
                revert DolomiteSupplyFuseWithdrawAmountTooSmall(0, data_.minAmountOut);
            }
            return (data_.asset, 0);
        }

        return
            _performWithdraw(
                data_.asset,
                dolomiteMarketId,
                finalAmount,
                data_.minAmountOut,
                data_.subAccountId,
                data_.isolationModeMarketId,
                catchExceptions_
            );
    }

    function _performWithdraw(
        address asset_,
        uint256 dolomiteMarketId_,
        uint256 finalAmount_,
        uint256 minAmountOut_,
        uint8 subAccountId_,
        uint256 isolationModeMarketId_,
        bool catchExceptions_
    ) private returns (address asset, uint256 amount) {
        uint256 balanceBefore = ERC20(asset_).balanceOf(address(this));
        if (catchExceptions_) {
            try
                IDepositWithdrawalRouter(DEPOSIT_WITHDRAWAL_ROUTER).withdrawWei(
                    isolationModeMarketId_,
                    uint256(subAccountId_),
                    dolomiteMarketId_,
                    finalAmount_,
                    IDepositWithdrawalRouter.BalanceCheckFlag.None
                )
            {
                uint256 receivedAmount = _validateMinAmountOut(asset_, balanceBefore, minAmountOut_);
                emit DolomiteSupplyFuseExit(VERSION, asset_, dolomiteMarketId_, receivedAmount, subAccountId_);
                return (asset_, receivedAmount);
            } catch {
                emit DolomiteSupplyFuseExitFailed(VERSION, asset_, dolomiteMarketId_, finalAmount_);
                return (asset_, 0);
            }
        } else {
            IDepositWithdrawalRouter(DEPOSIT_WITHDRAWAL_ROUTER).withdrawWei(
                isolationModeMarketId_,
                uint256(subAccountId_),
                dolomiteMarketId_,
                finalAmount_,
                IDepositWithdrawalRouter.BalanceCheckFlag.None
            );

            uint256 receivedAmount = _validateMinAmountOut(asset_, balanceBefore, minAmountOut_);
            emit DolomiteSupplyFuseExit(VERSION, asset_, dolomiteMarketId_, receivedAmount, subAccountId_);
            return (asset_, receivedAmount);
        }
    }

    function _validateMinAmountOut(
        address asset_,
        uint256 balanceBefore_,
        uint256 minAmountOut_
    ) private view returns (uint256 receivedAmount) {
        uint256 balanceAfter = ERC20(asset_).balanceOf(address(this));
        if (balanceAfter <= balanceBefore_) {
            if (minAmountOut_ > 0) {
                revert DolomiteSupplyFuseWithdrawAmountTooSmall(0, minAmountOut_);
            }
            return 0;
        }

        receivedAmount = balanceAfter - balanceBefore_;

        if (minAmountOut_ > 0 && receivedAmount < minAmountOut_) {
            revert DolomiteSupplyFuseWithdrawAmountTooSmall(receivedAmount, minAmountOut_);
        }
    }
}
