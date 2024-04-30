// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";

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
        PlasmaVaultStorageLib.GrantedAddressesToInteractWithVault storage accessControl = PlasmaVaultStorageLib
            .getGrantedAddressesToInteractWithVault();
        accessControl.value[account] = 1;
        emit AccessGrantedToVault(account);
    }

    function revokeAccessToVault(address account) internal {
        if (account == address(0)) {
            revert WrongAddress();
        }
        PlasmaVaultStorageLib.GrantedAddressesToInteractWithVault storage accessControl = PlasmaVaultStorageLib
            .getGrantedAddressesToInteractWithVault();
        accessControl.value[account] = 0;
        emit AccessRevokedToVault(account);
    }

    function isAccessGrantedToVault(address account) internal view returns (bool) {
        if (
            PlasmaVaultStorageLib.getGrantedAddressesToInteractWithVault().value[address(0)] == 0 ||
            PlasmaVaultStorageLib.getGrantedAddressesToInteractWithVault().value[account] == 1
        ) {
            return true;
        }
        revert NoAccessToVault(account);
    }

    function activateAccessControl() internal {
        PlasmaVaultStorageLib.getGrantedAddressesToInteractWithVault().value[address(0)] = 1;
        emit AccessControlActivated();
    }

    function deactivateAccessControl() internal {
        PlasmaVaultStorageLib.getGrantedAddressesToInteractWithVault().value[address(0)] = 0;
        emit AccessControlDeactivated();
    }

    function isControlAccessActivated() internal view returns (bool) {
        return PlasmaVaultStorageLib.getGrantedAddressesToInteractWithVault().value[address(0)] == 1;
    }
}
