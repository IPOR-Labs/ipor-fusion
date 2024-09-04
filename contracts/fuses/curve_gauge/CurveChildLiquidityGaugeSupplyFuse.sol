// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IChildLiquidityGauge} from "./ext/IChildLiquidityGauge.sol";
import {IFuse} from "../IFuse.sol";
import {PlasmaVaultConfigLib} from "./../../libraries/PlasmaVaultConfigLib.sol";

struct CurveChildLiquidityGaugeSupplyFuseEnterData {
    /// Curve gauge
    address childLiquidityGauge;
    /// @notice Amount of the LP Token to deposit (stake)
    uint256 amount;
}

struct CurveChildLiquidityGaugeSupplyFuseExitData {
    /// Curve gauge
    address childLiquidityGauge;
    /// @notice Amount of the LP Token to withdraw (unstake)
    uint256 amount;
}

contract CurveChildLiquidityGaugeSupplyFuse is IFuse {
    using SafeERC20 for IERC20;

    event CurveChildLiquidityGaugeSupplyFuseEnter(address version, address childLiquidityGauge, uint256 amount);

    event CurveChildLiquidityGaugeSupplyFuseExit(address version, address childLiquidityGauge, uint256 amount);

    error CurveChildLiquidityGaugeSupplyFuseUnsupportedGauge(address childLiquidityGauge);
    error CurveChildLiquidityGaugeSupplyFuseZeroDepositAmount();
    error CurveChildLiquidityGaugeSupplyFuseZeroWithdrawAmount();

    uint256 public immutable MARKET_ID;
    address public immutable VERSION;

    constructor(uint256 marketIdInput) {
        VERSION = address(this);
        MARKET_ID = marketIdInput;
    }

    function enter(bytes calldata data_) external override {
        _enter(abi.decode(data_, (CurveChildLiquidityGaugeSupplyFuseEnterData)));
    }

    /// @dev technical method to generate ABI
    function enter(CurveChildLiquidityGaugeSupplyFuseEnterData memory data_) external {
        _enter(data_);
    }

    function _enter(CurveChildLiquidityGaugeSupplyFuseEnterData memory data_) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.childLiquidityGauge)) {
            /// @notice substrate here refers to the staked Curve LP token (Gauge address)
            revert CurveChildLiquidityGaugeSupplyFuseUnsupportedGauge(data_.childLiquidityGauge);
        }
        if (data_.amount == 0) {
            revert CurveChildLiquidityGaugeSupplyFuseZeroDepositAmount();
        }
        uint256 balanceOfPlasmaVault = IERC20(IChildLiquidityGauge(data_.childLiquidityGauge).lp_token()).balanceOf(
            address(this)
        );
        uint256 depositAmount = data_.amount > balanceOfPlasmaVault ? balanceOfPlasmaVault : data_.amount;
        IERC20(IChildLiquidityGauge(data_.childLiquidityGauge).lp_token()).forceApprove(
            data_.childLiquidityGauge,
            depositAmount
        );
        IChildLiquidityGauge(data_.childLiquidityGauge).deposit(depositAmount, address(this), false);
        emit CurveChildLiquidityGaugeSupplyFuseEnter(VERSION, data_.childLiquidityGauge, depositAmount);
    }

    function exit(bytes calldata data_) external override {
        _exit(abi.decode(data_, (CurveChildLiquidityGaugeSupplyFuseExitData)));
    }

    /// @dev technical method to generate ABI
    function exit(CurveChildLiquidityGaugeSupplyFuseExitData memory data_) external {
        _exit(data_);
    }

    function _exit(CurveChildLiquidityGaugeSupplyFuseExitData memory data_) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.childLiquidityGauge)) {
            revert CurveChildLiquidityGaugeSupplyFuseUnsupportedGauge(data_.childLiquidityGauge);
        }
        if (data_.amount == 0) {
            revert CurveChildLiquidityGaugeSupplyFuseZeroWithdrawAmount();
        }
        uint256 balanceOfPlasmaVault = IERC20(data_.childLiquidityGauge).balanceOf(address(this));
        uint256 withdrawAmount = data_.amount > balanceOfPlasmaVault ? balanceOfPlasmaVault : data_.amount;
        IChildLiquidityGauge(data_.childLiquidityGauge).withdraw(withdrawAmount, address(this), false);
        emit CurveChildLiquidityGaugeSupplyFuseExit(VERSION, data_.childLiquidityGauge, withdrawAmount);
    }
}
