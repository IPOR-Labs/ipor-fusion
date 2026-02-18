// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {IporFusionMarkets} from "../../libraries/IporFusionMarkets.sol";
import {TransientStorageLib, TransientStorageParamTypes} from "../../transient_storage/TransientStorageLib.sol";

/// @dev Struct defining a single split route
struct TransientStorageSplitterRoute {
    /// @notice The address of the destination fuse to write the split amount to
    address destinationFuse;
    /// @notice The index in the destination fuse's inputs array
    uint256 destinationIndex;
    /// @notice The proportion numerator for this route
    uint256 numerator;
}

/// @dev Struct for passing data to the enter function
struct TransientStorageSplitterFuseEnterData {
    /// @notice The type of parameter to read the source amount from (INPUTS_BY_FUSE or OUTPUTS_BY_FUSE)
    TransientStorageParamTypes sourceParamType;
    /// @notice The address of the fuse to read the total amount from
    address sourceAddress;
    /// @notice The index in the source fuse's storage
    uint256 sourceIndex;
    /// @notice The common denominator for all proportions
    uint256 denominator;
    /// @notice Array of routes defining where to write each split amount
    TransientStorageSplitterRoute[] routes;
}

/// @title TransientStorageSplitterFuse
/// @notice Fuse for splitting a total amount from transient storage into proportional parts across multiple destination fuses
/// @author IPOR Labs
contract TransientStorageSplitterFuse is IFuseCommon {
    /// @notice The market ID associated with the Fuse
    uint256 public constant MARKET_ID = IporFusionMarkets.ZERO_BALANCE_MARKET;
    /// @notice The version identifier of this fuse contract
    address public immutable VERSION;

    constructor() {
        VERSION = address(this);
    }

    error TransientStorageSplitterFuseZeroDenominator();
    error TransientStorageSplitterFuseEmptyRoutes();
    error TransientStorageSplitterFuseNumeratorSumMismatch(uint256 numeratorSum, uint256 denominator);
    error TransientStorageSplitterFuseZeroDestinationAddress();
    error TransientStorageSplitterFuseUnknownParamType();

    /// @notice Splits a total amount from transient storage into proportional parts and writes them to destination fuses
    /// @param data_ The data containing split instructions
    /// @dev Requires that destination transient storage must be pre-initialized with sufficient array length before calling enter().
    ///      The last route receives the remainder to prevent dust loss from integer division.
    function enter(TransientStorageSplitterFuseEnterData calldata data_) external {
        if (data_.denominator == 0) {
            revert TransientStorageSplitterFuseZeroDenominator();
        }

        uint256 routesLen = data_.routes.length;
        if (routesLen == 0) {
            revert TransientStorageSplitterFuseEmptyRoutes();
        }

        // Validate numerator sum and destination addresses
        uint256 numeratorSum;
        for (uint256 i; i < routesLen; ++i) {
            if (data_.routes[i].destinationFuse == address(0)) {
                revert TransientStorageSplitterFuseZeroDestinationAddress();
            }
            numeratorSum += data_.routes[i].numerator;
        }
        if (numeratorSum != data_.denominator) {
            revert TransientStorageSplitterFuseNumeratorSumMismatch(numeratorSum, data_.denominator);
        }

        // Read total amount from source
        bytes32 rawValue;
        if (data_.sourceParamType == TransientStorageParamTypes.INPUTS_BY_FUSE) {
            rawValue = TransientStorageLib.getInput(data_.sourceAddress, data_.sourceIndex);
        } else if (data_.sourceParamType == TransientStorageParamTypes.OUTPUTS_BY_FUSE) {
            rawValue = TransientStorageLib.getOutput(data_.sourceAddress, data_.sourceIndex);
        } else {
            revert TransientStorageSplitterFuseUnknownParamType();
        }

        uint256 totalAmount = uint256(rawValue);
        uint256 allocated;

        // For all routes except the last, compute proportional amount
        uint256 lastIndex = routesLen - 1;
        for (uint256 i; i < lastIndex; ++i) {
            uint256 amount = (totalAmount * data_.routes[i].numerator) / data_.denominator;
            allocated += amount;
            TransientStorageLib.setInput(
                data_.routes[i].destinationFuse,
                data_.routes[i].destinationIndex,
                bytes32(amount)
            );
        }

        // Last route gets the remainder to prevent dust loss
        uint256 lastAmount = totalAmount - allocated;
        TransientStorageLib.setInput(
            data_.routes[lastIndex].destinationFuse,
            data_.routes[lastIndex].destinationIndex,
            bytes32(lastAmount)
        );
    }
}
