// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PriceOracleMiddlewareManager} from "../managers/price/PriceOracleMiddlewareManager.sol";

/// @title PriceManagerFactory
/// @notice Factory contract for creating and deploying new instances of PriceOracleMiddlewareManager
/// @dev This factory pattern allows for standardized creation of price manager instances with proper initialization
contract PriceManagerFactory {
    event PriceManagerCreated(address priceManager, address priceOracleMiddleware);

    /// @notice Creates a new instance of PriceOracleMiddlewareManager
    /// @param accessManager_ The address of the access control manager that will have initial authority
    /// @param priceOracleMiddleware_ The address of the price oracle middleware that will be used for price feeds
    /// @return priceManager The address of the newly deployed PriceOracleMiddlewareManager contract
    /// @dev The created price manager will be initialized with the provided access manager and price oracle middleware
    function create(
        address accessManager_,
        address priceOracleMiddleware_
    ) external returns (address priceManager) {
        priceManager = address(new PriceOracleMiddlewareManager(accessManager_, priceOracleMiddleware_));
        emit PriceManagerCreated(priceManager, priceOracleMiddleware_);
    }
}
