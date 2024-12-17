// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../../../contracts/fuses/IFuseCommon.sol";

/// @title MockInnerBalance contract
/// @notice Mock contract to test the inner balance of the contract
contract MockInnerBalance is IFuseCommon {
    uint256 public immutable MARKET_ID;
    address public immutable TOKEN;

    event MockInnerBalance(address token, uint256 amount);

    constructor(uint256 marketId, address token) {
        MARKET_ID = marketId;
        TOKEN = token;
    }

    function enter() external {
        emit MockInnerBalance(TOKEN, ERC20(TOKEN).balanceOf(address(this)));
    }
}
