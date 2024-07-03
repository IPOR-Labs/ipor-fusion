// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {FuseStorageLib} from "./FuseStorageLib.sol";
import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";

library FusesLib {
    event FuseAdded(address fuse);
    event FuseRemoved(address fuse);
    event BalanceFuseAdded(uint256 marketId, address fuse);
    event BalanceFuseRemoved(uint256 marketId, address fuse);

    error FuseAlreadyExists();
    error FuseDoesNotExist();
    error FuseUnsupported(address fuse);
    error BalanceFuseAlreadyExists(uint256 marketId, address fuse);
    error BalanceFuseDoesNotExist(uint256 marketId, address fuse);

    /// @notice Checks if the fuse is supported
    function isFuseSupported(address fuse_) internal view returns (bool) {
        return FuseStorageLib.getFuses().value[fuse_] != 0;
    }

    /// @notice Checks if the balance fuse is supported
    function isBalanceFuseSupported(uint256 marketId_, address fuse_) internal view returns (bool) {
        return PlasmaVaultStorageLib.getBalanceFuses().value[marketId_] == fuse_;
    }

    /// @notice Gets the balance fuse for the market
    function getBalanceFuse(uint256 marketId_) internal view returns (address) {
        return PlasmaVaultStorageLib.getBalanceFuses().value[marketId_];
    }

    /// @notice Gets the array of fuses
    function getFusesArray() internal view returns (address[] memory) {
        return FuseStorageLib.getFusesArray().value;
    }

    /// @notice Gets the index of the fuse in the fuses array
    function getFuseArrayIndex(address fuse_) internal view returns (uint256) {
        return FuseStorageLib.getFuses().value[fuse_];
    }

    /// @notice Adds a fuse to supported fuses
    function addFuse(address fuse_) internal {
        FuseStorageLib.Fuses storage fuses = FuseStorageLib.getFuses();

        uint256 keyIndexValue = fuses.value[fuse_];

        if (keyIndexValue != 0) {
            revert FuseAlreadyExists();
        }

        uint256 newLastFuseId = FuseStorageLib.getFusesArray().value.length + 1;

        /// @dev for balance fuses, value is a index + 1 in the fusesArray
        fuses.value[fuse_] = newLastFuseId;

        FuseStorageLib.getFusesArray().value.push(fuse_);

        emit FuseAdded(fuse_);
    }

    /// @notice Removes a fuse from supported fuses
    function removeFuse(address fuse_) internal {
        FuseStorageLib.Fuses storage fuses = FuseStorageLib.getFuses();

        uint256 indexToRemove = fuses.value[fuse_];

        if (indexToRemove == 0) {
            revert FuseDoesNotExist();
        }

        address lastKeyInArray = FuseStorageLib.getFusesArray().value[FuseStorageLib.getFusesArray().value.length - 1];

        fuses.value[lastKeyInArray] = indexToRemove;

        fuses.value[fuse_] = 0;

        /// @dev balanceFuses mapping contains values as index + 1
        FuseStorageLib.getFusesArray().value[indexToRemove - 1] = lastKeyInArray;

        FuseStorageLib.getFusesArray().value.pop();

        emit FuseRemoved(fuse_);
    }


    /// @notice Adds a balance fuse to the market
    function addBalanceFuse(uint256 marketId_, address fuse_) internal {
        address currentFuse = PlasmaVaultStorageLib.getBalanceFuses().value[marketId_];

        if (currentFuse == fuse_) {
            revert BalanceFuseAlreadyExists(marketId_, fuse_);
        }

        PlasmaVaultStorageLib.getBalanceFuses().value[marketId_] = fuse_;

        emit BalanceFuseAdded(marketId_, fuse_);
    }

    /// @notice Removes a balance fuse from the market
    function removeBalanceFuse(uint256 marketId_, address fuse_) internal {
        address currentFuse = PlasmaVaultStorageLib.getBalanceFuses().value[marketId_];

        if (currentFuse != fuse_) {
            revert BalanceFuseDoesNotExist(marketId_, fuse_);
        }

        PlasmaVaultStorageLib.getBalanceFuses().value[marketId_] = address(0);

        emit BalanceFuseRemoved(marketId_, fuse_);
    }
}
