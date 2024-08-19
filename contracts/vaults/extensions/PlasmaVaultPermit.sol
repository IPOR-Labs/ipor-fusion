// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {PlasmaVault, PlasmaVaultInitData} from "../PlasmaVault.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

/// @title PlasmaVault combined with ERC20Permit
abstract contract PlasmaVaultPermit is PlasmaVault, ERC20PermitUpgradeable {
    constructor(PlasmaVaultInitData memory initData_) PlasmaVault(initData_) ERC20PermitUpgradeable() initializer {
        super.__ERC20Permit_init(initData_.assetName);
    }

    function decimals() public view override(ERC20Upgradeable, PlasmaVault) returns (uint8) {
        return PlasmaVault.decimals();
    }

    function transfer(
        address to_,
        uint256 value_
    ) public virtual override(ERC20Upgradeable, PlasmaVault) restricted returns (bool) {
        return PlasmaVault.transfer(to_, value_);
    }

    function transferFrom(
        address from_,
        address to_,
        uint256 value_
    ) public virtual override(ERC20Upgradeable, PlasmaVault) restricted returns (bool) {
        return PlasmaVault.transferFrom(from_, to_, value_);
    }

    function _contextSuffixLength() internal view virtual override(PlasmaVault, ContextUpgradeable) returns (uint256) {
        return super._contextSuffixLength();
    }
    function _msgSender() internal view virtual override(PlasmaVault, ContextUpgradeable) returns (address) {
        return super._msgSender();
    }

    function _msgData() internal view virtual override(PlasmaVault, ContextUpgradeable) returns (bytes calldata) {
        return super._msgData();
    }
}
