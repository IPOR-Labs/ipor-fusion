// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title LegacyFactoryWithoutVaultCheck
/// @author IPOR Labs
/// @notice Deployed code without the future isFusionVault selector.
contract LegacyFactoryWithoutVaultCheck {
    /// @notice Exposes unrelated legacy functionality but no isFusionVault selector or fallback.
    /// @return Fixture version.
    function getFusionFactoryVersion() external pure returns (uint256) {
        return 1;
    }
}
