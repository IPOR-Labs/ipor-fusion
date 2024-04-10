// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IFuse} from "../../contracts/fuses/IFuse.sol";

contract DoNothingFuse is IFuse {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    struct DoNothingFuseEnterData {
        // token to supply
        address asset;
    }

    struct DoNothingFuseExitData {
        // token to supply
        address asset;
    }

    event DoNothingEnterFuse(address version, address asset);
    event DoNothingExitFuse(address version, address asset);

    constructor(uint256 marketIdInput) {
        MARKET_ID = marketIdInput;
        VERSION = address(this);
    }

    function enter(bytes calldata data) external {
        return _enter(abi.decode(data, (DoNothingFuseEnterData)));
    }

    function enter(DoNothingFuseEnterData memory data) external {
        return _enter(data);
    }

    function _enter(DoNothingFuseEnterData memory data) internal {
        emit DoNothingEnterFuse(VERSION, data.asset);
    }

    function exit(bytes calldata data) external {
        return _exit(abi.decode(data, (DoNothingFuseExitData)));
    }

    function exit(DoNothingFuseExitData calldata data) external {
        return _exit(data);
    }

    function _exit(DoNothingFuseExitData memory data) internal {
        emit DoNothingExitFuse(VERSION, data.asset);
    }
}
