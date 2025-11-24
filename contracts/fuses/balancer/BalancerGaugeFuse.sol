// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {BalancerSubstrateLib, BalancerSubstrateType, BalancerSubstrate} from "./BalancerSubstrateLib.sol";
import {ILiquidityGauge} from "./ext/ILiquidityGauge.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

struct BalancerGaugeFuseEnterData {
    address gaugeAddress;
    uint256 bptAmount;
    uint256 minBptAmount;
}

struct BalancerGaugeFuseExitData {
    address gaugeAddress;
    uint256 bptAmount;
    uint256 minBptAmount;
}

contract BalancerGaugeFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    error BalancerGaugeFuseUnsupportedGauge(address gaugeAddress);
    error BalancerGaugeFuseInsufficientBptAmount(address gaugeAddress, uint256 bptAmount, uint256 minBptAmount);

    event BalancerGaugeFuseEnter(address version, address gaugeAddress, uint256 bptAmount);
    event BalancerGaugeFuseExit(address version, address gaugeAddress, uint256 bptAmount);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(BalancerGaugeFuseEnterData calldata data_) external {
        if (data_.bptAmount == 0) {
            return;
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                BalancerSubstrateLib.substrateToBytes32(
                    BalancerSubstrate({
                        substrateType: BalancerSubstrateType.GAUGE,
                        substrateAddress: data_.gaugeAddress
                    })
                )
            )
        ) {
            revert BalancerGaugeFuseUnsupportedGauge(data_.gaugeAddress);
        }
        address lpToken = ILiquidityGauge(data_.gaugeAddress).lp_token();
        uint256 balanceOfPlasmaVault = IERC20(lpToken).balanceOf(address(this));

        uint256 depositAmount = data_.bptAmount > balanceOfPlasmaVault ? balanceOfPlasmaVault : data_.bptAmount;

        if (depositAmount < data_.minBptAmount) {
            revert BalancerGaugeFuseInsufficientBptAmount(data_.gaugeAddress, data_.bptAmount, data_.minBptAmount);
        }

        IERC20(lpToken).forceApprove(data_.gaugeAddress, depositAmount);
        ILiquidityGauge(data_.gaugeAddress).deposit(depositAmount, address(this), false);

        emit BalancerGaugeFuseEnter(VERSION, data_.gaugeAddress, data_.bptAmount);
    }

    function exit(BalancerGaugeFuseExitData calldata data_) external {
        if (data_.bptAmount == 0) {
            return;
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                BalancerSubstrateLib.substrateToBytes32(
                    BalancerSubstrate({
                        substrateType: BalancerSubstrateType.GAUGE,
                        substrateAddress: data_.gaugeAddress
                    })
                )
            )
        ) {
            revert BalancerGaugeFuseUnsupportedGauge(data_.gaugeAddress);
        }

        uint256 balanceOfPlasmaVault = IERC20(data_.gaugeAddress).balanceOf(address(this));

        uint256 withdrawAmount = data_.bptAmount > balanceOfPlasmaVault ? balanceOfPlasmaVault : data_.bptAmount;

        if (withdrawAmount < data_.minBptAmount) {
            revert BalancerGaugeFuseInsufficientBptAmount(data_.gaugeAddress, data_.bptAmount, data_.minBptAmount);
        }

        ILiquidityGauge(data_.gaugeAddress).withdraw(withdrawAmount, false);

        emit BalancerGaugeFuseExit(VERSION, data_.gaugeAddress, withdrawAmount);
    }
}
