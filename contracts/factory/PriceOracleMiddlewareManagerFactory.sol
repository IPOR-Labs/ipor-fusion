// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PriceOracleMiddlewareManager} from "../managers/price/PriceOracleMiddlewareManager.sol";

/// @title PriceOracleMiddlewareManagerFactory
/// @notice Factory contract for creating PriceOracleMiddlewareManager instances
contract PriceOracleMiddlewareManagerFactory {
    /// @notice Emitted when a new PriceOracleMiddlewareManager is created
    event PriceOracleMiddlewareManagerCreated(address indexed manager, address indexed priceOracleMiddleware);

    /// @notice Creates a new PriceOracleMiddlewareManager
    /// @param accessManager_ The initial authority address for access control
    /// @param priceOracleMiddleware_ Address of the price oracle middleware
    /// @return Address of the newly created PriceOracleMiddlewareManager
    function createPriceOracleMiddlewareManager(
        address accessManager_,
        address priceOracleMiddleware_
    ) external returns (address) {
        PriceOracleMiddlewareManager manager = new PriceOracleMiddlewareManager(accessManager_, priceOracleMiddleware_);

        emit PriceOracleMiddlewareManagerCreated(address(manager), priceOracleMiddleware_);
        return address(manager);
    }
}
