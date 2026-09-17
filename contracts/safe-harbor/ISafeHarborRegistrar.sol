// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

// solhint-disable gas-indexed-events
// IPOR Fusion convention: event parameters are never `indexed`, all values are kept in the data section.

/**
 * @title ISafeHarborRegistrar
 * @author IPOR Labs
 * @notice Interface of the SafeHarborRegistrar - owner-gated per-vault opt-in/opt-out of the SEAL Safe Harbor
 * Agreement adopted by IPOR. Vault owners (OWNER_ROLE on the vault's IporFusionAccessManager) decide alone whether
 * their Plasma Vault is covered by the Agreement; the Registrar owner (IPOR multisig) curates eligibility (manual
 * allowlist next to the FusionFactory check), holds the Agreement ownership on IPOR's behalf and can force-remove any
 * entry.
 */
interface ISafeHarborRegistrar {
    /// @notice Emitted when a vault is added to or removed from the Agreement
    /// @param vault The Plasma Vault whose participation changed
    /// @param enabled True when the vault was added to the Agreement, false when it was removed
    /// @param caller The account that triggered the change (vault owner or Registrar owner)
    event ParticipationChanged(address vault, bool enabled, address caller);

    /// @notice Emitted when the Registrar owner updates the manual allowlist entry of a vault
    /// @param vault The vault whose allowlist entry changed
    /// @param allowed True when the vault is now allowlisted, false when it is not
    event ManualAllowlistUpdated(address vault, bool allowed);

    /// @notice Emitted when the Registrar starts managing a different Agreement
    /// @param oldAgreement The previously managed Agreement
    /// @param newAgreement The newly managed Agreement
    event AgreementUpdated(address oldAgreement, address newAgreement);

    /// @notice Emitted when the Registrar hands the Agreement ownership over to another account
    /// @param agreement The Agreement whose ownership was transferred
    /// @param newOwner The new owner of the Agreement
    event AgreementOwnershipTransferred(address agreement, address newOwner);

    /// @notice Emitted when the asset recovery address used for (re)creating the chain entry changes
    /// @param assetRecoveryAddress The new asset recovery address (string, as stored in the Agreement)
    event AssetRecoveryAddressUpdated(string assetRecoveryAddress);

    /// @notice Thrown when the caller does not hold OWNER_ROLE on the AccessManager returned by the vault's
    /// `authority()`
    /// @param vault The vault the caller tried to manage
    /// @param caller The rejected caller
    error NotVaultOwner(address vault, address caller);

    /// @notice Thrown when the address is neither reported by the FusionFactory nor manually allowlisted
    /// @param vault The rejected address
    error NotFusionVault(address vault);

    /// @notice Thrown when the vault's `authority()` returns the zero address
    /// @param vault The vault without an access manager
    error NoAccessManager(address vault);

    /// @notice Thrown when opting in a vault that is already listed in the Agreement for this chain
    /// @param vault The vault already participating
    error AlreadyParticipating(address vault);

    /// @notice Thrown when opting out or force-removing a vault that is not listed in the Agreement for this chain
    /// @param vault The vault not participating
    error NotParticipating(address vault);

    /// @notice Thrown when the Registrar is not the owner of the managed Agreement and thus cannot modify it
    /// @param agreement The managed Agreement
    /// @param currentOwner The current owner of the Agreement
    error AgreementNotOwnedByRegistrar(address agreement, address currentOwner);

    /// @notice Thrown when an empty asset recovery address string is provided
    error EmptyAssetRecoveryAddress();

    /// @notice Thrown when attempting to renounce ownership, which is disabled
    error RenounceOwnershipDisabled();

    /// @notice Thrown when the Agreement returns ABI data that cannot be walked safely (offset out of bounds)
    error MalformedAgreementData();

    /// @notice Adds the vault to or removes it from the Agreement on the current chain
    /// @param vault_ The Plasma Vault, must be eligible (manual allowlist or FusionFactory `isFusionVault`)
    /// @param enabled_ True to opt in (add with ChildContractScope.None), false to opt out (remove)
    function setParticipation(address vault_, bool enabled_) external;

    /// @notice Removes a vault from the Agreement regardless of the vault's own governance
    /// @param vault_ The vault to remove
    function forceRemove(address vault_) external;

    /// @notice Sets the manual allowlist entry of a vault deployed before the factory exposed `isFusionVault`
    /// @param vault_ The vault address
    /// @param allowed_ True to allowlist, false to remove from the allowlist
    function setManualAllowlist(address vault_, bool allowed_) external;

    /// @notice Sets the manual allowlist entry of several vaults in one atomic transaction
    /// @param vaults_ The vault addresses, non-empty, every entry non-zero
    /// @param allowed_ True to allowlist, false to remove from the allowlist
    function setManualAllowlistBatch(address[] calldata vaults_, bool allowed_) external;

    /// @notice Points the Registrar at a different Agreement, without migrating participants
    /// @param newAgreement_ The new Agreement address
    function setAgreement(address newAgreement_) external;

    /// @notice Transfers the ownership of the managed Agreement to another account
    /// @param newOwner_ The new owner of the Agreement
    function transferAgreementOwnership(address newOwner_) external;

    /// @notice Sets the asset recovery address used when the Registrar has to (re)create the chain entry
    /// @param assetRecoveryAddress_ The recovery address as a non-empty string
    function setAssetRecoveryAddress(string calldata assetRecoveryAddress_) external;

    /// @notice Returns true when the vault is listed in the Agreement for the current chain
    /// @param vault_ The vault to check
    /// @return participating True when at least one account entry matches the vault address
    function isParticipating(address vault_) external view returns (bool participating);

    /// @notice Returns true when the address is eligible (manual allowlist or FusionFactory `isFusionVault`)
    /// @param vault_ The address to check
    /// @return eligible True when the vault may be opted in
    function isEligibleVault(address vault_) external view returns (bool eligible);

    /// @notice Returns true when the vault is on the manual allowlist
    /// @param vault_ The vault to check
    /// @return allowed True when allowlisted
    function isManualAllowlisted(address vault_) external view returns (bool allowed);

    /// @notice Returns the FusionFactory used for vault verification (zero when not configured)
    /// @return fusionFactory The FusionFactory address
    function getFusionFactory() external view returns (address fusionFactory);

    /// @notice Returns the managed Agreement address
    /// @return agreement The Agreement address
    function getAgreement() external view returns (address agreement);

    /// @notice Returns the CAIP-2 chain id of the chain the Registrar is deployed on, e.g. "eip155:1"
    /// @return caip2ChainId The CAIP-2 chain id
    function getCaip2ChainId() external view returns (string memory caip2ChainId);

    /// @notice Returns the asset recovery address used when (re)creating the chain entry in the Agreement
    /// @return assetRecoveryAddress The recovery address string
    function getAssetRecoveryAddress() external view returns (string memory assetRecoveryAddress);
}
