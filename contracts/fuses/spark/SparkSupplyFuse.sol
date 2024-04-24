// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFuse} from "../IFuse.sol";

import {ISavingsDai} from "./ISavingsDai.sol";

struct SparkSupplyFuseEnterData {
    /// @dev amount od DAI to supply
    uint256 amount;
}

struct SparkSupplyFuseExitData {
    /// @dev  amount of DAI to withdraw
    uint256 amount;
}

contract SparkSupplyFuse is IFuse {
    uint256 public immutable MARKET_ID;
    address public immutable VERSION;
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;

    event SparkSupplyEnterFuse(address version, uint256 amount);
    event SparkSupplyExitFuse(address version, uint256 amount);

    error SpSupplyFuseUnsupportedVault(string action, address asset, string errorCode);

    constructor(uint256 marketIdInput) {
        MARKET_ID = marketIdInput;
        VERSION = address(this);
    }

    function enter(bytes calldata data) external {
        _enter(abi.decode(data, (SparkSupplyFuseEnterData)));
    }

    function enter(SparkSupplyFuseEnterData memory data) external {
        _enter(data);
    }

    function _enter(SparkSupplyFuseEnterData memory data) internal {
        IERC20(DAI).approve(SDAI, data.amount);
        ISavingsDai(SDAI).deposit(data.amount, address(this));

        emit SparkSupplyEnterFuse(VERSION, data.amount);
    }

    function exit(bytes calldata data) external {
        _exit(abi.decode(data, (SparkSupplyFuseExitData)));
    }

    function exit(SparkSupplyFuseExitData calldata data) external {
        _exit(data);
    }

    function _exit(SparkSupplyFuseExitData memory data) internal {
        ISavingsDai(SDAI).withdraw(data.amount, address(this), address(this));
        emit SparkSupplyExitFuse(VERSION, data.amount);
    }
}
