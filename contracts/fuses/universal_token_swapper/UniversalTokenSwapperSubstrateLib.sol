// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @notice Enum to identify substrate type in UniversalTokenSwapper market
/// @dev Encoded as first byte (uint8) of bytes32 substrate
enum UniversalTokenSwapperSubstrateType {
    Unknown, // 0 - Invalid/unknown type
    Token, // 1 - Token address substrate (tokenIn, tokenOut)
    Target, // 2 - Allowed DEX/target address substrate
    Slippage // 3 - Slippage configuration substrate
}

/// @title UniversalTokenSwapperSubstrateLib
/// @notice Library for encoding and decoding UniversalTokenSwapper substrate information to/from bytes32
/// @dev Substrates are used to configure allowed tokens, targets, and slippage limits for swaps
/// @dev Layout: [0:1] type (1 byte) | [1:32] data (31 bytes)
///      - Token substrate: [0:1] type | [12:32] address (20 bytes), bytes [1:12] are padding
///      - Target substrate: [0:1] type | [12:32] address (20 bytes), bytes [1:12] are padding
///      - Slippage substrate: [0:1] type | [1:32] uint248 slippage in WAD (31 bytes)
library UniversalTokenSwapperSubstrateLib {
    /// @notice Error thrown when slippage value exceeds uint248 maximum
    /// @param slippageWad The slippage value that caused the overflow
    error UniversalTokenSwapperSubstrateLibSlippageOverflow(uint256 slippageWad);

    /// @notice Error thrown when zero address is provided for token or target
    error UniversalTokenSwapperSubstrateLibZeroAddress();

    /// @notice Encodes a token address as a substrate
    /// @param token_ The token address to encode
    /// @return encoded The bytes32 encoded substrate with Token type
    function encodeTokenSubstrate(address token_) internal pure returns (bytes32 encoded) {
        if (token_ == address(0)) {
            revert UniversalTokenSwapperSubstrateLibZeroAddress();
        }
        // Layout: [type (1 byte)][padding (11 bytes)][address (20 bytes)]
        // Type is in the most significant byte
        encoded = bytes32(uint256(UniversalTokenSwapperSubstrateType.Token) << 248) | bytes32(uint256(uint160(token_)));
    }

    /// @notice Encodes a target address as a substrate
    /// @param target_ The target/DEX address to encode
    /// @return encoded The bytes32 encoded substrate with Target type
    function encodeTargetSubstrate(address target_) internal pure returns (bytes32 encoded) {
        if (target_ == address(0)) {
            revert UniversalTokenSwapperSubstrateLibZeroAddress();
        }
        // Layout: [type (1 byte)][padding (11 bytes)][address (20 bytes)]
        // Type is in the most significant byte
        encoded =
            bytes32(uint256(UniversalTokenSwapperSubstrateType.Target) << 248) | bytes32(uint256(uint160(target_)));
    }

    /// @notice Encodes a slippage value as a substrate
    /// @param slippageWad_ The slippage value in WAD (1e18 = 100%)
    /// @return encoded The bytes32 encoded substrate with Slippage type
    function encodeSlippageSubstrate(uint256 slippageWad_) internal pure returns (bytes32 encoded) {
        // Layout: [type (1 byte)][slippage uint248 (31 bytes)]
        // Slippage must fit in 248 bits (31 bytes)
        if (slippageWad_ > type(uint248).max) {
            revert UniversalTokenSwapperSubstrateLibSlippageOverflow(slippageWad_);
        }
        encoded = bytes32(uint256(UniversalTokenSwapperSubstrateType.Slippage) << 248) | bytes32(slippageWad_);
    }

    /// @notice Decodes the substrate type from encoded bytes32
    /// @param substrate_ The encoded substrate
    /// @return substrateType The decoded substrate type
    function decodeSubstrateType(
        bytes32 substrate_
    ) internal pure returns (UniversalTokenSwapperSubstrateType substrateType) {
        // Extract the most significant byte
        substrateType = UniversalTokenSwapperSubstrateType(uint8(uint256(substrate_) >> 248));
    }

    /// @notice Decodes a token address from an encoded substrate
    /// @dev Should only be called when substrate type is Token
    /// @param substrate_ The encoded substrate
    /// @return token The decoded token address
    function decodeToken(bytes32 substrate_) internal pure returns (address token) {
        // Extract the last 20 bytes (160 bits)
        token = address(uint160(uint256(substrate_)));
    }

    /// @notice Decodes a target address from an encoded substrate
    /// @dev Should only be called when substrate type is Target
    /// @param substrate_ The encoded substrate
    /// @return target The decoded target address
    function decodeTarget(bytes32 substrate_) internal pure returns (address target) {
        // Extract the last 20 bytes (160 bits)
        target = address(uint160(uint256(substrate_)));
    }

    /// @notice Decodes a slippage value from an encoded substrate
    /// @dev Should only be called when substrate type is Slippage
    /// @param substrate_ The encoded substrate
    /// @return slippageWad The decoded slippage value in WAD
    function decodeSlippage(bytes32 substrate_) internal pure returns (uint256 slippageWad) {
        // Extract the last 31 bytes (248 bits) - mask out the type byte
        slippageWad = uint256(substrate_) & type(uint248).max;
    }

    /// @notice Checks if the substrate is a token substrate
    /// @param substrate_ The encoded substrate
    /// @return isToken True if the substrate is a token substrate
    function isTokenSubstrate(bytes32 substrate_) internal pure returns (bool isToken) {
        isToken = decodeSubstrateType(substrate_) == UniversalTokenSwapperSubstrateType.Token;
    }

    /// @notice Checks if the substrate is a target substrate
    /// @param substrate_ The encoded substrate
    /// @return isTarget True if the substrate is a target substrate
    function isTargetSubstrate(bytes32 substrate_) internal pure returns (bool isTarget) {
        isTarget = decodeSubstrateType(substrate_) == UniversalTokenSwapperSubstrateType.Target;
    }

    /// @notice Checks if the substrate is a slippage substrate
    /// @param substrate_ The encoded substrate
    /// @return isSlippage True if the substrate is a slippage substrate
    function isSlippageSubstrate(bytes32 substrate_) internal pure returns (bool isSlippage) {
        isSlippage = decodeSubstrateType(substrate_) == UniversalTokenSwapperSubstrateType.Slippage;
    }
}
