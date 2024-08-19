// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {PlasmaVault, PlasmaVaultInitData} from "./PlasmaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract IporPlasmaVault is PlasmaVault {
    constructor(PlasmaVaultInitData memory initData_) PlasmaVault(initData_) initializer {
        super.__ERC20_init(initData_.assetName, initData_.assetSymbol);
        super.__ERC4626_init(IERC20(initData_.underlyingToken));
    }

    function _fallback() internal override returns (bytes memory) {
        return "";
    }
}
