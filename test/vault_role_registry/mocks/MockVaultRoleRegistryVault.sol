// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title MockVaultRoleRegistryVault
/// @author IPOR Labs
/// @notice Minimal vault stub exposing the access manager of a real IporFusionAccessManager.
contract MockVaultRoleRegistryVault {
    address private immutable ACCESS_MANAGER;

    /// @notice Sets the access manager exposed by both getters.
    /// @param manager_ Vault access manager; may be zero to simulate a vault without authority.
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
