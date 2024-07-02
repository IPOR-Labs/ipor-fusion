// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";

library FusesLib {
    event FuseAdded(address indexed fuse);
    event FuseRemoved(address indexed fuse);
    event BalanceFuseAdded(uint256 indexed marketId, address indexed fuse);
    event BalanceFuseRemoved(uint256 indexed marketId, address indexed fuse);

    error FuseAlreadyExists();
    error FuseDoesNotExist();
    error FuseUnsupported(address fuse);
    error BalanceFuseAlreadyExists(uint256 marketId, address fuse);
    error BalanceFuseDoesNotExist(uint256 marketId, address fuse);

    function isFuseSupported(address fuse_) internal view returns (bool) {
        return PlasmaVaultStorageLib.getFuses().value[fuse_] != 0;
    }

    function getFusesArray() internal view returns (address[] memory) {
        return PlasmaVaultStorageLib.getFusesArray().value;
    }

    function getFuseArrayIndex(address fuse_) internal view returns (uint256) {
        return PlasmaVaultStorageLib.getFuses().value[fuse_];
    }

    function addFuse(address fuse_) internal {
        PlasmaVaultStorageLib.Fuses storage fuses = PlasmaVaultStorageLib.getFuses();

        uint256 keyIndexValue = fuses.value[fuse_];

        if (keyIndexValue != 0) {
            revert FuseAlreadyExists();
        }

        uint256 newLastFuseId = PlasmaVaultStorageLib.getFusesArray().value.length + 1;

        /// @dev for balance fuses, value is a index + 1 in the fusesArray
        fuses.value[fuse_] = newLastFuseId;

        PlasmaVaultStorageLib.getFusesArray().value.push(fuse_);

        emit FuseAdded(fuse_);
    }

    function removeFuse(address fuse_) internal {
        PlasmaVaultStorageLib.Fuses storage fuses = PlasmaVaultStorageLib.getFuses();

        uint256 indexToRemove = fuses.value[fuse_];

        if (indexToRemove == 0) {
            revert FuseDoesNotExist();
        }

        address lastKeyInArray = PlasmaVaultStorageLib.getFusesArray().value[
            PlasmaVaultStorageLib.getFusesArray().value.length - 1
        ];

        fuses.value[lastKeyInArray] = indexToRemove;

        fuses.value[fuse_] = 0;

        /// @dev balanceFuses mapping contains values as index + 1
        PlasmaVaultStorageLib.getFusesArray().value[indexToRemove - 1] = lastKeyInArray;

        PlasmaVaultStorageLib.getFusesArray().value.pop();

        emit FuseRemoved(fuse_);
    }

    function isBalanceFuseSupported(uint256 marketId_, address fuse_) internal view returns (bool) {
        return PlasmaVaultStorageLib.getBalanceFuses().value[marketId_] == fuse_;
    }

    function getBalanceFuse(uint256 marketId_) internal view returns (address) {
        return PlasmaVaultStorageLib.getBalanceFuses().value[marketId_];
    }

    function addBalanceFuse(uint256 marketId_, address fuse_) internal {
        address currentFuse = PlasmaVaultStorageLib.getBalanceFuses().value[marketId_];

        if (currentFuse == fuse_) {
            revert BalanceFuseAlreadyExists(marketId_, fuse_);
        }

        PlasmaVaultStorageLib.getBalanceFuses().value[marketId_] = fuse_;

        emit BalanceFuseAdded(marketId_, fuse_);
    }

    function removeBalanceFuse(uint256 marketId_, address fuse_) internal {
        address currentFuse = PlasmaVaultStorageLib.getBalanceFuses().value[marketId_];

        if (currentFuse != fuse_) {
            revert BalanceFuseDoesNotExist(marketId_, fuse_);
        }

        PlasmaVaultStorageLib.getBalanceFuses().value[marketId_] = address(0);

        emit BalanceFuseRemoved(marketId_, fuse_);
    }
}
