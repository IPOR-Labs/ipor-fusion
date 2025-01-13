// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPreHook} from "../IPreHook.sol";
import {PlasmaVault} from "../../../vaults/PlasmaVault.sol";
import {FusesLib} from "../../../libraries/FusesLib.sol";

/// @title UpdateBalancesPreHook
/// @notice Pre-execution hook for updating balances in Plasma Vault
/// @dev Implements basic pre-hook interface for balance updates
contract UpdateBalancesPreHook is IPreHook {
    /// @inheritdoc IPreHook
    function run() external {
        uint256[] memory marketIds = FusesLib.getActiveMarketsInBalanceFuses();
        if (marketIds.length == 0) {
            return;
        }
        PlasmaVault(address(this)).updateMarketsBalances(marketIds);
    }
}
