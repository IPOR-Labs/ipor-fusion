// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {ILeafGauge} from "./ext/ILeafGauge.sol";
import {VelodromeSuperchainSubstrateLib, VelodromeSuperchainSubstrate, VelodromeSuperchainSubstrateType} from "./VelodromeSuperchainLib.sol";

struct VelodromeSuperchainGaugeFuseEnterData {
    address gaugeAddress;
    uint256 amount;
    uint256 minAmount;
}

struct VelodromeSuperchainGaugeFuseExitData {
    address gaugeAddress;
    uint256 amount;
    uint256 minAmount;
}

contract VelodromeSuperchainGaugeFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    error VelodromeSuperchainGaugeFuseUnsupportedGauge(string action, address gaugeAddress);
    error VelodromeSuperchainGaugeFuseInvalidGauge();
    error VelodromeSuperchainGaugeFuseInvalidAmount();
    error VelodromeSuperchainGaugeFuseMinAmountNotMet();

    event VelodromeSuperchainGaugeFuseEnter(address version, address gaugeAddress, uint256 amount);
    event VelodromeSuperchainGaugeFuseExit(address version, address gaugeAddress, uint256 amount);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(VelodromeSuperchainGaugeFuseEnterData memory data_) external {
        if (data_.gaugeAddress == address(0)) {
            revert VelodromeSuperchainGaugeFuseInvalidGauge();
        }

        if (data_.amount == 0) {
            return;
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromeSuperchainSubstrateLib.substrateToBytes32(
                    VelodromeSuperchainSubstrate({
                        substrateAddress: data_.gaugeAddress,
                        substrateType: VelodromeSuperchainSubstrateType.Gauge
                    })
                )
            )
        ) {
            revert VelodromeSuperchainGaugeFuseUnsupportedGauge("enter", data_.gaugeAddress);
        }

        address stakingToken = ILeafGauge(data_.gaugeAddress).stakingToken();

        uint256 balance = IERC20(stakingToken).balanceOf(address(this));

        uint256 amountToDeposit = data_.amount > balance ? balance : data_.amount;

        if (amountToDeposit < data_.minAmount) {
            revert VelodromeSuperchainGaugeFuseMinAmountNotMet();
        }

        if (amountToDeposit == 0) {
            return;
        }

        IERC20(stakingToken).forceApprove(data_.gaugeAddress, amountToDeposit);

        ILeafGauge(data_.gaugeAddress).deposit(amountToDeposit);

        IERC20(stakingToken).forceApprove(data_.gaugeAddress, 0);

        emit VelodromeSuperchainGaugeFuseEnter(VERSION, data_.gaugeAddress, amountToDeposit);
    }

    function exit(VelodromeSuperchainGaugeFuseExitData memory data_) external {
        if (data_.gaugeAddress == address(0)) {
            revert VelodromeSuperchainGaugeFuseInvalidGauge();
        }

        if (data_.amount == 0) {
            revert VelodromeSuperchainGaugeFuseInvalidAmount();
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromeSuperchainSubstrateLib.substrateToBytes32(
                    VelodromeSuperchainSubstrate({
                        substrateAddress: data_.gaugeAddress,
                        substrateType: VelodromeSuperchainSubstrateType.Gauge
                    })
                )
            )
        ) {
            revert VelodromeSuperchainGaugeFuseUnsupportedGauge("exit", data_.gaugeAddress);
        }

        uint256 balance = ILeafGauge(data_.gaugeAddress).balanceOf(address(this));

        uint256 amountToWithdraw = data_.amount > balance ? balance : data_.amount;

        if (amountToWithdraw < data_.minAmount) {
            revert VelodromeSuperchainGaugeFuseMinAmountNotMet();
        }

        if (amountToWithdraw == 0) {
            return;
        }

        ILeafGauge(data_.gaugeAddress).withdraw(amountToWithdraw);

        emit VelodromeSuperchainGaugeFuseExit(VERSION, data_.gaugeAddress, amountToWithdraw);
    }
}
