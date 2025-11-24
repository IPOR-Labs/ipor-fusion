// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {IporFusionMarkets} from "../../libraries/IporFusionMarkets.sol";
import {TransientStorageLib, TransientStorageParamTypes} from "../../transient_storage/TransientStorageLib.sol";

/// @dev Struct defining a single mapping item
struct TransientStorageMapperItem {
    /// @notice The type of parameter to map (INPUT or OUTPUT)
    TransientStorageParamTypes paramType;
    /// @notice The address of the fuse to read data from
    address dataFromAddress;
    /// @notice The index of the data in the source fuse's storage
    uint256 dataFromIndex;
    /// @notice The address of the fuse to write data to
    address dataToAddress;
    /// @notice The index of the data in the destination fuse's storage
    uint256 dataToIndex;
}

/// @dev Struct for passing data to the enter function
struct TransientStorageMapperEnterData {
    /// @notice Array of mapping items to process
    TransientStorageMapperItem[] items;
}

/// @title TransientStorageMapperFuse
/// @notice Fuse for mapping transient storage data between fuses
/// @author IPOR Labs
contract TransientStorageMapperFuse is IFuseCommon {
    /// @notice The market ID associated with the Fuse
    uint256 public constant MARKET_ID = IporFusionMarkets.ERC20_VAULT_BALANCE;

    error TransientStorageMapperFuseUnknownParamType();
    error TransientStorageMapperFuseInvalidDataFromAddress();
    error TransientStorageMapperFuseInvalidDataToAddress();

    /// @notice Maps transient storage data between fuses
    /// @param data_ The data containing mapping instructions
    function enter(TransientStorageMapperEnterData calldata data_) external {
        uint256 len = data_.items.length;
        TransientStorageMapperItem calldata item;
        bytes32 value;
        for (uint256 i; i < len; ++i) {
            item = data_.items[i];

            if (item.dataFromAddress == address(0)) {
                revert TransientStorageMapperFuseInvalidDataFromAddress();
            }
            if (item.dataToAddress == address(0)) {
                revert TransientStorageMapperFuseInvalidDataToAddress();
            }
            if (item.paramType == TransientStorageParamTypes.INPUTS_BY_FUSE) {
                value = TransientStorageLib.getInput(item.dataFromAddress, item.dataFromIndex);
            } else if (item.paramType == TransientStorageParamTypes.OUTPUTS_BY_FUSE) {
                value = TransientStorageLib.getOutput(item.dataFromAddress, item.dataFromIndex);
            } else {
                revert TransientStorageMapperFuseUnknownParamType();
            }
            TransientStorageLib.setInput(item.dataToAddress, item.dataToIndex, value);
        }
    }
}
