// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {FuseStorageLib} from "./FuseStorageLib.sol";
import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";

/// @title Fuses Library responsible for managing fuses in the Plasma Vault
library FusesLib {
    using Address for address;

    event FuseAdded(address fuse);
    event FuseRemoved(address fuse);
    event BalanceFuseAdded(uint256 marketId, address fuse);
    event BalanceFuseRemoved(uint256 marketId, address fuse);

    error FuseAlreadyExists();
    error FuseDoesNotExist();
    error FuseUnsupported(address fuse);
    error BalanceFuseAlreadyExists(uint256 marketId, address fuse);
    error BalanceFuseDoesNotExist(uint256 marketId, address fuse);
    error BalanceFuseNotReadyToRemove(uint256 marketId, address fuse, uint256 currentBalance);

    /// @notice Checks if the fuse is supported
    /// @param fuse_ The address of the fuse
    /// @return true if the fuse is supported
    function isFuseSupported(address fuse_) internal view returns (bool) {
        return FuseStorageLib.getFuses().value[fuse_] != 0;
    }

    /// @notice Checks if the balance fuse is supported
    /// @param marketId_ The market id
    /// @param fuse_ The address of the fuse
    /// @return true if the balance fuse is supported
    function isBalanceFuseSupported(uint256 marketId_, address fuse_) internal view returns (bool) {
        return PlasmaVaultStorageLib.getBalanceFuses().value[marketId_] == fuse_;
    }

    /// @notice Gets the balance fuse for the market
    /// @param marketId_ The market id
    /// @return The address of the balance fuse
    function getBalanceFuse(uint256 marketId_) internal view returns (address) {
        return PlasmaVaultStorageLib.getBalanceFuses().value[marketId_];
    }

    /// @notice Gets the array of stored and supported Fuses
    /// @return The array of Fuses
    function getFusesArray() internal view returns (address[] memory) {
        return FuseStorageLib.getFusesArray().value;
    }

    /// @notice Gets the index of the fuse in the fuses array
    /// @param fuse_ The address of the fuse
    /// @return The index of the fuse in the fuses array stored in Plasma Vault
    function getFuseArrayIndex(address fuse_) internal view returns (uint256) {
        return FuseStorageLib.getFuses().value[fuse_];
    }

    /// @notice Adds a fuse to supported fuses
    /// @param fuse_ The address of the fuse
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
    /// @param fuse_ The address of the fuse
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
    /// @param marketId_ The market id
    /// @param fuse_ The address of the fuse
    /// @dev Every market can have one dedicated balance fuse
    function addBalanceFuse(uint256 marketId_, address fuse_) internal {
        address currentFuse = PlasmaVaultStorageLib.getBalanceFuses().value[marketId_];

        if (currentFuse == fuse_) {
            revert BalanceFuseAlreadyExists(marketId_, fuse_);
        }

        PlasmaVaultStorageLib.getBalanceFuses().value[marketId_] = fuse_;

        emit BalanceFuseAdded(marketId_, fuse_);
    }

    /// @notice Removes a balance fuse from the market
    /// @param marketId_ The market id
    /// @param fuse_ The address of the fuse
    /// @dev Every market can have one dedicated balance fuse
    function removeBalanceFuse(uint256 marketId_, address fuse_) internal {
        address currentBalanceFuse = PlasmaVaultStorageLib.getBalanceFuses().value[marketId_];

        if (currentBalanceFuse != fuse_) {
            revert BalanceFuseDoesNotExist(marketId_, fuse_);
        }

        uint256 wadBalanceAmountInUSD = abi.decode(
            currentBalanceFuse.functionDelegateCall(abi.encodeWithSignature("balanceOf()")),
            (uint256)
        );

        if (wadBalanceAmountInUSD > _calculateAllowedDustInBalanceFuse()) {
            revert BalanceFuseNotReadyToRemove(marketId_, fuse_, wadBalanceAmountInUSD);
        }

        PlasmaVaultStorageLib.getBalanceFuses().value[marketId_] = address(0);

        emit BalanceFuseRemoved(marketId_, fuse_);
    }

    function _calculateAllowedDustInBalanceFuse() private view returns (uint256) {
        return 10 ** (PlasmaVaultStorageLib.getERC4626Storage().underlyingDecimals / 2);
    }
}
