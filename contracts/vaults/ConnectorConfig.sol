// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

contract ConnectorConfig {

    struct Market {
        uint256 id;
        bytes32 name;
    }
    struct ConnectorConfigData {
        /// @dev when marketId = 0 then connector doesn't support any market
        uint256 marketId;

        /// @dev address to the connector contract which is responsible for the balanceOf function for a given market and asset
        address connectorBalanceOf;

    }

    /// @dev key - marketId, value - market name, when key = 0 then connector doesn't support any market
    /// TODO: iterable mapping
    mapping(uint256 => bytes32) public markets;

    uint256 public marketIdCounter;

    mapping(address => ConnectorConfigData) public connectorConfig;

    function addConnector(
        address connector,
        uint256 marketId,
        address connectorBalanceOf
    ) external {
        require(marketId == 0 || markets[marketId] > 0, "ConnectorConfig: market doesn't exist");
        connectorConfig[connector] = ConnectorConfigData(marketId, connectorBalanceOf);
    }

    function addMarket(bytes32 marketName) external {
        uint256 newMarketId = marketIdCounter++;
        markets[newMarketId] = marketName;
        marketIdCounter = newMarketId;
    }

    function getMarkets() external view returns (Market[] memory markets) {
        markets = new Market[](marketIdCounter);
        for (uint256 i = 0; i < marketIdCounter; i++) {
            markets[i] = Market(i, this.markets[i]);
        }
    }

}