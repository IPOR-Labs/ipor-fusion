// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";

library AlphasLib {
    event AlphaGranted(address alpha);
    event AlphaRevoked(address alpha);

    function isAlphaGranted(address alpha) internal view returns (bool) {
        return PlasmaVaultStorageLib.getAlphas().value[alpha] == 1;
    }

    function grantAlpha(address alpha) internal {
        PlasmaVaultStorageLib.Alphas storage alphas = PlasmaVaultStorageLib.getAlphas();
        alphas.value[alpha] = 1;
        emit AlphaGranted(alpha);
    }

    function revokeAlpha(address alpha) internal {
        PlasmaVaultStorageLib.Alphas storage alphas = PlasmaVaultStorageLib.getAlphas();
        alphas.value[alpha] = 0;
        emit AlphaRevoked(alpha);
    }
}
