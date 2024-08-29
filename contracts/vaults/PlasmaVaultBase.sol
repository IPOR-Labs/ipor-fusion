// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {IPlasmaVaultBase} from "../interfaces/IPlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "./PlasmaVaultGovernance.sol";
import {ERC20CappedUpgradeable} from "./ERC20CappedUpgradeable.sol";

/// @title Stateless extension of PlasmaVault with ERC20 Votes, ERC20 Permit. Used in the context of Plasma Vault (only by delegatecall).
contract PlasmaVaultBase is
    IPlasmaVaultBase,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    ERC20CappedUpgradeable,
    PlasmaVaultGovernance
{
    function init(
        string memory assetName_,
        address accessManager_,
        uint256 totalSupplyCap_
    ) external override initializer {
        super.__ERC20Votes_init();
        super.__ERC20Permit_init(assetName_);
        super.__AccessManaged_init(accessManager_);
        super.__ERC20Capped_init(totalSupplyCap_);
    }

    /// @dev Notice! Can be executed only by Plasma Vault in delegatecall. PlasmaVault execute this function only using delegatecall, to get PlasmaVault context and storage.
    /// @dev Internal method `PlasmaVault._update(address from_, address to_, uint256 value_)` is overridden and inside it calls - as a delegatecall - this function `updateInternal`.
    function updateInternal(address from_, address to_, uint256 value_) external override {
        _update(from_, to_, value_);
    }

    function nonces(address owner_) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner_);
    }

    function _update(
        address from_,
        address to_,
        uint256 value_
    ) internal virtual override(ERC20Upgradeable, ERC20VotesUpgradeable, ERC20CappedUpgradeable) {
        /// @dev update votes and update total supply and balance
        ERC20VotesUpgradeable._update(from_, to_, value_);
        /// @dev check total supply cap
        ERC20CappedUpgradeable._update(from_, to_, value_);
    }
}
