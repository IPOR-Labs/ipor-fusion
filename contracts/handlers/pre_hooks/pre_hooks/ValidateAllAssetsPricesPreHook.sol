// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { IPreHook } from "../IPreHook.sol";
import { PlasmaVaultLib } from "../../../libraries/PlasmaVaultLib.sol";
import { PriceOracleMiddlewareManager } from "../../../managers/price/PriceOracleMiddlewareManager.sol";

/// @title Validate All Assets Prices Pre-Hook
/// @notice Pre-hook that enforces price validation across all configured assets prior to executing a PlasmaVault action.
/// @dev Executes within the PlasmaVault context (delegatecall) to ensure the vault address is the caller when invoking the manager.
contract ValidateAllAssetsPricesPreHook is IPreHook {
    /// @notice Thrown when price oracle middleware manager is missing.
    error PriceOracleMiddlewareManagerNotConfigured();

    /// @inheritdoc IPreHook
    function run(bytes4) external {
        address priceOracleMiddlewareManager = PlasmaVaultLib.getPriceOracleMiddleware();
        if (priceOracleMiddlewareManager == address(0)) {
            revert PriceOracleMiddlewareManagerNotConfigured();
        }

        PriceOracleMiddlewareManager(priceOracleMiddlewareManager).validateAllAssetsPrices();
    }
}

