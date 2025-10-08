// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../../../contracts/fuses/IFuseCommon.sol";

/// @title EmptyFuse
/// @dev Empty fuse template with enter and exit functions
contract EmptyFuse is IFuseCommon {
    /// @notice Version of this contract for tracking
    address public immutable VERSION;

    /// @notice Market ID this fuse is associated with
    uint256 public immutable MARKET_ID;

    event EmptyFuseEnter(address version);
    event EmptyFuseExit(address version);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter() external {
        emit EmptyFuseEnter(VERSION);
    }

    function exit() external {
        emit EmptyFuseExit(VERSION);
    }
}
