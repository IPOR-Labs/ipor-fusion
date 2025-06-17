// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AssetDualSourcePriceFeed} from "../../price_oracle/price_feed/AssetDualSourcePriceFeed.sol";

/// @title AssetDualSourcePriceFeedFactory
/// @notice Factory contract for creating and deploying new instances of AssetDualSourcePriceFeed
/// @dev This factory pattern allows for standardized creation of dual source price feed instances
contract AssetDualSourcePriceFeedFactory {
    /// @notice Emitted when a new AssetDualSourcePriceFeed instance is created
    /// @param priceFeed The address of the newly created AssetDualSourcePriceFeed
    /// @param primarySource The address of the primary price source
    /// @param secondarySource The address of the secondary price source
    event AssetDualSourcePriceFeedCreated(
        address priceFeed,
        address primarySource,
        address secondarySource
    );

    /// @notice Creates a new instance of AssetDualSourcePriceFeed
    /// @param index_ The index of the AssetDualSourcePriceFeed instance
    /// @param primarySource_ The address of the primary price source
    /// @param secondarySource_ The address of the secondary price source
    /// @return priceFeed The address of the newly deployed AssetDualSourcePriceFeed contract
    /// @dev The created price feed will be initialized with the provided primary and secondary sources
    function create(
        uint256 index_,
        address primarySource_,
        address secondarySource_
    ) external returns (address priceFeed) {
        priceFeed = address(new AssetDualSourcePriceFeed(primarySource_, secondarySource_));
        emit AssetDualSourcePriceFeedCreated(index_, priceFeed, primarySource_, secondarySource_);
    }
}
