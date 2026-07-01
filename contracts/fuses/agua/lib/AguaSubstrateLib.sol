// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../../libraries/PlasmaVaultConfigLib.sol";

/// @notice Type discriminator for Agua substrate addresses
enum AguaSubstrateType {
    UNDEFINED, // 0 - invalid
    VAULT, // 1 - Agua Global Carry Vault address (also its own share token)
    ASSET // 2 - allowed deposit/redemption asset (e.g. USDC)
}

/// @notice Agua substrate containing type and address
struct AguaSubstrate {
    AguaSubstrateType substrateType;
    address substrateAddress;
}

/// @title AguaSubstrateLib
/// @notice Library for encoding, decoding, and validating Agua typed substrates
/// @dev Follows the same pattern as MidasSubstrateLib.
///      Encoding layout: [type (96 bits) | address (160 bits)]
library AguaSubstrateLib {
    /// @notice Thrown when a substrate is not granted for the market
    /// @param substrateType The substrate type discriminator
    /// @param substrateAddress The substrate address that is not granted
    error AguaFuseUnsupportedSubstrate(uint8 substrateType, address substrateAddress);

    /// @notice Encode an AguaSubstrate into bytes32
    /// @param substrate_ The substrate to encode
    /// @return The bytes32 encoded substrate
    function substrateToBytes32(AguaSubstrate memory substrate_) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(substrate_.substrateAddress)) | (uint256(substrate_.substrateType) << 160));
    }

    /// @notice Decode a bytes32 into an AguaSubstrate
    /// @param bytes32Substrate_ The bytes32 encoded substrate
    /// @return substrate The decoded AguaSubstrate
    function bytes32ToSubstrate(bytes32 bytes32Substrate_) internal pure returns (AguaSubstrate memory substrate) {
        substrate.substrateType = AguaSubstrateType(uint256(bytes32Substrate_) >> 160);
        substrate.substrateAddress = PlasmaVaultConfigLib.bytes32ToAddress(bytes32Substrate_);
    }

    /// @notice Validate that a vault address is granted as a substrate for the market
    /// @param marketId_ The market ID
    /// @param vault_ The Agua vault address to validate
    function validateVaultGranted(uint256 marketId_, address vault_) internal view {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                marketId_,
                substrateToBytes32(AguaSubstrate({substrateType: AguaSubstrateType.VAULT, substrateAddress: vault_}))
            )
        ) {
            revert AguaFuseUnsupportedSubstrate(uint8(AguaSubstrateType.VAULT), vault_);
        }
    }

    /// @notice Validate that an asset address is granted as a substrate for the market
    /// @param marketId_ The market ID
    /// @param asset_ The asset address to validate (e.g. USDC)
    function validateAssetGranted(uint256 marketId_, address asset_) internal view {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                marketId_,
                substrateToBytes32(AguaSubstrate({substrateType: AguaSubstrateType.ASSET, substrateAddress: asset_}))
            )
        ) {
            revert AguaFuseUnsupportedSubstrate(uint8(AguaSubstrateType.ASSET), asset_);
        }
    }
}
