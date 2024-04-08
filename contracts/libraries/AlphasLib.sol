// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {PlazmaVaultStorageLib} from "./PlazmaVaultStorageLib.sol";

//TODO: wait for confirmation the name to Alpha instead of Alpha
library AlphasLib {
    function grantAlpha(address alpha) internal {
        PlazmaVaultStorageLib.Alphas storage alphas = PlazmaVaultStorageLib.getAlphas();
        alphas.value[alpha] = 1;
    }

    function revokeAlpha(address alpha) internal {
        PlazmaVaultStorageLib.Alphas storage alphas = PlazmaVaultStorageLib.getAlphas();
        alphas.value[alpha] = 0;
    }

    function isAlphaGranted(address alpha) internal view returns (bool) {
        return PlazmaVaultStorageLib.getAlphas().value[alpha] == 1;
    }
}
