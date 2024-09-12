// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IChildLiquidityGauge} from "./ext/IChildLiquidityGauge.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "./../../libraries/PlasmaVaultConfigLib.sol";

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

    error CurveChildLiquidityGaugeSupplyFuseUnsupportedGauge(address childLiquidityGauge);
    error CurveChildLiquidityGaugeSupplyFuseZeroDepositAmount();
    error CurveChildLiquidityGaugeSupplyFuseZeroWithdrawAmount();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @dev technical method to generate ABI
    function enter(CurveChildLiquidityGaugeSupplyFuseEnterData memory data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.childLiquidityGauge)) {
            /// @notice substrate here refers to the staked Curve LP token (Gauge address)
            revert CurveChildLiquidityGaugeSupplyFuseUnsupportedGauge(data_.childLiquidityGauge);
        }
        if (data_.lpTokenAmount == 0) {
            revert CurveChildLiquidityGaugeSupplyFuseZeroDepositAmount();
        }
        address lpToken = IChildLiquidityGauge(data_.childLiquidityGauge).lp_token();
        uint256 balanceOfPlasmaVault = IERC20(lpToken).balanceOf(address(this));
        uint256 depositAmount = data_.lpTokenAmount > balanceOfPlasmaVault ? balanceOfPlasmaVault : data_.lpTokenAmount;
        IERC20(lpToken).forceApprove(data_.childLiquidityGauge, depositAmount);
        IChildLiquidityGauge(data_.childLiquidityGauge).deposit(depositAmount, address(this), false);
        emit CurveChildLiquidityGaugeSupplyFuseEnter(VERSION, data_.childLiquidityGauge, depositAmount);
    }

    /// @dev technical method to generate ABI
    function exit(CurveChildLiquidityGaugeSupplyFuseExitData memory data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.childLiquidityGauge)) {
            revert CurveChildLiquidityGaugeSupplyFuseUnsupportedGauge(data_.childLiquidityGauge);
        }
        if (data_.lpTokenAmount == 0) {
            revert CurveChildLiquidityGaugeSupplyFuseZeroWithdrawAmount();
        }
        uint256 balanceOfPlasmaVault = IERC20(data_.childLiquidityGauge).balanceOf(address(this));
        uint256 withdrawAmount = data_.lpTokenAmount > balanceOfPlasmaVault
            ? balanceOfPlasmaVault
            : data_.lpTokenAmount;
        IChildLiquidityGauge(data_.childLiquidityGauge).withdraw(withdrawAmount, address(this), false);
        emit CurveChildLiquidityGaugeSupplyFuseExit(VERSION, data_.childLiquidityGauge, withdrawAmount);
    }
}
