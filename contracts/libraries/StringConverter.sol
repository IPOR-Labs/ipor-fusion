// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title StringConverter
/// @notice Library for converting strings to/from bytes32 arrays using length-prefixed encoding
/// @dev IL-6957/IL-6960 fix: Uses length-prefixed encoding to preserve trailing null bytes
///      and prevent decoding malleability. The first 2 bytes store the string length (uint16),
///      followed by the actual string data. This ensures round-trip encode/decode is lossless.
library StringConverter {
    /// @notice Error thrown when string exceeds maximum supported length (65535 bytes)
    error StringTooLong();

    /// @notice Error thrown when encoded data is malformed (declared length exceeds available bytes)
    error InvalidEncodedData();

    /// @notice Converts a string to a length-prefixed bytes32 array
    /// @dev First 2 bytes of the encoding contain the string length (uint16, little-endian).
    ///      Remaining bytes contain the actual string data. This encoding preserves all bytes
    ///      including embedded and trailing null bytes, preventing collision attacks.
    /// @param s The string to encode
    /// @return result Array of bytes32 containing the length-prefixed encoded string
    function toBytes32(string memory s) internal pure returns (bytes32[] memory result) {
        bytes memory b = bytes(s);
        uint256 length = b.length;

        // Maximum supported length is uint16 max (65535)
        if (length > type(uint16).max) {
            revert StringTooLong();
        }

        // Handle empty string
        if (length == 0) {
            result = new bytes32[](1);
            // First bytes32 contains only length (0) in first 2 bytes
            result[0] = bytes32(0);
            return result;
        }

        // Calculate array size: 2 bytes for length + string data
        // First bytes32 holds 2 bytes length + 30 bytes data
        // Subsequent bytes32 hold 32 bytes data each
        uint256 totalBytes = length + 2;
        uint256 arrayLength = (totalBytes + 31) / 32;
        result = new bytes32[](arrayLength);

        // Pack length into first 2 bytes (little-endian)
        result[0] = bytes32(uint256(length));

        // Pack string data starting at byte index 2
        uint256 byteIndex;
        for (uint256 i; i < arrayLength; ++i) {
            bytes32 packed = result[i]; // Start with existing data (length in first bytes32)
            uint256 startByte = (i == 0) ? 2 : 0; // Skip first 2 bytes in first element

            for (uint256 j = startByte; j < 32 && byteIndex < length; ++j) {
                packed |= bytes32(uint256(uint8(b[byteIndex])) << (j * 8));
                ++byteIndex;
            }
            result[i] = packed;
        }
    }

    /// @notice Converts a length-prefixed bytes32 array back to a string
    /// @dev Reads the length from first 2 bytes and extracts exactly that many bytes.
    ///      This preserves all bytes including embedded and trailing nulls, preventing
    ///      decoding malleability where different inputs could produce the same output.
    /// @param b The bytes32 array to decode (must be length-prefixed encoded)
    /// @return The decoded string
    function fromBytes32(bytes32[] memory b) internal pure returns (string memory) {
        if (b.length == 0) {
            return "";
        }

        // Extract length from first 2 bytes (little-endian uint16)
        uint256 length = uint256(uint16(uint256(b[0])));

        // Handle zero-length string
        if (length == 0) {
            return "";
        }

        // Validate that array has enough bytes for declared length
        // Array provides: (b.length * 32) - 2 bytes of data (first 2 are length)
        uint256 availableDataBytes = b.length * 32 - 2;
        if (length > availableDataBytes) {
            revert InvalidEncodedData();
        }

        bytes memory result = new bytes(length);
        uint256 resultIndex;

        // Extract data starting at byte index 2 in first bytes32
        for (uint256 i; i < b.length && resultIndex < length; ++i) {
            bytes32 currentBytes32 = b[i];
            uint256 startByte = (i == 0) ? 2 : 0; // Skip length bytes in first element

            for (uint256 j = startByte; j < 32 && resultIndex < length; ++j) {
                result[resultIndex] = bytes1(uint8(uint256(currentBytes32 >> (j * 8))));
                ++resultIndex;
            }
        }

        return string(result);
    }
}
