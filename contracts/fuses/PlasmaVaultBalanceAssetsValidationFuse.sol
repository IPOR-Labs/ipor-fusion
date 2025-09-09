// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Errors} from "../libraries/errors/Errors.sol";
import {IFuseCommon} from "./IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../libraries/PlasmaVaultConfigLib.sol";

/**
 * @title PlasmaVaultBalanceAssetsValidationFuseEnterData
 * @notice Data structure for validating asset balances in Plasma Vault
 * @dev Contains arrays of assets and their corresponding minimum and maximum balance thresholds
 */
struct PlasmaVaultBalanceAssetsValidationFuseEnterData {
    /// @notice Array of asset addresses to validate
    address[] assets;
    /// @notice Array of minimum balance values for each asset, in decimals of the asset
    uint256[] minBalanceValues;
    /// @notice Array of maximum balance values for each asset, in decimals of the asset
    uint256[] maxBalanceValues;
}

/**
 * @title PlasmaVaultBalanceAssetsValidationFuse
 * @notice A fuse contract that validates asset balances within specified ranges for Plasma Vault
 * @dev This fuse ensures that the vault maintains asset balances within acceptable thresholds
 *      to prevent excessive exposure or insufficient liquidity. It validates that each asset's
 *      balance falls within the specified min/max range and that the asset is granted for the market.
 *
 * Key features:
 * - Validates asset balances against minimum and maximum thresholds
 * - Ensures assets are granted for the specific market
 * - Skips validation for zero addresses
 * - Provides detailed error information for balance violations
 */
contract PlasmaVaultBalanceAssetsValidationFuse is IFuseCommon {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    /// @notice The version identifier for this fuse contract
    address public immutable VERSION;
    /// @notice The market ID this fuse is associated with
    uint256 public immutable MARKET_ID;

    /**
     * @notice Error thrown when an asset's balance is outside the allowed range
     * @param asset The address of the asset that failed validation
     * @param balance The current balance of the asset
     * @param minBalance The minimum allowed balance
     * @param maxBalance The maximum allowed balance
     */
    error PlasmaVaultBalanceAssetsValidationFuseInvalidBalance(
        address asset,
        uint256 balance,
        uint256 minBalance,
        uint256 maxBalance
    );

    /**
     * @notice Constructor for PlasmaVaultBalanceAssetsValidationFuse
     * @param marketId_ The market ID to associate with this fuse
     * @dev Reverts if marketId_ is zero
     */
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert Errors.WrongValue();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /**
     * @notice Validates asset balances against specified thresholds
     * @param data_ The validation data containing assets and their balance thresholds
     * @dev This function performs the following validations:
     *       1. Ensures all arrays have the same length
     *       2. Skips validation for zero addresses
     *       3. Verifies each asset is granted for the market
     *       4. Checks that each asset's balance falls within min/max range
     *
     * @custom:revert Errors.WrongValue When arrays have different lengths or asset is not granted
     * @custom:revert PlasmaVaultBalanceAssetsValidationFuseInvalidBalance When balance is outside allowed range
     */
    function enter(PlasmaVaultBalanceAssetsValidationFuseEnterData memory data_) external {
        if (
            data_.assets.length != data_.minBalanceValues.length || data_.assets.length != data_.maxBalanceValues.length
        ) {
            revert Errors.WrongValue();
        }

        uint256 balance;
        uint256 length = data_.assets.length;

        for (uint256 i; i < length; i++) {
            if (data_.assets[i] == address(0)) {
                continue;
            }

            if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.assets[i])) {
                revert Errors.WrongValue();
            }

            balance = ERC20(data_.assets[i]).balanceOf(address(this));

            if (balance < data_.minBalanceValues[i] || balance > data_.maxBalanceValues[i]) {
                revert PlasmaVaultBalanceAssetsValidationFuseInvalidBalance(
                    data_.assets[i],
                    balance,
                    data_.minBalanceValues[i],
                    data_.maxBalanceValues[i]
                );
            }
        }
    }
}
