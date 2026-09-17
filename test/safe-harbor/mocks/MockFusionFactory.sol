// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFusionFactoryVaultCheck} from "../../../contracts/safe-harbor/IFusionFactoryVaultCheck.sol";

/// @title MockFusionFactory
/// @author IPOR Labs
/// @notice Configurable factory eligibility and selector failure for registrar unit tests.
contract MockFusionFactory is IFusionFactoryVaultCheck {
    error FactoryUnavailable();

    mapping(address vault => bool recognized) private _vaults;
    bool private _revertLookup;

    /// @notice Configures whether the factory recognizes a vault.
    /// @param vault_ Vault address.
    /// @param recognized_ Factory response for this vault.
    function setFusionVault(address vault_, bool recognized_) external {
        _vaults[vault_] = recognized_;
    }

    /// @notice Configures simulated factory unavailability.
    /// @param revertLookup_ Whether eligibility lookups revert.
    function setRevertLookup(bool revertLookup_) external {
        _revertLookup = revertLookup_;
    }

    /// @inheritdoc IFusionFactoryVaultCheck
    function isFusionVault(address vault_) external view override returns (bool) {
        if (_revertLookup) revert FactoryUnavailable();
        return _vaults[vault_];
    }
}
