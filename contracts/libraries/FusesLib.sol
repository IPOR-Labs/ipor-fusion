// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

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

    function isFuseSupported(address fuse) internal view returns (bool) {
        return PlasmaVaultStorageLib.getFuses().value[fuse] != 0;
    }

    function getFusesArray() internal view returns (address[] memory) {
        return PlasmaVaultStorageLib.getFusesArray().value;
    }

    function getFuseArrayIndex(address fuse) internal view returns (uint256) {
        return PlasmaVaultStorageLib.getFuses().value[fuse];
    }

    // TODO: add tests for addFuse and removeFuse
    function addFuse(address fuse) internal {
        PlasmaVaultStorageLib.Fuses storage fuses = PlasmaVaultStorageLib.getFuses();

        uint256 keyIndexValue = fuses.value[fuse];

        if (keyIndexValue != 0) {
            revert FuseAlreadyExists();
        }

        uint256 newLastFuseId = PlasmaVaultStorageLib.getFusesArray().value.length + 1;

        /// @dev for balance fuses, value is a index + 1 in the fusesArray
        fuses.value[fuse] = newLastFuseId;

        PlasmaVaultStorageLib.getFusesArray().value.push(fuse);

        emit FuseAdded(fuse);
    }

    function removeFuse(address fuse) internal {
        PlasmaVaultStorageLib.Fuses storage fuses = PlasmaVaultStorageLib.getFuses();

        uint256 indexToRemove = fuses.value[fuse];

        if (indexToRemove == 0) {
            revert FuseDoesNotExist();
        }

        address lastKeyInArray = PlasmaVaultStorageLib.getFusesArray().value[
            PlasmaVaultStorageLib.getFusesArray().value.length - 1
        ];

        fuses.value[lastKeyInArray] = indexToRemove;

        fuses.value[fuse] = 0;

        /// @dev balanceFuses mapping contains values as index + 1
        PlasmaVaultStorageLib.getFusesArray().value[indexToRemove - 1] = lastKeyInArray;

        PlasmaVaultStorageLib.getFusesArray().value.pop();

        emit FuseRemoved(fuse);
    }

    function isBalanceFuseSupported(uint256 marketId, address fuse) internal view returns (bool) {
        return PlasmaVaultStorageLib.getBalanceFuses().value[marketId] == fuse;
    }

    function getBalanceFuse(uint256 marketId) internal view returns (address) {
        return PlasmaVaultStorageLib.getBalanceFuses().value[marketId];
    }

    function addBalanceFuse(uint256 marketId, address fuse) internal {
        address currentFuse = PlasmaVaultStorageLib.getBalanceFuses().value[marketId];

        if (currentFuse == fuse) {
            revert BalanceFuseAlreadyExists(marketId, fuse);
        }

        PlasmaVaultStorageLib.getBalanceFuses().value[marketId] = fuse;

        emit BalanceFuseAdded(marketId, fuse);
    }

    //TODO: add balance fuse array and add tests for that
    function removeBalanceFuse(uint256 marketId, address fuse) internal {
        address currentFuse = PlasmaVaultStorageLib.getBalanceFuses().value[marketId];

        if (currentFuse != fuse) {
            revert BalanceFuseDoesNotExist(marketId, fuse);
        }

        PlasmaVaultStorageLib.getBalanceFuses().value[marketId] = address(0);

        emit BalanceFuseRemoved(marketId, fuse);
    }
}
