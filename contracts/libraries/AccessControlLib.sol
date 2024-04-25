// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {PlazmaVaultStorageLib} from "./PlazmaVaultStorageLib.sol";

library AccessControlLib {
    event AccessGrantedToVault(address indexed account);
    event AccessRevokedToVault(address indexed account);
    event AccessControlActivated();
    event AccessControlDeactivated();

    error WrongAddress();
    error NoAccessToVault(address account);

    function grantAccessToVault(address account) internal {
        if (account == address(0)) {
            revert WrongAddress();
        }
        PlazmaVaultStorageLib.GrantedAddressesToInteractWithVault storage accessControl = PlazmaVaultStorageLib
            .getGrantedAddressesToInteractWithVault();
        accessControl.value[account] = 1;
        emit AccessGrantedToVault(account);
    }

    function revokeAccessToVault(address account) internal {
        if (account == address(0)) {
            revert WrongAddress();
        }
        PlazmaVaultStorageLib.GrantedAddressesToInteractWithVault storage accessControl = PlazmaVaultStorageLib
            .getGrantedAddressesToInteractWithVault();
        accessControl.value[account] = 0;
        emit AccessRevokedToVault(account);
    }

    function isAccessGrantedToVault(address account) internal view returns (bool) {
        if (
            PlazmaVaultStorageLib.getGrantedAddressesToInteractWithVault().value[address(0)] == 0 ||
            PlazmaVaultStorageLib.getGrantedAddressesToInteractWithVault().value[account] == 1
        ) {
            return true;
        }
        revert NoAccessToVault(account);
    }

    function activateAccessControl() internal {
        PlazmaVaultStorageLib.getGrantedAddressesToInteractWithVault().value[address(0)] = 1;
        emit AccessControlActivated();
    }

    function deactivateAccessControl() internal {
        PlazmaVaultStorageLib.getGrantedAddressesToInteractWithVault().value[address(0)] = 0;
        emit AccessControlDeactivated();
    }

    function isControlAccessActivated() internal view returns (bool) {
        return PlazmaVaultStorageLib.getGrantedAddressesToInteractWithVault().value[address(0)] == 1;
    }
}
