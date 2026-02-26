// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PriceOracleMiddlewareManager} from "../managers/price/PriceOracleMiddlewareManager.sol";
import {FusionFactoryCreate3Lib} from "./lib/FusionFactoryCreate3Lib.sol";

/// @title PriceManagerFactory
/// @notice Factory contract for creating and deploying new instances of PriceOracleMiddlewareManager
/// @dev This factory pattern allows for standardized creation of price manager instances with proper initialization
contract PriceManagerFactory {
    /// @notice Error thrown when trying to use zero address as base
    error InvalidBaseAddress();

    /// @notice Error thrown when caller is not the FusionFactory
    error CallerNotFusionFactory();

    /// @notice The address of the FusionFactory that is authorized to call deployDeterministic
    address public immutable FUSION_FACTORY;

    constructor(address fusionFactory_) {
        FUSION_FACTORY = fusionFactory_;
    }

    modifier onlyFusionFactory() {
        if (msg.sender != FUSION_FACTORY) revert CallerNotFusionFactory();
        _;
    }

    /// @notice Creates a new instance of PriceOracleMiddlewareManager using CREATE3 deterministic deployment
    /// @param baseAddress_ The address of the base PriceOracleMiddlewareManager implementation
    /// @param salt_ The CREATE3 salt for deterministic address
    /// @param accessManager_ The address of the access control manager that will have initial authority
    /// @param priceOracleMiddleware_ The address of the price oracle middleware that will be used for price feeds
    /// @return priceManager The address of the deterministically deployed PriceOracleMiddlewareManager
    function deployDeterministic(
        address baseAddress_,
        bytes32 salt_,
        address accessManager_,
        address priceOracleMiddleware_
    ) external onlyFusionFactory returns (address priceManager) {
        if (baseAddress_ == address(0)) revert InvalidBaseAddress();

        priceManager = FusionFactoryCreate3Lib.deployMinimalProxyDeterministic(baseAddress_, salt_);
        PriceOracleMiddlewareManager(priceManager).proxyInitialize(accessManager_, priceOracleMiddleware_);
    }

    /// @notice Predicts the address of a deterministic PriceOracleMiddlewareManager deployment
    /// @param salt_ The CREATE3 salt to predict the address for
    /// @return The predicted deployment address
    function predictDeterministicAddress(bytes32 salt_) external view returns (address) {
        return FusionFactoryCreate3Lib.predictAddress(salt_);
    }
}
