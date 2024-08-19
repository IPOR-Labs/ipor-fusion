// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {PlasmaVault, PlasmaVaultInitData} from "../PlasmaVault.sol";

/// @title PlasmaVault combined with ERC20Permit and ERC20Votes
abstract contract PlasmaVaultFusion is PlasmaVault {
    using Address for address;

    constructor(PlasmaVaultInitData memory initData_) PlasmaVault(initData_) {}

    function _update(address from_, address to_, uint256 value_) internal virtual override(ERC20Upgradeable) {
        PLASMA_VAULT_BASE.functionDelegateCall(
            abi.encodeWithSignature("updateInternal(address,address,uint256)", from_, to_, value_)
        );
    }
}
