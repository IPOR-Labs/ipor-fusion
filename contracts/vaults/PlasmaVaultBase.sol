// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IPlasmaVaultBase} from "../interfaces/IPlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "./PlasmaVaultGovernance.sol";
import {ERC20VotesUpgradeable} from "./ERC20VotesUpgradeable.sol";
import {PlasmaVaultLib} from "../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";

/// @title Stateless extension of PlasmaVault with ERC20 Votes, ERC20 Permit. Used in the context of Plasma Vault (only by delegatecall).
contract PlasmaVaultBase is IPlasmaVaultBase, ERC20PermitUpgradeable, ERC20VotesUpgradeable, PlasmaVaultGovernance {
    /**
     * @dev Total supply cap has been exceeded.
     */
    error ERC20ExceededCap(uint256 increasedSupply, uint256 cap);

    /**
     * @dev The supplied cap is not a valid cap.
     */
    error ERC20InvalidCap(uint256 cap);

    function init(
        string memory assetName_,
        address accessManager_,
        uint256 totalSupplyCap_
    ) external override initializer {
        super.__ERC20Votes_init();
        super.__ERC20Permit_init(assetName_);
        super.__AccessManaged_init(accessManager_);
        __init(totalSupplyCap_);
    }

    function __init(uint256 cap_) internal onlyInitializing {
        // solhint-disable-previous-line func-name-mixedcase
        PlasmaVaultStorageLib.ERC20CappedStorage storage $ = PlasmaVaultStorageLib.getERC20CappedStorage();
        if (cap_ == 0) {
            revert ERC20InvalidCap(0);
        }
        $.cap = cap_;
    }

    function cap() public view virtual returns (uint256) {
        PlasmaVaultStorageLib.ERC20CappedStorage storage $ = PlasmaVaultStorageLib.getERC20CappedStorage();
        return $.cap;
    }

    /// @dev Notice! Can be executed only by Plasma Vault in delegatecall. PlasmaVault execute this function only using delegatecall, to get PlasmaVault context and storage.
    /// @dev Internal method `PlasmaVault._update(address from_, address to_, uint256 value_)` is overridden and inside it calls - as a delegatecall - this function `updateInternal`.
    function updateInternal(address from_, address to_, uint256 value_) external override {
        _update(from_, to_, value_);
    }

    function nonces(address owner_) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner_);
    }

    /// @dev Notice! Can be executed only by Plasma Vault in delegatecall.
    /// Combines the logic required for ERC20VotesUpgradeable and ERC20VotesUpgradeable
    function _update(address from_, address to_, uint256 value_) internal virtual override {
        super._update(from_, to_, value_);

        /// @dev total supply cap validation is disabled when performance and management fee is minted
        if (PlasmaVaultLib.isTotalSupplyCapValidationEnabled()) {
            /// @dev check total supply cap
            if (from_ == address(0)) {
                uint256 maxSupply = cap();
                uint256 supply = totalSupply();
                if (supply > maxSupply) {
                    revert ERC20ExceededCap(supply, maxSupply);
                }
            }
        }

        _transferVotingUnits(from_, to_, value_);
    }
}
