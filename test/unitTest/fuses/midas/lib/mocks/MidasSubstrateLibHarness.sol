// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {MidasSubstrateLib, MidasSubstrate, MidasSubstrateType} from "contracts/fuses/midas/lib/MidasSubstrateLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";

/// @title MidasSubstrateLibHarness
/// @notice Test harness that exposes MidasSubstrateLib internal functions as external calls.
///         Also exposes grantMarketSubstrates so tests can set up diamond storage directly.
contract MidasSubstrateLibHarness {
    // ============ Pure encoding/decoding wrappers ============

    function substrateToBytes32(MidasSubstrate memory substrate_) external pure returns (bytes32) {
        return MidasSubstrateLib.substrateToBytes32(substrate_);
    }

    function bytes32ToSubstrate(bytes32 bytes32Substrate_) external pure returns (MidasSubstrate memory) {
        return MidasSubstrateLib.bytes32ToSubstrate(bytes32Substrate_);
    }

    // ============ Validation wrappers ============

    function validateMTokenGranted(uint256 marketId_, address mToken_) external view {
        MidasSubstrateLib.validateMTokenGranted(marketId_, mToken_);
    }

    function validateDepositVaultGranted(uint256 marketId_, address depositVault_) external view {
        MidasSubstrateLib.validateDepositVaultGranted(marketId_, depositVault_);
    }

    function validateRedemptionVaultGranted(uint256 marketId_, address redemptionVault_) external view {
        MidasSubstrateLib.validateRedemptionVaultGranted(marketId_, redemptionVault_);
    }

    function validateInstantRedemptionVaultGranted(uint256 marketId_, address instantRedemptionVault_) external view {
        MidasSubstrateLib.validateInstantRedemptionVaultGranted(marketId_, instantRedemptionVault_);
    }

    function validateAssetGranted(uint256 marketId_, address asset_) external view {
        MidasSubstrateLib.validateAssetGranted(marketId_, asset_);
    }

    // ============ Storage helpers ============

    /// @notice Grant substrates to a market in diamond storage (for test setup)
    function grantMarketSubstrates(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }
}
