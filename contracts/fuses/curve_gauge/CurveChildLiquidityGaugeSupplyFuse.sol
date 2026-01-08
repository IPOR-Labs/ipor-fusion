// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IChildLiquidityGauge} from "./ext/IChildLiquidityGauge.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "./../../libraries/PlasmaVaultConfigLib.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";

/// @notice Data structure for entering the Curve Child Liquidity Gauge Supply Fuse
/// @dev This struct contains the necessary information for staking LP tokens into a Curve gauge
struct CurveChildLiquidityGaugeSupplyFuseEnterData {
    /// @notice Address of the Curve child liquidity gauge
    address childLiquidityGauge;
    /// @notice Amount of the LP Token to deposit (stake) into the gauge (18 decimals)
    uint256 lpTokenAmount;
}

/// @notice Data structure for exiting the Curve Child Liquidity Gauge Supply Fuse
/// @dev This struct contains the necessary information for unstaking LP tokens from a Curve gauge
struct CurveChildLiquidityGaugeSupplyFuseExitData {
    /// @notice Address of the Curve child liquidity gauge
    address childLiquidityGauge;
    /// @notice Amount of the LP Token to withdraw (unstake) from the gauge (18 decimals)
    uint256 lpTokenAmount;
}

contract CurveChildLiquidityGaugeSupplyFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    event CurveChildLiquidityGaugeSupplyFuseEnter(address version, address childLiquidityGauge, uint256 amount);
    event CurveChildLiquidityGaugeSupplyFuseExit(address version, address childLiquidityGauge, uint256 amount);
    event CurveChildLiquidityGaugeSupplyFuseExitFailed(address version, address childLiquidityGauge, uint256 amount);

    error CurveChildLiquidityGaugeSupplyFuseUnsupportedGauge(address childLiquidityGauge);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Enters the fuse
    /// @param data_ The data for entering the fuse
    /// @return childLiquidityGauge The address of the gauge
    /// @return lpTokenAmount The amount of LP tokens deposited
    function enter(
        CurveChildLiquidityGaugeSupplyFuseEnterData memory data_
    ) public returns (address childLiquidityGauge, uint256 lpTokenAmount) {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.childLiquidityGauge)) {
            /// @notice substrate here refers to the staked Curve LP token (Gauge address)
            revert CurveChildLiquidityGaugeSupplyFuseUnsupportedGauge(data_.childLiquidityGauge);
        }

        if (data_.lpTokenAmount == 0) {
            return (data_.childLiquidityGauge, 0);
        }

        address lpToken = IChildLiquidityGauge(data_.childLiquidityGauge).lp_token();
        uint256 balanceOfPlasmaVault = IERC20(lpToken).balanceOf(address(this));
        uint256 depositAmount = data_.lpTokenAmount > balanceOfPlasmaVault ? balanceOfPlasmaVault : data_.lpTokenAmount;

        IERC20(lpToken).forceApprove(data_.childLiquidityGauge, depositAmount);
        IChildLiquidityGauge(data_.childLiquidityGauge).deposit(depositAmount, address(this), false);

        emit CurveChildLiquidityGaugeSupplyFuseEnter(VERSION, data_.childLiquidityGauge, depositAmount);

        return (data_.childLiquidityGauge, depositAmount);
    }

    /// @notice Enters the fuse using transient storage data
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address childLiquidityGauge = TypeConversionLib.toAddress(inputs[0]);
        uint256 lpTokenAmount = TypeConversionLib.toUint256(inputs[1]);

        (address childLiquidityGaugeUsed, uint256 lpTokenAmountUsed) = enter(
            CurveChildLiquidityGaugeSupplyFuseEnterData({
                childLiquidityGauge: childLiquidityGauge,
                lpTokenAmount: lpTokenAmount
            })
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(childLiquidityGaugeUsed);
        outputs[1] = TypeConversionLib.toBytes32(lpTokenAmountUsed);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @dev Could be used only if lpToken is ERC4626.
    /// @dev params[0] - amount in underlying asset, params[1] - vault address
    function instantWithdraw(bytes32[] calldata params_) external {
        uint256 amount = uint256(params_[0]);

        address gauge = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);
        address lpToken = IChildLiquidityGauge(gauge).lp_token();
        uint256 lpTokenToWithdraw = ERC4626Upgradeable(lpToken).convertToShares(amount);

        _exit(CurveChildLiquidityGaugeSupplyFuseExitData(gauge, lpTokenToWithdraw), true);
    }

    /// @notice Exits the fuse
    /// @param data_ The data for exiting the fuse
    /// @return childLiquidityGauge The address of the gauge
    /// @return lpTokenAmount The amount of LP tokens withdrawn
    function exit(
        CurveChildLiquidityGaugeSupplyFuseExitData memory data_
    ) public returns (address childLiquidityGauge, uint256 lpTokenAmount) {
        return _exit(data_, false);
    }

    /// @notice Exits the fuse using transient storage data
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address childLiquidityGauge = TypeConversionLib.toAddress(inputs[0]);
        uint256 lpTokenAmount = TypeConversionLib.toUint256(inputs[1]);

        (address childLiquidityGaugeUsed, uint256 lpTokenAmountUsed) = _exit(
            CurveChildLiquidityGaugeSupplyFuseExitData({
                childLiquidityGauge: childLiquidityGauge,
                lpTokenAmount: lpTokenAmount
            }),
            false
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(childLiquidityGaugeUsed);
        outputs[1] = TypeConversionLib.toBytes32(lpTokenAmountUsed);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    function _exit(
        CurveChildLiquidityGaugeSupplyFuseExitData memory data_,
        bool catchExceptions_
    ) internal returns (address childLiquidityGauge, uint256 lpTokenAmount) {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.childLiquidityGauge)) {
            revert CurveChildLiquidityGaugeSupplyFuseUnsupportedGauge(data_.childLiquidityGauge);
        }

        if (data_.lpTokenAmount == 0) {
            return (data_.childLiquidityGauge, 0);
        }

        uint256 balanceOfPlasmaVault = IERC20(data_.childLiquidityGauge).balanceOf(address(this));

        uint256 finalAmount = data_.lpTokenAmount > balanceOfPlasmaVault ? balanceOfPlasmaVault : data_.lpTokenAmount;

        if (finalAmount == 0) {
            return (data_.childLiquidityGauge, 0);
        }

        _performWithdraw(data_.childLiquidityGauge, finalAmount, catchExceptions_);

        return (data_.childLiquidityGauge, finalAmount);
    }

    function _performWithdraw(address childLiquidityGauge_, uint256 finalAmount_, bool catchExceptions_) private {
        if (catchExceptions_) {
            try IChildLiquidityGauge(childLiquidityGauge_).withdraw(finalAmount_, address(this), false) {
                emit CurveChildLiquidityGaugeSupplyFuseExit(VERSION, childLiquidityGauge_, finalAmount_);
            } catch {
                /// @dev if withdraw failed, continue with the next step
                emit CurveChildLiquidityGaugeSupplyFuseExitFailed(VERSION, childLiquidityGauge_, finalAmount_);
            }
        } else {
            IChildLiquidityGauge(childLiquidityGauge_).withdraw(finalAmount_, address(this), false);
            emit CurveChildLiquidityGaugeSupplyFuseExit(VERSION, childLiquidityGauge_, finalAmount_);
        }
    }
}
