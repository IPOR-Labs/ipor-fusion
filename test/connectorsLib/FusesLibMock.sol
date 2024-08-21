// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {FusesLib} from "../../contracts/libraries/FusesLib.sol";

contract FusesLibMock {
    function isFuseSupported(address fuse) external view returns (bool) {
        return FusesLib.isFuseSupported(fuse);
    }

    function addFuse(address fuse) external {
        FusesLib.addFuse(fuse);
    }

    function removeFuse(address fuse) external {
        FusesLib.removeFuse(fuse);
    }

    function isBalanceFuseSupported(uint256 marketId, address fuse) external view returns (bool) {
        return FusesLib.isBalanceFuseSupported(marketId, fuse);
    }

    function addBalanceFuse(uint256 marketId, address fuse) external {
        FusesLib.addBalanceFuse(marketId, fuse);
    }

    function removeBalanceFuse(uint256 marketId, address fuse) external {
        FusesLib.removeBalanceFuse(marketId, fuse);
    }

    function getFusesArray() external view returns (address[] memory) {
        return FusesLib.getFusesArray();
    }

    function getFuseArrayIndex(address fuse) external view returns (uint256) {
        return FusesLib.getFuseArrayIndex(fuse);
    }
}
