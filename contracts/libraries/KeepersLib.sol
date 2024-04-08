// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {VaultStorageLib} from "./VaultStorageLib.sol";

library KeepersLib {
    function grantKeeper(address keeper) internal {
        VaultStorageLib.Keepers storage keepers = VaultStorageLib.getKeepers();
        keepers.value[keeper] = 1;
    }

    function revokeKeeper(address keeper) internal {
        VaultStorageLib.Keepers storage keepers = VaultStorageLib.getKeepers();
        keepers.value[keeper] = 0;
    }

    function isKeeperGranted(address keeper) internal view returns (bool) {
        return VaultStorageLib.getKeepers().value[keeper] == 1;
    }
}
