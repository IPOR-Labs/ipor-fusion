// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {PlasmaVault, PlasmaVaultInitData} from "../PlasmaVault.sol";

/// @title STATELESS extension of PlasmaVault with ERC20Votes
contract PlasmaVaultBase is ERC20VotesUpgradeable {
    function init() external initializer {
        __ERC20Votes_init();
    }

    /// @dev Support Votes, can be executed only by Vault
    function updateInternal(address from_, address to_, uint256 value_) external {
        console2.log("PlasmaVaultBase.updateInternal, to_=", to_);
        console2.log("PlasmaVaultBase.updateInternal, value_=", value_);
        /// @dev Assume that _update on Vault was executed.

        if (from_ == address(0)) {
            console2.log("PlasmaVaultBase.updateInternal address(this)=", address(this));
            uint256 supply = ERC20(address(this)).totalSupply();
            console2.log("PlasmaVaultBase.updateInternal, supply=", supply);
            uint256 cap = _maxSupply();
            if (supply > cap) {
                revert ERC20ExceededSafeSupply(supply, cap);
            }
        }
        _transferVotingUnits(from_, to_, value_);
    }
}
