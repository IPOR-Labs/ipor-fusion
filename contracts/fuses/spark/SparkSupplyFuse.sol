// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFuseCommon} from "../IFuseCommon.sol";

import {ISavingsDai} from "./ext/ISavingsDai.sol";

/// @notice Structure for entering (supply) to the Spark protocol
struct SparkSupplyFuseEnterData {
    /// @dev amount od DAI to supply
    uint256 amount;
}

/// @notice Structure for exiting (withdraw) from the Spark protocol
struct SparkSupplyFuseExitData {
    /// @dev  amount of DAI to withdraw
    uint256 amount;
}

/// @title Fuse Spark Supply protocol responsible for supplying and withdrawing assets from the Spark protocol
contract SparkSupplyFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event SparkSupplyFuseEnter(address version, uint256 amount);
    event SparkSupplyFuseExit(address version, uint256 amount);
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
        ISavingsDai(SDAI).deposit(data.amount, address(this));

        emit SparkSupplyFuseEnter(VERSION, data.amount);
    }

    function exit(SparkSupplyFuseExitData calldata data) external {
        if (data.amount == 0) {
            return;
        }

        ISavingsDai(SDAI).withdraw(data.amount, address(this), address(this));

        emit SparkSupplyFuseExit(VERSION, data.amount);
    }
}
