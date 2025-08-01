// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {ILeafGauge} from "./ext/ILeafGauge.sol";
import {VelodromeSubstrateLib, VelodromeSubstrate, VelodromeSubstrateType} from "./VelodrimeLib.sol";

struct VelodromeGaugeFuseEnterData {
    address gaugeAddress;
    uint256 amount;
}

struct VelodromeGaugeFuseExitData {
    address gaugeAddress;
    uint256 amount;
}

contract VelodromeGaugeFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    error VelodromeGaugeFuseUnsupportedGauge(string action, address gaugeAddress);
    error VelodromeGaugeFuseInvalidGauge();
    error VelodromeGaugeFuseInvalidAmount();

    event VelodromeGaugeFuseEnter(address version, address gaugeAddress, uint256 amount);
    event VelodromeGaugeFuseExit(address version, address gaugeAddress, uint256 amount);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(VelodromeGaugeFuseEnterData memory data_) external {
        if (data_.gaugeAddress == address(0)) {
            revert VelodromeGaugeFuseInvalidGauge();
        }

        if (data_.amount == 0) {
            return;
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromeSubstrateLib.substrateToBytes32(
                    VelodromeSubstrate({
                        substrateAddress: data_.gaugeAddress,
                        substrateType: VelodromeSubstrateType.Gauge
                    })
                )
            )
        ) {
            revert VelodromeGaugeFuseUnsupportedGauge("enter", data_.gaugeAddress);
        }

        address stakingToken = ILeafGauge(data_.gaugeAddress).stakingToken();

        uint256 balance = IERC20(stakingToken).balanceOf(address(this));

        uint256 amountToDeposit = data_.amount > balance ? balance : data_.amount;

        if (amountToDeposit == 0) {
            return;
        }

        IERC20(stakingToken).forceApprove(data_.gaugeAddress, amountToDeposit);

        ILeafGauge(data_.gaugeAddress).deposit(amountToDeposit);

        IERC20(stakingToken).forceApprove(data_.gaugeAddress, 0);

        emit VelodromeGaugeFuseEnter(VERSION, data_.gaugeAddress, amountToDeposit);
    }

    function exit(VelodromeGaugeFuseExitData memory data_) external {
        if (data_.gaugeAddress == address(0)) {
            revert VelodromeGaugeFuseInvalidGauge();
        }

        if (data_.amount == 0) {
            revert VelodromeGaugeFuseInvalidAmount();
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromeSubstrateLib.substrateToBytes32(
                    VelodromeSubstrate({
                        substrateAddress: data_.gaugeAddress,
                        substrateType: VelodromeSubstrateType.Gauge
                    })
                )
            )
        ) {
            revert VelodromeGaugeFuseUnsupportedGauge("exit", data_.gaugeAddress);
        }

        uint256 balance = ILeafGauge(data_.gaugeAddress).balanceOf(address(this));

        uint256 amountToWithdraw = data_.amount > balance ? balance : data_.amount;

        if (amountToWithdraw == 0) {
            return;
        }

        ILeafGauge(data_.gaugeAddress).withdraw(amountToWithdraw);

        emit VelodromeGaugeFuseExit(VERSION, data_.gaugeAddress, amountToWithdraw);
    }
}
