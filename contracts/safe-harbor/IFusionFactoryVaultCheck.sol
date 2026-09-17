// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title IFusionFactoryVaultCheck
 * @author IPOR Labs
 * @notice Minimal view of the FusionFactory used to verify that an address is a genuine IPOR Fusion Plasma Vault
 * @dev `isFusionVault` is introduced by IL-8227. Factory deployments predating that version do not expose the
 * selector; callers must treat a reverting call as "not a Fusion vault" and rely on a manual allowlist instead.
 */
interface IFusionFactoryVaultCheck {
    /// @notice Returns true when the given address is a Plasma Vault deployed by the FusionFactory
    /// @param vault_ The address to check
    /// @return isVault True when the address is a genuine Fusion vault
    function isFusionVault(address vault_) external view returns (bool isVault);
}
