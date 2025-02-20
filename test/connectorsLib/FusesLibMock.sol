// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {FusesLib} from "../../contracts/libraries/FusesLib.sol";
import {PlasmaVaultStorageLib} from "../../contracts/libraries/PlasmaVaultStorageLib.sol";

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

    function getBalanceFusesMarketIds() external view returns (uint256[] memory) {
        PlasmaVaultStorageLib.BalanceFuses storage balanceFuses = PlasmaVaultStorageLib.getBalanceFuses();
        return balanceFuses.marketIds;
    }

    function getBalanceFusesIndexes(uint256 marketId) external view returns (uint256) {
        PlasmaVaultStorageLib.BalanceFuses storage balanceFuses = PlasmaVaultStorageLib.getBalanceFuses();
        return balanceFuses.indexes[marketId];
    }
}
