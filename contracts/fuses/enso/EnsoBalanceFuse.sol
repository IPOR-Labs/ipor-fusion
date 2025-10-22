// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IEnsoExecutor} from "./IEnsoExecutor.sol";
import {EnsoStorageLib} from "./EnsoStorageLib.sol";

/// @title EnsoBalanceFuse
/// @notice Fuse for reading balance from EnsoExecutor and converting it to USD value
/// @dev This fuse reads the asset balance from EnsoExecutor instance stored in PlasmaVault storage and converts it to USD
contract EnsoBalanceFuse is IMarketBalanceFuse {
    error EnsoBalanceFuseInvalidPriceOracleMiddleware();

    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /// @notice Get the balance of the Plasma Vault in the EnsoExecutor in USD
    /// @return The balance of the Plasma Vault in USD, represented in 18 decimals
    function balanceOf() external view override returns (uint256) {
        // Get executor address from storage
        address executorAddress = EnsoStorageLib.getEnsoExecutor();

        // If executor doesn't exist, return 0
        if (executorAddress == address(0)) {
            return 0;
        }

        // Get balance from EnsoExecutor
        (address assetAddress, uint256 assetBalance) = IEnsoExecutor(executorAddress).getBalance();

        // If no asset or no balance, return 0
        if (assetAddress == address(0) || assetBalance == 0) {
            return 0;
        }

        // Get price oracle middleware
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        if (priceOracleMiddleware == address(0)) {
            revert EnsoBalanceFuseInvalidPriceOracleMiddleware();
        }

        // Get asset price
        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(
            assetAddress
        );

        // Get asset decimals
        uint256 assetDecimals = IERC20Metadata(assetAddress).decimals();

        // Convert to USD in 18 decimals
        return IporMath.convertToWad(assetBalance * price, assetDecimals + priceDecimals);
    }
}
