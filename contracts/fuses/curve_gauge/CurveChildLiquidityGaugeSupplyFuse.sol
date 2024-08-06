// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IChildLiquidityGauge} from "./ext/IChildLiquidityGauge.sol";
import {IFuse} from "../IFuse.sol";
import {PlasmaVaultConfigLib} from "./../../libraries/PlasmaVaultConfigLib.sol";

struct CurveChildLiquidityGaugeSupplyFuseEnterData {
    /// Curve gauge
    IChildLiquidityGauge childLiquidityGauge;
    /// @notice LP Token to deposit (stake)
    address lpToken;
    /// @notice Amount of the LP Token to deposit (stake)
    uint256 amount;
}

struct CurveChildLiquidityGaugeSupplyFuseExitData {
    /// Curve gauge
    IChildLiquidityGauge childLiquidityGauge;
    /// @notice LP Token to withdraw (unstake)
    address lpToken;
    /// @notice Amount of the LP Token to withdraw (unstake)
    uint256 amount;
}

contract CurveChildLiquidityGaugeSupplyFuse is IFuse {
    using SafeERC20 for IERC20;

    event CurveChildLiquidityGaugeSupplyFuseEnter(address version, address lpToken, uint256 amount);

    event CurveChildLiquidityGaugeSupplyFuseExit(address version, address lpToken, uint256 amount);

    error CurveChildLiquidityGaugeSupplyFuseUnsupportedGauge(address lpToken);
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
        IChildLiquidityGauge childLiquidityGauge = data_.childLiquidityGauge;
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(data_.childLiquidityGauge))) {
            /// @notice substrate here refers to the staked Curve LP token (Gauge address)
            revert CurveChildLiquidityGaugeSupplyFuseUnsupportedGauge(address(data_.childLiquidityGauge));
        }
        if (data_.amount == 0) {
            revert CurveChildLiquidityGaugeSupplyFuseZeroDepositAmount();
        }
        IERC20(data_.lpToken).forceApprove(address(childLiquidityGauge), data_.amount);
        childLiquidityGauge.deposit(data_.amount, address(this), false);
        emit CurveChildLiquidityGaugeSupplyFuseEnter(VERSION, data_.lpToken, data_.amount);
    }

    function exit(bytes calldata data_) external override {
        _exit(abi.decode(data_, (CurveChildLiquidityGaugeSupplyFuseExitData)));
    }

    /// @dev technical method to generate ABI
    function exit(CurveChildLiquidityGaugeSupplyFuseExitData memory data_) external {
        _exit(data_);
    }

    function _exit(CurveChildLiquidityGaugeSupplyFuseExitData memory data_) internal {
        IChildLiquidityGauge childLiquidityGauge = data_.childLiquidityGauge;
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(data_.childLiquidityGauge))) {
            revert CurveChildLiquidityGaugeSupplyFuseUnsupportedGauge(address(data_.childLiquidityGauge));
        }
        if (data_.amount == 0) {
            revert CurveChildLiquidityGaugeSupplyFuseZeroWithdrawAmount();
        }
        childLiquidityGauge.withdraw(data_.amount, address(this), false);
        emit CurveChildLiquidityGaugeSupplyFuseExit(VERSION, data_.lpToken, data_.amount);
    }
}
