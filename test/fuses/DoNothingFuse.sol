// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IFuse} from "../../contracts/fuses/IFuse.sol";

contract DoNothingFuse is IFuse {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    struct DoNothingFuseData {
        // token to supply
        address asset;
    }

    event DoNothingFuse(address version, string action, address asset);

    constructor(uint256 marketIdInput) {
        MARKET_ID = marketIdInput;
        VERSION = address(this);
    }

    function enter(bytes calldata data) external {
        DoNothingFuseData memory structData = abi.decode(data, (DoNothingFuseData));
        return _enter(structData);
    }

    function enter(DoNothingFuseData memory data) external {
        return _enter(data);
    }

    function _enter(DoNothingFuseData memory data) internal {
        emit DoNothingFuse(VERSION, "enter", data.asset);
    }

    function exit(bytes calldata data) external {
        DoNothingFuseData memory data = abi.decode(data, (DoNothingFuseData));
        return _exit(data);
    }

    function exit(DoNothingFuseData calldata data) external {
        return _exit(data);
    }

    function _exit(DoNothingFuseData memory data) internal {
        emit DoNothingFuse(VERSION, "exit", data.asset);
    }
}
