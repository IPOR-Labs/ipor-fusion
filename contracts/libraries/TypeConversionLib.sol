// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

enum DataType {
    UNKNOWN,
    UINT256,
    UINT128,
    UINT64,
    UINT32,
    UINT16,
    UINT8,
    INT256,
    INT128,
    INT64,
    INT32,
    INT16,
    INT8,
    ADDRESS,
    BOOL,
    BYTES32
}

/// @title TypeConversionLib
/// @notice Library for converting between bytes32 and various Solidity types
/// @author IPOR Labs
library TypeConversionLib {
    /// @notice Converts an address to bytes32
    /// @param value_ The address to convert
    /// @return The bytes32 representation
    function toBytes32(address value_) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value_)));
    }

    /// @notice Converts bytes32 to an address
    /// @param value_ The bytes32 to convert
    /// @return The address representation
    function toAddress(bytes32 value_) internal pure returns (address) {
        return address(uint160(uint256(value_)));
    }

    /// @notice Converts a uint256 to bytes32
    /// @param value_ The uint256 to convert
    /// @return The bytes32 representation
    function toBytes32(uint256 value_) internal pure returns (bytes32) {
        return bytes32(value_);
    }

    /// @notice Converts bytes32 to a uint256
    /// @param value_ The bytes32 to convert
    /// @return The uint256 representation
    function toUint256(bytes32 value_) internal pure returns (uint256) {
        return uint256(value_);
    }

    /// @notice Converts a bool to bytes32
    /// @param value_ The bool to convert
    /// @return The bytes32 representation (1 for true, 0 for false)
    function toBytes32(bool value_) internal pure returns (bytes32) {
        return bytes32(uint256(value_ ? 1 : 0));
    }

    /// @notice Converts bytes32 to a bool
    /// @param value_ The bytes32 to convert
    /// @return The bool representation
    function toBool(bytes32 value_) internal pure returns (bool) {
        return uint256(value_) != 0;
    }

    /// @notice Converts an int256 to bytes32
    /// @param value_ The int256 to convert
    /// @return The bytes32 representation
    function toBytes32(int256 value_) internal pure returns (bytes32) {
        return bytes32(uint256(value_));
    }

    /// @notice Converts bytes32 to an int256
    /// @param value_ The bytes32 to convert
    /// @return The int256 representation
    function toInt256(bytes32 value_) internal pure returns (int256) {
        return int256(uint256(value_));
    }

    /// @notice Converts bytes32 to bytes
    /// @param value_ The bytes32 to convert
    /// @return The bytes representation
    function toBytes(bytes32 value_) internal pure returns (bytes memory) {
        return abi.encodePacked(value_);
    }

    /// @notice Converts bytes to bytes32
    /// @dev Reads the first 32 bytes of the input array. Returns 0 if empty.
    /// @param value_ The bytes to convert
    /// @return result The bytes32 representation
    function toBytes32(bytes memory value_) internal pure returns (bytes32 result) {
        if (value_.length == 0) return 0x0;
        assembly {
            result := mload(add(value_, 32))
        }
    }
}
