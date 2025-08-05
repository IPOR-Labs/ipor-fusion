// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IGauge} from "./ext/IGauge.sol";
import {AerodromeSubstrateLib, AerodromeSubstrate, AerodromeSubstrateType} from "./AreodromeLib.sol";

struct AerodromeGaugeFuseEnterData {
    address gaugeAddress;
    uint256 amount;
}

struct AerodromeGaugeFuseExitData {
    address gaugeAddress;
    uint256 amount;
}

contract AerodromeGaugeFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    error AerodromeGaugeFuseUnsupportedGauge(string action, address gaugeAddress);
    error AerodromeGaugeFuseInvalidGauge();
    error AerodromeGaugeFuseInvalidAmount();

    event AerodromeGaugeFuseEnter(address version, address gaugeAddress, uint256 amount);
    event AerodromeGaugeFuseExit(address version, address gaugeAddress, uint256 amount);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(AerodromeGaugeFuseEnterData memory data_) external {
        if (data_.gaugeAddress == address(0)) {
            revert AerodromeGaugeFuseInvalidGauge();
        }

        if (data_.amount == 0) {
            return;
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                AerodromeSubstrateLib.substrateToBytes32(
                    AerodromeSubstrate({
                        substrateAddress: data_.gaugeAddress,
                        substrateType: AerodromeSubstrateType.Gauge
                    })
                )
            )
        ) {
            revert AerodromeGaugeFuseUnsupportedGauge("enter", data_.gaugeAddress);
        }

        address stakingToken = IGauge(data_.gaugeAddress).stakingToken();

        uint256 balance = IERC20(stakingToken).balanceOf(address(this));

        uint256 amountToDeposit = data_.amount > balance ? balance : data_.amount;

        if (amountToDeposit == 0) {
            return;
        }

        IERC20(stakingToken).forceApprove(data_.gaugeAddress, amountToDeposit);

        IGauge(data_.gaugeAddress).deposit(amountToDeposit);

        IERC20(stakingToken).forceApprove(data_.gaugeAddress, 0);

        emit AerodromeGaugeFuseEnter(VERSION, data_.gaugeAddress, amountToDeposit);
    }

    function exit(AerodromeGaugeFuseExitData memory data_) external {
        if (data_.gaugeAddress == address(0)) {
            revert AerodromeGaugeFuseInvalidGauge();
        }

        if (data_.amount == 0) {
            revert AerodromeGaugeFuseInvalidAmount();
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                AerodromeSubstrateLib.substrateToBytes32(
                    AerodromeSubstrate({
                        substrateAddress: data_.gaugeAddress,
                        substrateType: AerodromeSubstrateType.Gauge
                    })
                )
            )
        ) {
            revert AerodromeGaugeFuseUnsupportedGauge("exit", data_.gaugeAddress);
        }

        uint256 balance = IGauge(data_.gaugeAddress).balanceOf(address(this));

        uint256 amountToWithdraw = data_.amount > balance ? balance : data_.amount;

        if (amountToWithdraw == 0) {
            return;
        }

        IGauge(data_.gaugeAddress).withdraw(amountToWithdraw);

        emit AerodromeGaugeFuseExit(VERSION, data_.gaugeAddress, amountToWithdraw);
    }
}
