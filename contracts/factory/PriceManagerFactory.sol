// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PriceOracleMiddlewareManager} from "../managers/price/PriceOracleMiddlewareManager.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title PriceManagerFactory
/// @notice Factory contract for creating and deploying new instances of PriceOracleMiddlewareManager
/// @dev This factory pattern allows for standardized creation of price manager instances with proper initialization
contract PriceManagerFactory {
    /// @notice Emitted when a new PriceOracleMiddlewareManager instance is created
    /// @param index The index of the PriceOracleMiddlewareManager instance
    /// @param priceManager The address of the newly created PriceOracleMiddlewareManager
    /// @param priceOracleMiddleware The address of the price oracle middleware that will be used for price feeds
    event PriceManagerCreated(uint256 index, address priceManager, address priceOracleMiddleware);

    /// @notice Emitted when a new PriceOracleMiddlewareManager instance is cloned
    /// @param baseAddress The address of the base PriceOracleMiddlewareManager implementation to clone
    /// @param index The index of the PriceOracleMiddlewareManager instance
    /// @param priceManager The address of the newly cloned PriceOracleMiddlewareManager
    /// @param priceOracleMiddleware The address of the price oracle middleware that will be used for price feeds
    event PriceManagerCloned(address baseAddress, uint256 index, address priceManager, address priceOracleMiddleware);

    /// @notice Error thrown when trying to use zero address as base
    error InvalidBaseAddress();

    /// @notice Creates a new instance of PriceOracleMiddlewareManager
    /// @param index_ The index of the PriceOracleMiddlewareManager instance
    /// @param accessManager_ The address of the access control manager that will have initial authority
    /// @param priceOracleMiddleware_ The address of the price oracle middleware that will be used for price feeds
    /// @return priceManager The address of the newly deployed PriceOracleMiddlewareManager contract
    /// @dev The created price manager will be initialized with the provided access manager and price oracle middleware
    function create(
        uint256 index_,
        address accessManager_,
        address priceOracleMiddleware_
    ) external returns (address priceManager) {
        priceManager = address(new PriceOracleMiddlewareManager(accessManager_, priceOracleMiddleware_));
        emit PriceManagerCreated(index_, priceManager, priceOracleMiddleware_);
    }

    /// @notice Creates a new instance of PriceOracleMiddlewareManager using Clones pattern
    /// @dev Clones the base PriceOracleMiddlewareManager and initializes it with the provided parameters
    /// @param baseAddress_ The address of the base PriceOracleMiddlewareManager implementation to clone
    /// @param index_ The index of the PriceOracleMiddlewareManager instance
    /// @param accessManager_ The address of the access control manager that will have initial authority
    /// @param priceOracleMiddleware_ The address of the price oracle middleware that will be used for price feeds
    /// @return priceManager The address of the newly cloned PriceOracleMiddlewareManager contract
    function clone(
        address baseAddress_,
        uint256 index_,
        address accessManager_,
        address priceOracleMiddleware_
    ) external returns (address priceManager) {
        if (baseAddress_ == address(0)) revert InvalidBaseAddress();

        priceManager = Clones.clone(baseAddress_);
        PriceOracleMiddlewareManager(priceManager).proxyInitialize(accessManager_, priceOracleMiddleware_);

        emit PriceManagerCloned(baseAddress_, index_, priceManager, priceOracleMiddleware_);
    }
}
