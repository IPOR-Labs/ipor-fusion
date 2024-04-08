// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

contract FuseConfig {
    struct Market {
        uint256 id;
        bytes32 name;
    }

    /// @dev key - marketId, value - market name
    mapping(uint256 => bytes32) public markets;

    /// @dev key - marketId, value - balance fuse address
    mapping(uint256 => address) public marketBalanceFuses;

    uint256 public currentMarketId;

    function addMarket(bytes32 marketName, address balanceFuse) external returns (uint256 newMarketId) {
        newMarketId = currentMarketId++;
        markets[newMarketId] = marketName;
        currentMarketId = newMarketId;
        marketBalanceFuses[newMarketId] = balanceFuse;
    }

    function getMarkets() external view returns (Market[] memory resultMarkets) {
        resultMarkets = new Market[](currentMarketId);
        for (uint256 i; i < currentMarketId; ++i) {
            resultMarkets[i] = Market(i, markets[i]);
        }
    }

    function getBalanceFuse(uint256 marketId) external view returns (address) {
        return marketBalanceFuses[marketId];
    }
}
