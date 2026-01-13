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
    uint256 public constant MARKET_ID = IporFusionMarkets.ZERO_BALANCE_MARKET;
    /// @notice Maximum number of items allowed in a single mapping operation
    /// @dev Prevents DoS attacks through excessively large arrays and ensures gas limits are not exceeded
    uint256 public constant MAX_ITEMS = 256;
    /// @notice Maximum decimal difference allowed for conversion
    /// @dev Prevents overflow when calculating scale factor: 10^77 is the largest power of 10 that fits in uint256
    uint256 public constant MAX_DECIMAL_DIFF = 77;
    /// @notice The version identifier of this fuse contract
    address public immutable VERSION;

    constructor() {
        VERSION = address(this);
    }

    error TransientStorageMapperFuseUnknownParamType();
    error TransientStorageMapperFuseInvalidDataFromAddress();
    error TransientStorageMapperFuseInvalidDataToAddress();
    error TransientStorageMapperFuseUnsupportedDataType();
    error TransientStorageMapperFuseValueOutOfRange(uint256 value, DataType targetType);
    error TransientStorageMapperFuseNegativeValueNotAllowed(int256 value, DataType targetType);
    error TransientStorageMapperFuseInvalidConversion(DataType fromType, DataType toType);
    error TransientStorageMapperFuseDecimalOverflow(uint256 value, uint256 fromDecimals, uint256 toDecimals);
    error TransientStorageMapperFuseSignedDecimalOverflow(int256 value, uint256 fromDecimals, uint256 toDecimals);
    error TransientStorageMapperFuseItemsArrayTooLarge(uint256 itemsLength, uint256 maxItems);
    error TransientStorageMapperFuseDecimalDifferenceTooLarge(uint256 fromDecimals, uint256 toDecimals, uint256 maxDiff);

    /// @notice Maps transient storage data between fuses with optional type and decimal conversion
    /// @param data_ The data containing mapping instructions
    /// @dev Reverts if items array length exceeds MAX_ITEMS (256) to prevent DoS attacks
    /// @dev Requires that destination transient storage (dataToAddress) must be pre-initialized with sufficient array length before calling enter().
    ///      The TransientStorageLib.setInput() function requires the destination storage to have been initialized with at least (dataToIndex + 1) elements.
    function enter(TransientStorageMapperEnterData calldata data_) external {
        uint256 len = data_.items.length;
        if (len > MAX_ITEMS) {
            revert TransientStorageMapperFuseItemsArrayTooLarge(len, MAX_ITEMS);
        }
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

    // ============ Type Classification Helpers ============

    /// @notice Checks if the data type is a signed integer type
    /// @param dataType_ The data type to check
    /// @return True if the data type is a signed integer type
    function _isSignedType(DataType dataType_) internal pure returns (bool) {
        return dataType_ == DataType.INT256 || dataType_ == DataType.INT128 ||
               dataType_ == DataType.INT64 || dataType_ == DataType.INT32 ||
               dataType_ == DataType.INT16 || dataType_ == DataType.INT8;
    }

    /// @notice Checks if the data type is an unsigned integer type
    /// @param dataType_ The data type to check
    /// @return True if the data type is an unsigned integer type
    function _isUnsignedType(DataType dataType_) internal pure returns (bool) {
        return dataType_ == DataType.UINT256 || dataType_ == DataType.UINT128 ||
               dataType_ == DataType.UINT64 || dataType_ == DataType.UINT32 ||
               dataType_ == DataType.UINT16 || dataType_ == DataType.UINT8;
    }

    /// @notice Checks if the data type supports decimal conversion
    /// @param dataType_ The data type to check
    /// @return True if the data type is numeric (unsigned or signed integer)
    function _isNumericType(DataType dataType_) internal pure returns (bool) {
        return _isSignedType(dataType_) || _isUnsignedType(dataType_);
    }

    // ============ Conversion Path Validation ============

    /// @notice Validates that the conversion path is supported
    /// @param fromType_ Source data type
    /// @param toType_ Target data type
    function _validateConversionPath(DataType fromType_, DataType toType_) internal pure {
        // INT* -> ADDRESS is not allowed
        if (_isSignedType(fromType_) && toType_ == DataType.ADDRESS) {
            revert TransientStorageMapperFuseInvalidConversion(fromType_, toType_);
        }
        // BOOL -> ADDRESS is not allowed
        if (fromType_ == DataType.BOOL && toType_ == DataType.ADDRESS) {
            revert TransientStorageMapperFuseInvalidConversion(fromType_, toType_);
        }
        // ADDRESS -> INT* is not allowed
        if (fromType_ == DataType.ADDRESS && _isSignedType(toType_)) {
            revert TransientStorageMapperFuseInvalidConversion(fromType_, toType_);
        }
    }

    // ============ Main Conversion Function ============

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
        // Early return for UNKNOWN types
        if (fromType_ == DataType.UNKNOWN || toType_ == DataType.UNKNOWN) {
            return value_;
        }

        // Early return for same type and decimals
        if (fromType_ == toType_ && fromDecimals_ == toDecimals_) {
            return value_;
        }

        // Validate conversion paths
        _validateConversionPath(fromType_, toType_);

        // Route based on source type
        if (_isSignedType(fromType_)) {
            return _convertFromSigned(value_, fromType_, fromDecimals_, toType_, toDecimals_);
        } else {
            return _convertFromUnsigned(value_, fromType_, fromDecimals_, toType_, toDecimals_);
        }
    }

    // ============ Signed Source Conversion ============

    /// @notice Converts from a signed source type
    /// @param value_ The source value as bytes32
    /// @param fromType_ The source data type (must be signed)
    /// @param fromDecimals_ The source decimals
    /// @param toType_ The destination data type
    /// @param toDecimals_ The destination decimals
    /// @return The converted value as bytes32
    function _convertFromSigned(
        bytes32 value_,
        DataType fromType_,
        uint256 fromDecimals_,
        DataType toType_,
        uint256 toDecimals_
    ) internal pure returns (bytes32) {
        int256 signedValue = _extractSignedNumericValue(value_, fromType_);

        // INT* -> UINT*
        if (_isUnsignedType(toType_)) {
            if (signedValue < 0) {
                revert TransientStorageMapperFuseNegativeValueNotAllowed(signedValue, toType_);
            }
            uint256 unsignedValue = uint256(signedValue);
            // Apply decimal conversion
            if (fromDecimals_ != toDecimals_) {
                unsignedValue = _convertDecimals(unsignedValue, fromDecimals_, toDecimals_);
            }
            return _packNumericValue(unsignedValue, toType_);
        }

        // INT* -> INT*
        if (_isSignedType(toType_)) {
            // Apply decimal conversion preserving sign
            if (fromDecimals_ != toDecimals_) {
                signedValue = _convertSignedDecimals(signedValue, fromDecimals_, toDecimals_);
            }
            return _packSignedNumericValue(signedValue, toType_);
        }

        // INT* -> BOOL
        if (toType_ == DataType.BOOL) {
            return bytes32(uint256(signedValue != 0 ? 1 : 0));
        }

        // INT* -> BYTES32
        if (toType_ == DataType.BYTES32) {
            return value_;
        }

        revert TransientStorageMapperFuseUnsupportedDataType();
    }

    // ============ Unsigned Source Conversion ============

    /// @notice Converts from an unsigned/non-signed source type
    /// @param value_ The source value as bytes32
    /// @param fromType_ The source data type
    /// @param fromDecimals_ The source decimals
    /// @param toType_ The destination data type
    /// @param toDecimals_ The destination decimals
    /// @return The converted value as bytes32
    function _convertFromUnsigned(
        bytes32 value_,
        DataType fromType_,
        uint256 fromDecimals_,
        DataType toType_,
        uint256 toDecimals_
    ) internal pure returns (bytes32) {
        uint256 numericValue = _extractNumericValue(value_, fromType_);

        // Apply decimal conversion only for numeric source and target types
        bool applyDecimals = _isNumericType(fromType_) && _isNumericType(toType_) && fromDecimals_ != toDecimals_;

        // UINT*/ADDRESS/BOOL/BYTES32 -> INT*
        if (_isSignedType(toType_)) {
            // For unsigned to signed, apply decimals first (on unsigned), then range check and convert
            if (applyDecimals) {
                numericValue = _convertDecimals(numericValue, fromDecimals_, toDecimals_);
            }
            return _packNumericValueToSigned(numericValue, toType_);
        }

        // Standard unsigned conversion path
        if (applyDecimals) {
            numericValue = _convertDecimals(numericValue, fromDecimals_, toDecimals_);
        }

        return _packNumericValue(numericValue, toType_);
    }

    // ============ Signed Value Extraction ============

    /// @notice Extracts signed numeric value from bytes32 based on data type
    /// @param value_ The bytes32 value
    /// @param dataType_ The data type (must be a signed type)
    /// @return The extracted signed value as int256
    function _extractSignedNumericValue(bytes32 value_, DataType dataType_) internal pure returns (int256) {
        if (dataType_ == DataType.INT256) {
            return int256(uint256(value_));
        } else if (dataType_ == DataType.INT128) {
            return int256(int128(int256(uint256(value_))));
        } else if (dataType_ == DataType.INT64) {
            return int256(int64(int256(uint256(value_))));
        } else if (dataType_ == DataType.INT32) {
            return int256(int32(int256(uint256(value_))));
        } else if (dataType_ == DataType.INT16) {
            return int256(int16(int256(uint256(value_))));
        } else if (dataType_ == DataType.INT8) {
            return int256(int8(int256(uint256(value_))));
        }
        revert TransientStorageMapperFuseUnsupportedDataType();
    }

    // ============ Signed Decimal Conversion ============

    /// @notice Converts signed value between different decimal precisions
    /// @param value_ The signed value to convert
    /// @param fromDecimals_ Source decimals
    /// @param toDecimals_ Destination decimals
    /// @return The converted signed value
    function _convertSignedDecimals(
        int256 value_,
        uint256 fromDecimals_,
        uint256 toDecimals_
    ) internal pure returns (int256) {
        if (fromDecimals_ == toDecimals_) {
            return value_;
        }
        
        uint256 decimalDiff;
        if (fromDecimals_ < toDecimals_) {
            decimalDiff = toDecimals_ - fromDecimals_;
        } else {
            decimalDiff = fromDecimals_ - toDecimals_;
        }
        
        // Validate that decimal difference is within reasonable bounds to prevent scale calculation overflow
        if (decimalDiff > MAX_DECIMAL_DIFF) {
            revert TransientStorageMapperFuseDecimalDifferenceTooLarge(fromDecimals_, toDecimals_, MAX_DECIMAL_DIFF);
        }
        
        if (fromDecimals_ < toDecimals_) {
            // Scale up: multiply by 10^(toDecimals - fromDecimals)
            uint256 scale = 10 ** decimalDiff;
            int256 scaleSigned = int256(scale);
            int256 result;
            // Use unchecked to prevent panic, then manually check for overflow
            unchecked {
                result = value_ * scaleSigned;
            }
            // Check for overflow: if value != 0, result / scale must equal value
            if (value_ != 0 && result / scaleSigned != value_) {
                revert TransientStorageMapperFuseSignedDecimalOverflow(value_, fromDecimals_, toDecimals_);
            }
            return result;
        } else {
            // Scale down: divide by 10^(fromDecimals - toDecimals)
            uint256 scale = 10 ** decimalDiff;
            return value_ / int256(scale);
        }
    }

    // ============ Signed Value Packing ============

    /// @notice Packs signed numeric value into bytes32 based on data type
    /// @param value_ The signed numeric value
    /// @param dataType_ The target data type (must be signed)
    /// @return The packed bytes32 value
    function _packSignedNumericValue(int256 value_, DataType dataType_) internal pure returns (bytes32) {
        if (dataType_ == DataType.INT256) {
            return bytes32(uint256(value_));
        } else if (dataType_ == DataType.INT128) {
            if (value_ > type(int128).max || value_ < type(int128).min) {
                revert TransientStorageMapperFuseValueOutOfRange(uint256(value_ >= 0 ? value_ : -value_), dataType_);
            }
            return bytes32(uint256(int256(int128(value_))));
        } else if (dataType_ == DataType.INT64) {
            if (value_ > type(int64).max || value_ < type(int64).min) {
                revert TransientStorageMapperFuseValueOutOfRange(uint256(value_ >= 0 ? value_ : -value_), dataType_);
            }
            return bytes32(uint256(int256(int64(value_))));
        } else if (dataType_ == DataType.INT32) {
            if (value_ > type(int32).max || value_ < type(int32).min) {
                revert TransientStorageMapperFuseValueOutOfRange(uint256(value_ >= 0 ? value_ : -value_), dataType_);
            }
            return bytes32(uint256(int256(int32(value_))));
        } else if (dataType_ == DataType.INT16) {
            if (value_ > type(int16).max || value_ < type(int16).min) {
                revert TransientStorageMapperFuseValueOutOfRange(uint256(value_ >= 0 ? value_ : -value_), dataType_);
            }
            return bytes32(uint256(int256(int16(value_))));
        } else if (dataType_ == DataType.INT8) {
            if (value_ > type(int8).max || value_ < type(int8).min) {
                revert TransientStorageMapperFuseValueOutOfRange(uint256(value_ >= 0 ? value_ : -value_), dataType_);
            }
            return bytes32(uint256(int256(int8(value_))));
        }
        revert TransientStorageMapperFuseUnsupportedDataType();
    }

    // ============ Unsigned to Signed Packing ============

    /// @notice Packs unsigned value into signed type with range checking
    /// @param value_ The unsigned value
    /// @param dataType_ The target data type (must be signed)
    /// @return The packed bytes32 value
    function _packNumericValueToSigned(uint256 value_, DataType dataType_) internal pure returns (bytes32) {
        if (dataType_ == DataType.INT256) {
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

    // ============ Unsigned Value Extraction ============

    /// @notice Extracts numeric value from bytes32 based on data type (unsigned/non-signed types)
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
        }
        revert TransientStorageMapperFuseUnsupportedDataType();
    }

    // ============ Unsigned Decimal Conversion ============

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
        }
        
        uint256 decimalDiff;
        if (fromDecimals_ < toDecimals_) {
            decimalDiff = toDecimals_ - fromDecimals_;
        } else {
            decimalDiff = fromDecimals_ - toDecimals_;
        }
        
        // Validate that decimal difference is within reasonable bounds to prevent scale calculation overflow
        if (decimalDiff > MAX_DECIMAL_DIFF) {
            revert TransientStorageMapperFuseDecimalDifferenceTooLarge(fromDecimals_, toDecimals_, MAX_DECIMAL_DIFF);
        }
        
        if (fromDecimals_ < toDecimals_) {
            // Scale up: multiply by 10^(toDecimals - fromDecimals)
            uint256 scale = 10 ** decimalDiff;
            uint256 result;
            // Use unchecked to prevent panic, then manually check for overflow
            unchecked {
                result = value_ * scale;
            }
            // Check for overflow: if value != 0, result / scale must equal value
            if (value_ != 0 && result / scale != value_) {
                revert TransientStorageMapperFuseDecimalOverflow(value_, fromDecimals_, toDecimals_);
            }
            return result;
        } else {
            // Scale down: divide by 10^(fromDecimals - toDecimals)
            return value_ / (10 ** decimalDiff);
        }
    }

    // ============ Unsigned Value Packing ============

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
        }
        revert TransientStorageMapperFuseUnsupportedDataType();
    }
}
