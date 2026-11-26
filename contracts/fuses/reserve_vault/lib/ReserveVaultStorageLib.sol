// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title ReserveVaultStorageLib
/// @notice Principal ledger of a reserve vault: for each member vault, the amount of the member vault's asset that the
///         reserve vault deposited into it and has not withdrawn yet
/// @dev Runs in the reserve vault's delegatecall context (the supply fuse writes it, the balance fuse and the principal
///      reader read it). The ledger lives in an ERC-7201 namespace, so it cannot collide with PlasmaVault storage or with
///      the namespaces of other fuse families.
/// @dev Unit: the principal is an amount of the member vault's asset (`IERC4626(memberVault).asset()` decimals), not
///      shares and not USD.
/// @dev The principal never goes below zero: `decreasePrincipal` reverts with `ReserveVaultPrincipalUnderflow` instead
///      of clamping, so a caller can never silently book less than it asked to withdraw.
/// @dev The namespace id and the struct layout are frozen: a deployed reserve vault keeps its ledger at this slot.
/// @author IPOR Labs
library ReserveVaultStorageLib {
    /// @notice Thrown when a decrease would take the principal of a member vault below zero
    /// @param vault The member vault
    /// @param amount The requested decrease, in the member vault's asset
    /// @param principal The principal recorded for the member vault, in the member vault's asset
    error ReserveVaultPrincipalUnderflow(address vault, uint256 amount, uint256 principal);

    /// @dev Calculation: keccak256(abi.encode(uint256(keccak256("io.ipor.reserveVault.Principal")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant PRINCIPAL_SLOT = 0xfe3e36b7a79b299f7842403e054c98e2e5416e9781dec139f16800dec991f700;

    /// @dev Principal ledger of the reserve vault
    /// @custom:storage-location erc7201:io.ipor.reserveVault.Principal
    struct PrincipalStorage {
        /// @dev Member vault => principal deposited by the reserve vault and not withdrawn yet, in the member vault's asset
        mapping(address vault => uint256 principal) principals;
    }

    /// @notice Returns the principal recorded for a member vault
    /// @param vault_ The member vault
    /// @return The principal, in the member vault's asset; zero when nothing is recorded
    function getPrincipal(address vault_) internal view returns (uint256) {
        return _getPrincipalStorage().principals[vault_];
    }

    /// @notice Adds an amount to the principal of a member vault
    /// @param vault_ The member vault
    /// @param amount_ The amount to add, in the member vault's asset
    /// @return principal The principal after the increase
    function increasePrincipal(address vault_, uint256 amount_) internal returns (uint256 principal) {
        PrincipalStorage storage $ = _getPrincipalStorage();
        principal = $.principals[vault_] + amount_;
        $.principals[vault_] = principal;
    }

    /// @notice Subtracts an amount from the principal of a member vault
    /// @dev Reverts with `ReserveVaultPrincipalUnderflow` when `amount_` exceeds the recorded principal; the principal
    ///      is never clamped.
    /// @param vault_ The member vault
    /// @param amount_ The amount to subtract, in the member vault's asset
    /// @return principal The principal after the decrease
    function decreasePrincipal(address vault_, uint256 amount_) internal returns (uint256 principal) {
        PrincipalStorage storage $ = _getPrincipalStorage();
        uint256 current = $.principals[vault_];
        if (amount_ > current) {
            revert ReserveVaultPrincipalUnderflow(vault_, amount_, current);
        }
        unchecked {
            principal = current - amount_;
        }
        $.principals[vault_] = principal;
    }

    /// @notice Returns the storage pointer of the principal ledger
    /// @return storagePtr The principal ledger in the ERC-7201 namespace
    function _getPrincipalStorage() private pure returns (PrincipalStorage storage storagePtr) {
        assembly {
            storagePtr.slot := PRINCIPAL_SLOT
        }
    }
}
