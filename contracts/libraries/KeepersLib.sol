// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {StorageLib} from "./StorageLib.sol";

library KeepersLib {
    function grantKeeper(address keeper) internal {
        StorageLib.Keepers storage keepers = StorageLib.getKeepers();
        keepers.value[keeper] = 1;
    }

    function revokeKeeper(address keeper) internal {
        StorageLib.Keepers storage keepers = StorageLib.getKeepers();
        keepers.value[keeper] = 0;
    }

    function isKeeperGranted(address keeper) internal view returns (bool) {
        return StorageLib.getKeepers().value[keeper] == 1;
    }
}