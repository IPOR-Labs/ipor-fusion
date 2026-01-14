// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {IporFusionMarkets} from "../../libraries/IporFusionMarkets.sol";
import {TransientStorageLib, TransientStorageParamTypes} from "../../transient_storage/TransientStorageLib.sol";
import {DataType} from "../../libraries/TypeConversionLib.sol";

/// @dev Struct defining a single mapping item
struct TransientStorageMapperItem {
    /// @notice The type of parameter to map (INPUT or OUTPUT)
    TransientStorageParamTypes paramType;
    /// @notice The address of the fuse to read data from
    address dataFromAddress;
    /// @notice The index of the data in the source fuse's storage
    uint256 dataFromIndex;
    /// @notice The data type of the source value
    DataType dataFromType;
    /// @notice The number of decimals for the source value (used for decimal conversion)
    uint256 dataFromDecimals;
    /// @notice The address of the fuse to write data to
    address dataToAddress;
    /// @notice The index of the data in the destination fuse's storage
    uint256 dataToIndex;
    /// @notice The data type of the destination value
    DataType dataToType;
    /// @notice The number of decimals for the destination value (used for decimal conversion)
    uint256 dataToDecimals;
}

/// @dev Struct for passing data to the enter function
struct TransientStorageMapperEnterData {
    /// @notice Array of mapping items to process
    TransientStorageMapperItem[] items;
}

