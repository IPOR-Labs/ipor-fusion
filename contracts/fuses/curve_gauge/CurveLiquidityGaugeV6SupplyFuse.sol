// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILiquidityGaugeV6} from "./ext/ILiquidityGaugeV6.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "./../../libraries/PlasmaVaultConfigLib.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";

/// @notice Data structure for entering the Curve Liquidity Gauge V6 Supply Fuse
/// @dev This struct contains the necessary information for staking LP tokens into an Ethereum mainnet Curve gauge
struct CurveLiquidityGaugeV6SupplyFuseEnterData {
    /// @notice Address of the Curve liquidity gauge (V6)
    address liquidityGauge;
    /// @notice Amount of the LP Token to deposit (stake) into the gauge (18 decimals)
    uint256 lpTokenAmount;
}

/// @notice Data structure for exiting the Curve Liquidity Gauge V6 Supply Fuse
/// @dev This struct contains the necessary information for unstaking LP tokens from an Ethereum mainnet Curve gauge
struct CurveLiquidityGaugeV6SupplyFuseExitData {
    /// @notice Address of the Curve liquidity gauge (V6)
    address liquidityGauge;
    /// @notice Amount of the LP Token to withdraw (unstake) from the gauge (18 decimals)
    uint256 lpTokenAmount;
}

