// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/// @title STATELESS extension of PlasmaVault with ERC20 Votes, ERC20 Permit. Used by PlasmaVault only by delegatecall.
contract PlasmaVaultBase is ERC20PermitUpgradeable, ERC20VotesUpgradeable {
    function init(string memory assetName) external initializer {
        super.__ERC20Votes_init();
        super.__ERC20Permit_init(assetName);
    }

    /// @dev Support Votes, can be executed only by Vault
    function updateInternal(address from_, address to_, uint256 value_) external {
        /// @dev Assume that _update on Vault was executed.
        if (from_ == address(0)) {
            uint256 supply = ERC20(address(this)).totalSupply();
            uint256 cap = _maxSupply();
            if (supply > cap) {
                revert ERC20ExceededSafeSupply(supply, cap);
            }
        }
        _transferVotingUnits(from_, to_, value_);
    }

    function nonces(address owner_) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner_);
    }

    function _update(
        address from_,
        address to_,
        uint256 value_
    ) internal virtual override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._update(from_, to_, value_);
    }
}
