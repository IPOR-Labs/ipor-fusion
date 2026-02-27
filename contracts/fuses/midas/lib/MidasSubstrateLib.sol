// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../../libraries/PlasmaVaultConfigLib.sol";

/// @notice Type discriminator for Midas substrate addresses
enum MidasSubstrateType {
    UNDEFINED, // 0 - invalid
    M_TOKEN, // 1 - mTBILL, mBASIS token address
    DEPOSIT_VAULT, // 2 - Midas Deposit Vault (for depositInstant / depositRequest)
    REDEMPTION_VAULT, // 3 - Midas Standard Redemption Vault (for redeemRequest)
    INSTANT_REDEMPTION_VAULT, // 4 - Midas Instant Redemption Vault (for redeemInstant)
    ASSET // 5 - Allowed deposit/withdrawal asset (e.g., USDC)
}

/// @notice Midas substrate containing type and address
struct MidasSubstrate {
    MidasSubstrateType substrateType;
    address substrateAddress;
}

/// @title MidasSubstrateLib
/// @notice Library for encoding, decoding, and validating Midas typed substrates
/// @dev Follows the same pattern as BalancerSubstrateLib and AerodromeSubstrateLib.
///      Encoding layout: [type (96 bits) | address (160 bits)]
library MidasSubstrateLib {
    error MidasFuseUnsupportedSubstrate(uint8 substrateType, address substrateAddress);

    /// @notice Encode a MidasSubstrate into bytes32
    /// @param substrate_ The substrate to encode
    /// @return The bytes32 encoded substrate
    function substrateToBytes32(MidasSubstrate memory substrate_) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(substrate_.substrateAddress)) | (uint256(substrate_.substrateType) << 160));
    }

    /// @notice Decode a bytes32 into a MidasSubstrate
    /// @param bytes32Substrate_ The bytes32 encoded substrate
    /// @return substrate The decoded MidasSubstrate
    function bytes32ToSubstrate(bytes32 bytes32Substrate_) internal pure returns (MidasSubstrate memory substrate) {
        substrate.substrateType = MidasSubstrateType(uint256(bytes32Substrate_) >> 160);
        substrate.substrateAddress = PlasmaVaultConfigLib.bytes32ToAddress(bytes32Substrate_);
    }

    /// @notice Validate that an mToken address is granted as a substrate for the market
    /// @param marketId_ The market ID
    /// @param mToken_ The mToken address to validate
    function validateMTokenGranted(uint256 marketId_, address mToken_) internal view {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                marketId_,
                substrateToBytes32(
                    MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: mToken_})
                )
            )
        ) {
            revert MidasFuseUnsupportedSubstrate(uint8(MidasSubstrateType.M_TOKEN), mToken_);
        }
    }

    /// @notice Validate that a deposit vault address is granted as a substrate for the market
    /// @param marketId_ The market ID
    /// @param depositVault_ The deposit vault address to validate
    function validateDepositVaultGranted(uint256 marketId_, address depositVault_) internal view {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                marketId_,
                substrateToBytes32(
                    MidasSubstrate({
                        substrateType: MidasSubstrateType.DEPOSIT_VAULT,
                        substrateAddress: depositVault_
                    })
                )
            )
        ) {
            revert MidasFuseUnsupportedSubstrate(uint8(MidasSubstrateType.DEPOSIT_VAULT), depositVault_);
        }
    }

    /// @notice Validate that a standard redemption vault address is granted as a substrate for the market
    /// @param marketId_ The market ID
    /// @param redemptionVault_ The redemption vault address to validate
    function validateRedemptionVaultGranted(uint256 marketId_, address redemptionVault_) internal view {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                marketId_,
                substrateToBytes32(
                    MidasSubstrate({
                        substrateType: MidasSubstrateType.REDEMPTION_VAULT,
                        substrateAddress: redemptionVault_
                    })
                )
            )
        ) {
            revert MidasFuseUnsupportedSubstrate(uint8(MidasSubstrateType.REDEMPTION_VAULT), redemptionVault_);
        }
    }

    /// @notice Validate that an instant redemption vault address is granted as a substrate for the market
    /// @param marketId_ The market ID
    /// @param instantRedemptionVault_ The instant redemption vault address to validate
    function validateInstantRedemptionVaultGranted(uint256 marketId_, address instantRedemptionVault_) internal view {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                marketId_,
                substrateToBytes32(
                    MidasSubstrate({
                        substrateType: MidasSubstrateType.INSTANT_REDEMPTION_VAULT,
                        substrateAddress: instantRedemptionVault_
                    })
                )
            )
        ) {
            revert MidasFuseUnsupportedSubstrate(
                uint8(MidasSubstrateType.INSTANT_REDEMPTION_VAULT), instantRedemptionVault_
            );
        }
    }

    /// @notice Validate that an asset address is granted as a substrate for the market
    /// @param marketId_ The market ID
    /// @param asset_ The asset address to validate (e.g., USDC)
    function validateAssetGranted(uint256 marketId_, address asset_) internal view {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                marketId_,
                substrateToBytes32(
                    MidasSubstrate({substrateType: MidasSubstrateType.ASSET, substrateAddress: asset_})
                )
            )
        ) {
            revert MidasFuseUnsupportedSubstrate(uint8(MidasSubstrateType.ASSET), asset_);
        }
    }
}