/// @title Supply Fuse for Ethereum mainnet Curve LiquidityGaugeV6
/// @notice Key difference vs CurveChildLiquidityGaugeSupplyFuse: withdraw(uint256, bool) instead of withdraw(uint256, address, bool)
contract CurveLiquidityGaugeV6SupplyFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    event CurveLiquidityGaugeV6SupplyFuseEnter(address version, address liquidityGauge, uint256 amount);
    event CurveLiquidityGaugeV6SupplyFuseExit(address version, address liquidityGauge, uint256 amount);
    event CurveLiquidityGaugeV6SupplyFuseExitFailed(address version, address liquidityGauge, uint256 amount);

    error CurveLiquidityGaugeV6SupplyFuseUnsupportedGauge(address liquidityGauge);
    error CurveLiquidityGaugeV6SupplyFuseInsufficientStakedBalance(
        address gauge,
        uint256 requiredShares,
        uint256 availableShares
    );

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Enters the fuse — stakes LP tokens into the gauge
    /// @param data_ The data for entering the fuse
    /// @return liquidityGauge The address of the gauge
    /// @return lpTokenAmount The amount of LP tokens deposited
    function enter(
        CurveLiquidityGaugeV6SupplyFuseEnterData memory data_
    ) public returns (address liquidityGauge, uint256 lpTokenAmount) {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.liquidityGauge)) {
            revert CurveLiquidityGaugeV6SupplyFuseUnsupportedGauge(data_.liquidityGauge);
        }

        if (data_.lpTokenAmount == 0) {
            return (data_.liquidityGauge, 0);
        }

        address lpToken = ILiquidityGaugeV6(data_.liquidityGauge).lp_token();
        uint256 balanceOfPlasmaVault = IERC20(lpToken).balanceOf(address(this));
        uint256 depositAmount = data_.lpTokenAmount > balanceOfPlasmaVault ? balanceOfPlasmaVault : data_.lpTokenAmount;

        IERC20(lpToken).forceApprove(data_.liquidityGauge, depositAmount);
        ILiquidityGaugeV6(data_.liquidityGauge).deposit(depositAmount, address(this), false);

        emit CurveLiquidityGaugeV6SupplyFuseEnter(VERSION, data_.liquidityGauge, depositAmount);

        return (data_.liquidityGauge, depositAmount);
    }

    /// @notice Enters the fuse using transient storage data
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address liquidityGauge = TypeConversionLib.toAddress(inputs[0]);
        uint256 lpTokenAmount = TypeConversionLib.toUint256(inputs[1]);

        (address liquidityGaugeUsed, uint256 lpTokenAmountUsed) = enter(
            CurveLiquidityGaugeV6SupplyFuseEnterData({
                liquidityGauge: liquidityGauge,
                lpTokenAmount: lpTokenAmount
            })
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(liquidityGaugeUsed);
        outputs[1] = TypeConversionLib.toBytes32(lpTokenAmountUsed);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @dev Could be used only if lpToken is ERC4626.
    /// @dev params[0] - amount in underlying asset, params[1] - gauge address
    /// @notice Uses previewWithdraw instead of convertToShares for withdrawal flows.
    function instantWithdraw(bytes32[] calldata params_) external {
        uint256 amount = uint256(params_[0]);

        if (amount == 0) {
            return;
        }

        address gauge = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);
        address lpToken = ILiquidityGaugeV6(gauge).lp_token();

        uint256 lpTokenToWithdraw = ERC4626Upgradeable(lpToken).previewWithdraw(amount);

        uint256 stakedBalance = IERC20(gauge).balanceOf(address(this));
        if (lpTokenToWithdraw > stakedBalance) {
            revert CurveLiquidityGaugeV6SupplyFuseInsufficientStakedBalance(gauge, lpTokenToWithdraw, stakedBalance);
        }

        _exit(CurveLiquidityGaugeV6SupplyFuseExitData(gauge, lpTokenToWithdraw), true);
    }

    /// @notice Exits the fuse — unstakes LP tokens from the gauge
    /// @param data_ The data for exiting the fuse
    /// @return liquidityGauge The address of the gauge
    /// @return lpTokenAmount The amount of LP tokens withdrawn
    function exit(
        CurveLiquidityGaugeV6SupplyFuseExitData memory data_
    ) public returns (address liquidityGauge, uint256 lpTokenAmount) {
        return _exit(data_, false);
    }

    /// @notice Exits the fuse using transient storage data
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address liquidityGauge = TypeConversionLib.toAddress(inputs[0]);
        uint256 lpTokenAmount = TypeConversionLib.toUint256(inputs[1]);

        (address liquidityGaugeUsed, uint256 lpTokenAmountUsed) = _exit(
            CurveLiquidityGaugeV6SupplyFuseExitData({
                liquidityGauge: liquidityGauge,
                lpTokenAmount: lpTokenAmount
            }),
            false
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(liquidityGaugeUsed);
        outputs[1] = TypeConversionLib.toBytes32(lpTokenAmountUsed);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    function _exit(
        CurveLiquidityGaugeV6SupplyFuseExitData memory data_,
        bool catchExceptions_
    ) internal returns (address liquidityGauge, uint256 lpTokenAmount) {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.liquidityGauge)) {
            revert CurveLiquidityGaugeV6SupplyFuseUnsupportedGauge(data_.liquidityGauge);
        }

        if (data_.lpTokenAmount == 0) {
            return (data_.liquidityGauge, 0);
        }

        uint256 balanceOfPlasmaVault = IERC20(data_.liquidityGauge).balanceOf(address(this));

        uint256 finalAmount = data_.lpTokenAmount > balanceOfPlasmaVault ? balanceOfPlasmaVault : data_.lpTokenAmount;

        if (finalAmount == 0) {
            return (data_.liquidityGauge, 0);
        }

        _performWithdraw(data_.liquidityGauge, finalAmount, catchExceptions_);

        return (data_.liquidityGauge, finalAmount);
    }

    function _performWithdraw(address liquidityGauge_, uint256 finalAmount_, bool catchExceptions_) private {
        if (catchExceptions_) {
            try ILiquidityGaugeV6(liquidityGauge_).withdraw(finalAmount_, false) {
                emit CurveLiquidityGaugeV6SupplyFuseExit(VERSION, liquidityGauge_, finalAmount_);
            } catch {
                emit CurveLiquidityGaugeV6SupplyFuseExitFailed(VERSION, liquidityGauge_, finalAmount_);
            }
        } else {
            ILiquidityGaugeV6(liquidityGauge_).withdraw(finalAmount_, false);
            emit CurveLiquidityGaugeV6SupplyFuseExit(VERSION, liquidityGauge_, finalAmount_);
        }
    }
}
