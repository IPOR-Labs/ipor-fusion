// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {PlasmaVault, PlasmaVaultInitData} from "../PlasmaVault.sol";

/// @notice Abstract for PlasmaVault where is fusion of ERC20, ERC4626, ERC20Permit, ERC20Votes standards.
abstract contract PlasmaVaultVotes is PlasmaVault, ERC20Votes {
    constructor(PlasmaVaultInitData memory initData_) PlasmaVault(initData_) {}

    function decimals() public view override(ERC20, PlasmaVault) returns (uint8) {
        return PlasmaVault.decimals();
    }

    function transfer(
        address to_,
        uint256 value_
    ) public virtual override(ERC20, PlasmaVault) restricted returns (bool) {
        return PlasmaVault.transfer(to_, value_);
    }

    function transferFrom(
        address from_,
        address to_,
        uint256 value_
    ) public virtual override(ERC20, PlasmaVault) restricted returns (bool) {
        return PlasmaVault.transferFrom(from_, to_, value_);
    }

    function nonces(address owner_) public view override returns (uint256) {
        return super.nonces(owner_);
    }

    function _update(address from_, address to_, uint256 amount_) internal override(ERC20, ERC20Votes) {
        ERC20Votes._update(from_, to_, amount_);
    }
}
