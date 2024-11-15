// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {AssetChainlinkPriceFeed} from "../../contracts/price_oracle/price_feed/AssetChainlinkPriceFeed.sol";
import {TestAddresses} from "./TestAddresses.sol";

/// @title PriceOracleMiddlewareHelper
/// @notice Helper library for deploying and configuring PriceOracleMiddleware in tests
/// @dev Contains utility functions to assist with PriceOracleMiddleware testing
library PriceOracleMiddlewareHelper {
    struct AssetPriceSource {
        address asset;
        address source;
    }

    /// @notice Deploys and configures PriceOracleMiddleware with given owner and Chainlink feed registry
    /// @param owner_ Address that will own the oracle
    /// @param chainlinkFeedRegistry_ Address of the Chainlink feed registry
    /// @return priceOracleMiddleware The deployed and configured PriceOracleMiddleware proxy
    function deployPriceOracleMiddleware(
        address owner_,
        address chainlinkFeedRegistry_
    ) internal returns (PriceOracleMiddleware priceOracleMiddleware) {
        // Deploy implementation
        address priceOracleMiddleware = address(new PriceOracleMiddleware(chainlinkFeedRegistry_));

        // Deploy and initialize proxy
        return
            PriceOracleMiddleware(
                address(
                    new ERC1967Proxy(
                        address(priceOracleMiddleware),
                        abi.encodeWithSignature("initialize(address)", owner_)
                    )
                )
            );
    }

    function setAssetsPricesSources(
        PriceOracleMiddleware priceOracleMiddleware_,
        address[] memory assets,
        address[] memory sources
    ) internal {
        priceOracleMiddleware_.setAssetsPricesSources(assets, sources);
    }

    function addressOf(PriceOracleMiddleware priceOracleMiddleware_) internal view returns (address) {
        return address(priceOracleMiddleware_);
    }

    function addSource(PriceOracleMiddleware priceOracleMiddleware_, address asset_, address source_) internal {
        address[] memory assets = new address[](1);
        assets[0] = asset_;
        address[] memory sources = new address[](1);
        sources[0] = source_;
        priceOracleMiddleware_.setAssetsPricesSources(assets, sources);
    }

    function deployWstEthPriceFeedOnBase() internal returns (address) {
        // Deploy AssetChainlinkPriceFeed for wstETH using:
        // - wstETH as asset
        // - CHAINLINK_WSTETH_TO_ETH_PRICE for wstETH/ETH price feed
        // - CHAINLINK_ETH_PRICE for ETH/USD price feed
        return
            address(
                new AssetChainlinkPriceFeed(
                    TestAddresses.BASE_WSTETH,
                    TestAddresses.BASE_CHAINLINK_WSTETH_TO_ETH_PRICE,
                    TestAddresses.BASE_CHAINLINK_ETH_PRICE
                )
            );
    }
}
