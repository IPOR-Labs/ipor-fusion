// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {DualCrossReferencePriceFeed} from "../../contracts/price_oracle/price_feed/DualCrossReferencePriceFeed.sol";
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
        address priceOracleMiddlewareAddr = address(new PriceOracleMiddleware(chainlinkFeedRegistry_));

        // Deploy and initialize proxy
        return
            PriceOracleMiddleware(
                address(
                    new ERC1967Proxy(
                        address(priceOracleMiddlewareAddr),
                        abi.encodeWithSignature("initialize(address)", owner_)
                    )
                )
            );
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
                new DualCrossReferencePriceFeed(
                    TestAddresses.BASE_WSTETH,
                    TestAddresses.BASE_CHAINLINK_WSTETH_TO_ETH_PRICE,
                    TestAddresses.BASE_CHAINLINK_ETH_PRICE
                )
            );
    }

    function getArbitrumPriceOracleMiddleware() internal returns (PriceOracleMiddleware) {
        return PriceOracleMiddleware(0xF9d7F359875E21b3A74BEd7Db40348f5393AF758);
    }

    function getEthereumPriceOracleMiddleware() internal returns (PriceOracleMiddleware) {
        return PriceOracleMiddleware(0xB7018C15279E0f5990613cc00A91b6032066f2f7);
    }
}
