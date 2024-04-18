// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {PlazmaVaultStorageLib} from "./PlazmaVaultStorageLib.sol";

library FusesLib {
    event FuseAdded(address indexed fuse);
    event FuseRemoved(address indexed fuse);
    event BalanceFuseAdded(uint256 indexed marketId, address indexed fuse);
    event BalanceFuseRemoved(uint256 indexed marketId, address indexed fuse);

    error FuseAlreadyExists();
    error FuseDoesNotExist();
    error BalanceFuseAlreadyExists(uint256 marketId, address fuse);
    error BalanceFuseDoesNotExist(uint256 marketId, address fuse);

    function isFuseSupported(address fuse) internal view returns (bool) {
        return PlazmaVaultStorageLib.getFuses().value[fuse] != 0;
    }

    function getFusesArray() internal view returns (address[] memory) {
        return PlazmaVaultStorageLib.getFusesArray().value;
    }

    function getFuseArrayIndex(address fuse) internal view returns (uint256) {
        return PlazmaVaultStorageLib.getFuses().value[fuse];
    }

    // TODO: add tests for addFuse and removeFuse
    function addFuse(address fuse) internal {
        PlazmaVaultStorageLib.Fuses storage fuses = PlazmaVaultStorageLib.getFuses();

        uint256 keyIndexValue = fuses.value[fuse];

        if (keyIndexValue != 0) {
            revert FuseAlreadyExists();
        }

        uint256 newLastFuseId = PlazmaVaultStorageLib.getFusesArray().value.length + 1;

        /// @dev for balance fuses, value is a index + 1 in the fusesArray
        fuses.value[fuse] = newLastFuseId;

        PlazmaVaultStorageLib.getFusesArray().value.push(fuse);

        emit FuseAdded(fuse);
    }

    function removeFuse(address fuse) internal {
        PlazmaVaultStorageLib.Fuses storage fuses = PlazmaVaultStorageLib.getFuses();

        uint256 indexToRemove = fuses.value[fuse];

        if (indexToRemove == 0) {
            revert FuseDoesNotExist();
        }

        address lastKeyInArray = PlazmaVaultStorageLib.getFusesArray().value[
            PlazmaVaultStorageLib.getFusesArray().value.length - 1
        ];

        fuses.value[lastKeyInArray] = indexToRemove;

        fuses.value[fuse] = 0;

        /// @dev balanceFuses mapping contains values as index + 1
        PlazmaVaultStorageLib.getFusesArray().value[indexToRemove - 1] = lastKeyInArray;

        PlazmaVaultStorageLib.getFusesArray().value.pop();

        emit FuseRemoved(fuse);
    }

    function isBalanceFuseSupported(uint256 marketId, address fuse) internal view returns (bool) {
        return PlazmaVaultStorageLib.getBalanceFuses().value[marketId] == fuse;
    }

    function getBalanceFuse(uint256 marketId) internal view returns (address) {
        return PlazmaVaultStorageLib.getBalanceFuses().value[marketId];
    }

    function addBalanceFuse(uint256 marketId, address fuse) internal {
        address currentFuse = PlazmaVaultStorageLib.getBalanceFuses().value[marketId];

        if (currentFuse == fuse) {
            revert BalanceFuseAlreadyExists(marketId, fuse);
        }

        PlazmaVaultStorageLib.getBalanceFuses().value[marketId] = fuse;

        emit BalanceFuseAdded(marketId, fuse);
    }

    //TODO: add balance fuse array and add tests for that
    function removeBalanceFuse(uint256 marketId, address fuse) internal {
        address currentFuse = PlazmaVaultStorageLib.getBalanceFuses().value[marketId];

        if (currentFuse != fuse) {
            revert BalanceFuseDoesNotExist(marketId, fuse);
        }

        PlazmaVaultStorageLib.getBalanceFuses().value[marketId] = address(0);

        emit BalanceFuseRemoved(marketId, fuse);
    }
}
