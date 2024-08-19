// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {PlasmaVault, PlasmaVaultInitData} from "../PlasmaVault.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
/// @title PlasmaVault combined with ERC20Permit and ERC20Votes
abstract contract PlasmaVaultFusion is PlasmaVault, ERC20PermitUpgradeable {
    using Address for address;

    constructor(PlasmaVaultInitData memory initData_) PlasmaVault(initData_) ERC20PermitUpgradeable() initializer {
        super.__ERC20_init(initData_.assetName, initData_.assetSymbol);
        super.__ERC4626_init(IERC20(initData_.underlyingToken));
        super.__ERC20Permit_init(initData_.assetName);
    }

    function decimals() public view override(ERC20Upgradeable, PlasmaVault) returns (uint8) {
        return PlasmaVault.decimals();
    }

    function transfer(
        address to_,
        uint256 value_
    ) public virtual override(ERC20Upgradeable, PlasmaVault) restricted returns (bool) {
        console2.log("PlasmaVaultFusion.transfer, to_=", to_);
        console2.log("PlasmaVaultFusion.transfer, value_=", value_);
        return PlasmaVault.transfer(to_, value_);
    }

    function transferFrom(
        address from_,
        address to_,
        uint256 value_
    ) public virtual override(ERC20Upgradeable, PlasmaVault) restricted returns (bool) {
        console2.log("PlasmaVaultFusion.transferFrom, to_=", to_);
        console2.log("PlasmaVaultFusion.transferFrom, value_=", value_);
        return PlasmaVault.transferFrom(from_, to_, value_);
    }

    function _fallback() internal override returns (bytes memory) {
        console2.log("PlasmaVaultFusion._fallback, msg.sender=", msg.sender);
        console2.logBytes4(msg.sig);
        return PLASMA_VAULT_BASE.functionDelegateCall(msg.data);
    }

    function _update(address from_, address to_, uint256 value_) internal virtual override(ERC20Upgradeable) {
        super._update(from_, to_, value_);
        console2.log("PlasmaVaultFusion._update, to_=", to_);
        console2.log("PlasmaVaultFusion._update, value_=", value_);
        console2.log("PlasmaVaultFusion._update, PLASMA_VAULT_BASE=", PLASMA_VAULT_BASE);
        console2.log("PlasmaVaultFusion._update, address(this)=", address(this));
        console2.log("PlasmaVaultFusion._update, totalSupply=", ERC20Upgradeable(address(this)).totalSupply());
        PLASMA_VAULT_BASE.functionDelegateCall(
            abi.encodeWithSignature("updateInternal(address,address,uint256)", from_, to_, value_)
        );
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

    //
    //    function nonces(address owner_) public view override(ERC20Permit, Nonces) returns (uint256) {
    //        return super.nonces(owner_);
    //    }
}
