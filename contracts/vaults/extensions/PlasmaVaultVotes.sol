// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {PlasmaVault, PlasmaVaultInitData} from "../PlasmaVault.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
/// @title PlasmaVault combined with ERC20Votes
abstract contract PlasmaVaultVotes is PlasmaVault, ERC20VotesUpgradeable {
    constructor(PlasmaVaultInitData memory initData_) PlasmaVault(initData_) initializer {
        super.__ERC20_init(initData_.assetName, initData_.assetSymbol);
        super.__ERC4626_init(IERC20(initData_.underlyingToken));
        super.__ERC20Votes_init();
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

    function nonces(address owner_) public view override returns (uint256) {
        return super.nonces(owner_);
    }

    function _update(
        address from_,
        address to_,
        uint256 amount_
    ) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        ERC20VotesUpgradeable._update(from_, to_, amount_);
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
