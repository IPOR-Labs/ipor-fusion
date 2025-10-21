// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @notice Structure representing a substrate with target address and function selector
/// @param target_ The target contract address
/// @param functionSelector_ The function selector (first 4 bytes of function signature hash)
struct Substrat {
    address target_;
    bytes4 functionSelector_;
}

/// @title EnsoSubstrateLib
/// @notice Library for encoding and decoding substrate information (address + function selector) to/from bytes32
library EnsoSubstrateLib {
    /// @notice Encodes a Substrat struct into bytes32
    /// @dev Layout: [0:20] address (20 bytes) | [20:24] bytes4 selector (4 bytes) | [24:32] padding (8 bytes)
    /// @param substrat_ The Substrat struct to encode
    /// @return encoded The bytes32 encoded representation
    function encode(Substrat memory substrat_) internal pure returns (bytes32 encoded) {
        // Shift address to occupy the first 20 bytes (most significant)
        // Then OR with the function selector shifted to bytes [20:24]
        encoded =
            bytes32(uint256(uint160(substrat_.target_)) << 96) |
            bytes32(uint256(uint32(substrat_.functionSelector_)) << 64);
    }

    /// @notice Decodes bytes32 back into a Substrat struct
    /// @dev Extracts address from first 20 bytes and function selector from next 4 bytes
    /// @param encoded_ The bytes32 encoded data
    /// @return substrat_ The decoded Substrat struct
    function decode(bytes32 encoded_) internal pure returns (Substrat memory substrat_) {
        // Extract address from first 20 bytes (shift right 96 bits to get the most significant 160 bits)
        substrat_.target_ = address(uint160(uint256(encoded_) >> 96));

        // Extract function selector from bytes [20:24] (shift right 64 bits and mask to get 4 bytes)
        substrat_.functionSelector_ = bytes4(uint32(uint256(encoded_) >> 64));
    }

    /// @notice Encodes address and function selector directly into bytes32
    /// @param target_ The target contract address
    /// @param functionSelector_ The function selector
    /// @return encoded The bytes32 encoded representation
    function encodeRaw(address target_, bytes4 functionSelector_) internal pure returns (bytes32 encoded) {
        encoded = bytes32(uint256(uint160(target_)) << 96) | bytes32(uint256(uint32(functionSelector_)) << 64);
    }

    /// @notice Decodes bytes32 into address and function selector
    /// @param encoded_ The bytes32 encoded data
    /// @return target_ The decoded target address
    /// @return functionSelector_ The decoded function selector
    function decodeRaw(bytes32 encoded_) internal pure returns (address target_, bytes4 functionSelector_) {
        target_ = address(uint160(uint256(encoded_) >> 96));
        functionSelector_ = bytes4(uint32(uint256(encoded_) >> 64));
    }

    /// @notice Extracts only the target address from encoded bytes32
    /// @param encoded_ The bytes32 encoded data
    /// @return target_ The target address
    function getTarget(bytes32 encoded_) internal pure returns (address target_) {
        target_ = address(uint160(uint256(encoded_) >> 96));
    }

    /// @notice Extracts only the function selector from encoded bytes32
    /// @param encoded_ The bytes32 encoded data
    /// @return functionSelector_ The function selector
    function getFunctionSelector(bytes32 encoded_) internal pure returns (bytes4 functionSelector_) {
        functionSelector_ = bytes4(uint32(uint256(encoded_) >> 64));
    }
}
