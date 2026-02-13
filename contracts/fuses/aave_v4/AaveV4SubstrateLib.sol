// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title AaveV4SubstrateType
/// @notice Type flag for Aave V4 substrate encoding
/// @dev Stored in the most significant byte (bits 255..248) of the bytes32 substrate
enum AaveV4SubstrateType {
    /// @dev 0 - Invalid/undefined (default Solidity zero value)
    Undefined,
    /// @dev 1 - ERC20 token address
    Asset,
    /// @dev 2 - Aave V4 Spoke contract address
    Spoke
}

/// @title AaveV4SubstrateLib
/// @author IPOR Labs
/// @notice Encoding and decoding of typed substrates for Aave V4 integration
/// @dev Substrate layout (bytes32):
///      +----------+---------------------------+---------------------+
///      | Bits     | 255..248 (8 bits)         | 247..0 (248 bits)   |
///      +----------+---------------------------+---------------------+
///      | Content  | Type flag (uint8)         | Padded address data |
///      +----------+---------------------------+---------------------+
///      Address occupies bits 159..0 (20 bytes), bits 247..160 are zero padding.
///      Flag 0 (Undefined) ensures uninitialized bytes32 is automatically invalid.
library AaveV4SubstrateLib {
    uint256 private constant _FLAG_SHIFT = 248;

    /// @notice Encodes an ERC20 token address as an Asset substrate
    /// @param token_ The address of the ERC20 token
    /// @return The encoded bytes32 substrate with Asset type flag
    function encodeAsset(address token_) internal pure returns (bytes32) {
        return bytes32(uint256(AaveV4SubstrateType.Asset) << _FLAG_SHIFT | uint256(uint160(token_)));
    }

    /// @notice Encodes an Aave V4 Spoke contract address as a Spoke substrate
    /// @param spoke_ The address of the Spoke contract
    /// @return The encoded bytes32 substrate with Spoke type flag
    function encodeSpoke(address spoke_) internal pure returns (bytes32) {
        return bytes32(uint256(AaveV4SubstrateType.Spoke) << _FLAG_SHIFT | uint256(uint160(spoke_)));
    }

    /// @notice Decodes the type flag from a substrate
    /// @param substrate_ The encoded bytes32 substrate
    /// @return The substrate type (Undefined, Asset, or Spoke)
    function decodeSubstrateType(bytes32 substrate_) internal pure returns (AaveV4SubstrateType) {
        uint8 flag = uint8(uint256(substrate_) >> _FLAG_SHIFT);
        if (flag > uint8(type(AaveV4SubstrateType).max)) {
            return AaveV4SubstrateType.Undefined;
        }
        return AaveV4SubstrateType(flag);
    }

    /// @notice Decodes the address from a substrate
    /// @param substrate_ The encoded bytes32 substrate
    /// @return The decoded address (lower 160 bits)
    function decodeAddress(bytes32 substrate_) internal pure returns (address) {
        return address(uint160(uint256(substrate_)));
    }

    /// @notice Checks if a substrate is an Asset type
    /// @param substrate_ The encoded bytes32 substrate
    /// @return True if the substrate has the Asset type flag
    function isAssetSubstrate(bytes32 substrate_) internal pure returns (bool) {
        return uint8(uint256(substrate_) >> _FLAG_SHIFT) == uint8(AaveV4SubstrateType.Asset);
    }

    /// @notice Checks if a substrate is a Spoke type
    /// @param substrate_ The encoded bytes32 substrate
    /// @return True if the substrate has the Spoke type flag
    function isSpokeSubstrate(bytes32 substrate_) internal pure returns (bool) {
        return uint8(uint256(substrate_) >> _FLAG_SHIFT) == uint8(AaveV4SubstrateType.Spoke);
    }
}
