// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PriceOracleMiddlewareManager} from "../managers/price/PriceOracleMiddlewareManager.sol";

/// @title PriceManagerFactory
/// @notice Factory contract for creating PriceManager instances
contract PriceManagerFactory {

    event PriceManagerCreated(address priceManager, address priceOracleMiddleware);

    /// @notice Creates a new PriceOracleMiddlewareManager
    /// @param accessManager_ The initial authority address for access control
    /// @param priceOracleMiddleware_ Address of the price oracle middleware
    /// @return priceManager Address of the newly created PriceOracleMiddlewareManager
    function getInstance(
        address accessManager_,
        address priceOracleMiddleware_
    ) external returns (address priceManager) {
        priceManager = address(new PriceOracleMiddlewareManager(accessManager_, priceOracleMiddleware_));
        emit PriceManagerCreated(priceManager, priceOracleMiddleware_);
    }
}
