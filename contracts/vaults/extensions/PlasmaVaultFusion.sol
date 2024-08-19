// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {PlasmaVault, PlasmaVaultInitData} from "../PlasmaVault.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/// @title PlasmaVault combined with ERC20Permit and ERC20Votes
abstract contract PlasmaVaultFusion is PlasmaVault, ERC20Permit {
    using Address for address;

    constructor(PlasmaVaultInitData memory initData_) PlasmaVault(initData_) ERC20Permit(initData_.assetName) {}

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

    function _fallback() internal override returns (bytes memory) {
        console2.log("PlasmaVaultFusion._fallback");
        //        calls_[i].fuse.functionDelegateCall(calls_[i].data);
        return PlasmaVaultLib.getPlasmaVaultBaseAddress().functionDelegateCall(msg.data);
    }
}
