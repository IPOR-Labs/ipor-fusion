// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFuseCommon} from "../../../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../../../IFuseInstantWithdraw.sol";

import {ISavingsDai} from "./ext/ISavingsDai.sol";

import {IporMath} from "../../../../libraries/math/IporMath.sol";

/// @notice Structure for entering (supply) to the Spark protocol
struct SparkSupplyFuseEnterData {
    /// @dev amount of DAI to supply / deposit
    uint256 amount;
}

/// @notice Structure for exiting (withdraw) from the Spark protocol
struct SparkSupplyFuseExitData {
    /// @dev  amount of DAI to withdraw
    uint256 amount;
}

/// @title Fuse Spark Supply protocol responsible for supplying and withdrawing assets from the Spark protocol
contract SparkSupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeERC20 for ERC20;

    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event SparkSupplyFuseEnter(address version, uint256 amount, uint256 shares);
    event SparkSupplyFuseExit(address version, uint256 amount, uint256 shares);
    event SparkSupplyFuseExitFailed(address version, uint256 amount);

    constructor(uint256 marketIdInput) {
        VERSION = address(this);
        MARKET_ID = marketIdInput;
    }

    function enter(SparkSupplyFuseEnterData memory data) external {
        if (data.amount == 0) {
            return;
        }
        ERC20(DAI).forceApprove(SDAI, data.amount);
        uint256 shares = ISavingsDai(SDAI).deposit(data.amount, address(this));

        emit SparkSupplyFuseEnter(VERSION, data.amount, shares);
    }

    function exit(SparkSupplyFuseExitData calldata data) external {
        _exit(data);
    }

    /// @dev params[0] - amount in underlying asset
    function instantWithdraw(bytes32[] calldata params_) external override {
        _exit(SparkSupplyFuseExitData({amount: uint256(params_[0])}));
    }

    function _exit(SparkSupplyFuseExitData memory data_) private {
        if (data_.amount == 0) {
            return;
        }

        uint256 finalAmount = IporMath.min(data_.amount, ISavingsDai(SDAI).maxWithdraw(address(this)));

        if (finalAmount == 0) {
            return;
        }

        try ISavingsDai(SDAI).withdraw(finalAmount, address(this), address(this)) returns (uint256 shares) {
            emit SparkSupplyFuseExit(VERSION, data_.amount, shares);
        } catch {
            /// @dev if withdraw failed, continue with the next step
            emit SparkSupplyFuseExitFailed(VERSION, finalAmount);
        }
    }
}