/// @title TransientStorageMapperFuse
/// @notice Fuse for mapping transient storage data between fuses with type and decimal conversion
/// @author IPOR Labs
contract TransientStorageMapperFuse is IFuseCommon {
    /// @notice The market ID associated with the Fuse
    uint256 public constant MARKET_ID = IporFusionMarkets.ERC20_VAULT_BALANCE;

    error TransientStorageMapperFuseUnknownParamType();
    error TransientStorageMapperFuseInvalidDataFromAddress();
    error TransientStorageMapperFuseInvalidDataToAddress();
    error TransientStorageMapperFuseUnsupportedDataType();
    error TransientStorageMapperFuseValueOutOfRange(uint256 value, DataType targetType);

    /// @notice Maps transient storage data between fuses with optional type and decimal conversion
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

            value = _convertValue(
                value,
                item.dataFromType,
                item.dataFromDecimals,
                item.dataToType,
                item.dataToDecimals
            );

            TransientStorageLib.setInput(item.dataToAddress, item.dataToIndex, value);
        }
    }

    /// @notice Converts value from source type/decimals to destination type/decimals
    /// @param value_ The source value as bytes32
    /// @param fromType_ The source data type
    /// @param fromDecimals_ The source decimals
    /// @param toType_ The destination data type
    /// @param toDecimals_ The destination decimals
    /// @return The converted value as bytes32
    function _convertValue(
        bytes32 value_,
        DataType fromType_,
        uint256 fromDecimals_,
        DataType toType_,
        uint256 toDecimals_
    ) internal pure returns (bytes32) {
        // If types are UNKNOWN or the same with same decimals, return value unchanged
        if (fromType_ == DataType.UNKNOWN || toType_ == DataType.UNKNOWN) {
            return value_;
        }

        // If types and decimals are identical, no conversion needed
        if (fromType_ == toType_ && fromDecimals_ == toDecimals_) {
            return value_;
        }

        // Extract numeric value based on fromType
        uint256 numericValue = _extractNumericValue(value_, fromType_);

        // Apply decimal conversion if decimals differ
        if (fromDecimals_ != toDecimals_) {
            numericValue = _convertDecimals(numericValue, fromDecimals_, toDecimals_);
        }

        // Convert to destination type
        return _packNumericValue(numericValue, toType_);
    }

    /// @notice Extracts numeric value from bytes32 based on data type
    /// @param value_ The bytes32 value
    /// @param dataType_ The data type
    /// @return The extracted numeric value as uint256
    function _extractNumericValue(bytes32 value_, DataType dataType_) internal pure returns (uint256) {
        if (dataType_ == DataType.UINT256 || dataType_ == DataType.BYTES32) {
            return uint256(value_);
        } else if (dataType_ == DataType.UINT128) {
            return uint256(uint128(uint256(value_)));
        } else if (dataType_ == DataType.UINT64) {
            return uint256(uint64(uint256(value_)));
        } else if (dataType_ == DataType.UINT32) {
            return uint256(uint32(uint256(value_)));
        } else if (dataType_ == DataType.UINT16) {
            return uint256(uint16(uint256(value_)));
        } else if (dataType_ == DataType.UINT8) {
            return uint256(uint8(uint256(value_)));
        } else if (dataType_ == DataType.ADDRESS) {
            return uint256(uint160(uint256(value_)));
        } else if (dataType_ == DataType.BOOL) {
            return uint256(value_) != 0 ? 1 : 0;
        } else if (dataType_ == DataType.INT256) {
            int256 signedValue = int256(uint256(value_));
            return signedValue >= 0 ? uint256(signedValue) : 0;
        } else if (dataType_ == DataType.INT128) {
            int128 signedValue = int128(int256(uint256(value_)));
            return signedValue >= 0 ? uint256(int256(signedValue)) : 0;
        } else if (dataType_ == DataType.INT64) {
            int64 signedValue = int64(int256(uint256(value_)));
            return signedValue >= 0 ? uint256(int256(signedValue)) : 0;
        } else if (dataType_ == DataType.INT32) {
            int32 signedValue = int32(int256(uint256(value_)));
            return signedValue >= 0 ? uint256(int256(signedValue)) : 0;
        } else if (dataType_ == DataType.INT16) {
            int16 signedValue = int16(int256(uint256(value_)));
            return signedValue >= 0 ? uint256(int256(signedValue)) : 0;
        } else if (dataType_ == DataType.INT8) {
            int8 signedValue = int8(int256(uint256(value_)));
            return signedValue >= 0 ? uint256(int256(signedValue)) : 0;
        }
        revert TransientStorageMapperFuseUnsupportedDataType();
    }

    /// @notice Converts value between different decimal precisions
    /// @param value_ The value to convert
    /// @param fromDecimals_ Source decimals
    /// @param toDecimals_ Destination decimals
    /// @return The converted value
    function _convertDecimals(
        uint256 value_,
        uint256 fromDecimals_,
        uint256 toDecimals_
    ) internal pure returns (uint256) {
        if (fromDecimals_ == toDecimals_) {
            return value_;
        } else if (fromDecimals_ < toDecimals_) {
            // Scale up: multiply by 10^(toDecimals - fromDecimals)
            return value_ * (10 ** (toDecimals_ - fromDecimals_));
        } else {
            // Scale down: divide by 10^(fromDecimals - toDecimals)
            return value_ / (10 ** (fromDecimals_ - toDecimals_));
        }
    }

    /// @notice Packs numeric value into bytes32 based on data type
    /// @dev Validates that value fits within the target type's range before conversion
    /// @param value_ The numeric value
    /// @param dataType_ The target data type
    /// @return The packed bytes32 value
    function _packNumericValue(uint256 value_, DataType dataType_) internal pure returns (bytes32) {
        if (dataType_ == DataType.UINT256 || dataType_ == DataType.BYTES32) {
            return bytes32(value_);
        } else if (dataType_ == DataType.UINT128) {
            if (value_ > type(uint128).max) {
                revert TransientStorageMapperFuseValueOutOfRange(value_, dataType_);
            }
            return bytes32(uint256(uint128(value_)));
        } else if (dataType_ == DataType.UINT64) {
            if (value_ > type(uint64).max) {
                revert TransientStorageMapperFuseValueOutOfRange(value_, dataType_);
            }
            return bytes32(uint256(uint64(value_)));
        } else if (dataType_ == DataType.UINT32) {
            if (value_ > type(uint32).max) {
                revert TransientStorageMapperFuseValueOutOfRange(value_, dataType_);
            }
            return bytes32(uint256(uint32(value_)));
        } else if (dataType_ == DataType.UINT16) {
            if (value_ > type(uint16).max) {
                revert TransientStorageMapperFuseValueOutOfRange(value_, dataType_);
            }
            return bytes32(uint256(uint16(value_)));
        } else if (dataType_ == DataType.UINT8) {
            if (value_ > type(uint8).max) {
                revert TransientStorageMapperFuseValueOutOfRange(value_, dataType_);
            }
            return bytes32(uint256(uint8(value_)));
        } else if (dataType_ == DataType.ADDRESS) {
            if (value_ > type(uint160).max) {
                revert TransientStorageMapperFuseValueOutOfRange(value_, dataType_);
            }
            return bytes32(uint256(uint160(value_)));
        } else if (dataType_ == DataType.BOOL) {
            return bytes32(uint256(value_ != 0 ? 1 : 0));
        } else if (dataType_ == DataType.INT256) {
            // INT256 can represent the full uint256 range in its positive domain up to int256.max
            if (value_ > uint256(type(int256).max)) {
                revert TransientStorageMapperFuseValueOutOfRange(value_, dataType_);
            }
            return bytes32(value_);
        } else if (dataType_ == DataType.INT128) {
            if (value_ > uint128(type(int128).max)) {
                revert TransientStorageMapperFuseValueOutOfRange(value_, dataType_);
            }
            return bytes32(uint256(int256(int128(uint128(value_)))));
        } else if (dataType_ == DataType.INT64) {
            if (value_ > uint64(type(int64).max)) {
                revert TransientStorageMapperFuseValueOutOfRange(value_, dataType_);
            }
            return bytes32(uint256(int256(int64(uint64(value_)))));
        } else if (dataType_ == DataType.INT32) {
            if (value_ > uint32(type(int32).max)) {
                revert TransientStorageMapperFuseValueOutOfRange(value_, dataType_);
            }
            return bytes32(uint256(int256(int32(uint32(value_)))));
        } else if (dataType_ == DataType.INT16) {
            if (value_ > uint16(type(int16).max)) {
                revert TransientStorageMapperFuseValueOutOfRange(value_, dataType_);
            }
            return bytes32(uint256(int256(int16(uint16(value_)))));
        } else if (dataType_ == DataType.INT8) {
            if (value_ > uint8(type(int8).max)) {
                revert TransientStorageMapperFuseValueOutOfRange(value_, dataType_);
            }
            return bytes32(uint256(int256(int8(uint8(value_)))));
        }
        revert TransientStorageMapperFuseUnsupportedDataType();
    }
}
