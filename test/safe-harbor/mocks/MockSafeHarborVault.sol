// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title MockSafeHarborVault
/// @author IPOR Labs
/// @notice Minimal vault role-routing stub backed by a real IporFusionAccessManager.
contract MockSafeHarborVault {
    address private immutable ACCESS_MANAGER;

    /// @notice Sets the access manager exposed by both PlasmaVault getter paths.
    /// @param manager_ Vault access manager.
    constructor(address manager_) {
        ACCESS_MANAGER = manager_;
    }

    /// @notice Mirrors PlasmaVault's inherited AccessManaged authority getter.
    /// @return Vault access manager.
    function authority() external view returns (address) {
        return ACCESS_MANAGER;
    }

    /// @notice Mirrors the PlasmaVaultGovernance getter for the same authority.
    /// @return Vault access manager.
    function getAccessManagerAddress() external view returns (address) {
        return ACCESS_MANAGER;
    }
}
