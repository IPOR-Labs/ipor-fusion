// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {PlazmaVaultStorageLib} from "./PlazmaVaultStorageLib.sol";

//TODO: wait for confirmation the name to Alpha instead of Keeper
library KeepersLib {
    function grantKeeper(address keeper) internal {
        PlazmaVaultStorageLib.Keepers storage keepers = PlazmaVaultStorageLib.getKeepers();
        keepers.value[keeper] = 1;
    }

    function revokeKeeper(address keeper) internal {
        PlazmaVaultStorageLib.Keepers storage keepers = PlazmaVaultStorageLib.getKeepers();
        keepers.value[keeper] = 0;
    }

    function isKeeperGranted(address keeper) internal view returns (bool) {
        return PlazmaVaultStorageLib.getKeepers().value[keeper] == 1;
    }
}
