// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {VaultStorageLib} from "./VaultStorageLib.sol";

library ConnectorsLib {
    event ConnectorAdded(address indexed connector);
    event ConnectorRemoved(address indexed connector);
    event BalanceConnectorAdded(uint256 indexed marketId, address indexed connector);
    event BalanceConnectorRemoved(uint256 indexed marketId, address indexed connector);

    error WrongAddress();
    error ConnectorAlreadyExists();
    error ConnectorDoesNotExist();
    error BalanceConnectorAlreadyExists(uint256 marketId, address connector);
    error BalanceConnectorDoesNotExist(uint256 marketId, address connector);

    function addConnector(address connector) internal {
        VaultStorageLib.Connectors storage connectors = VaultStorageLib.getConnectors();

        uint256 keyIndexValue = connectors.value[connector];

        if (keyIndexValue != 0) {
            revert ConnectorAlreadyExists();
        }

        uint256 newLastConnectorId = VaultStorageLib.getConnectorsArray().value.length + 1;

        /// @dev for balance connectors, value is a index + 1 in the connectorsArray
        connectors.value[connector] = newLastConnectorId;

        VaultStorageLib.getConnectorsArray().value.push(connector);

        emit ConnectorAdded(connector);
    }

    function removeConnector(address connector) internal {
        VaultStorageLib.Connectors storage connectors = VaultStorageLib.getConnectors();

        uint256 indexToRemove = connectors.value[connector];

        if (indexToRemove == 0) {
            revert ConnectorDoesNotExist();
        }

        address lastKeyInArray = VaultStorageLib.getConnectorsArray().value[
            VaultStorageLib.getConnectorsArray().value.length - 1
        ];

        connectors.value[lastKeyInArray] = indexToRemove;

        connectors.value[connector] = 0;

        /// @dev balanceConnectors mapping contains values as index + 1
        VaultStorageLib.getConnectorsArray().value[indexToRemove - 1] = lastKeyInArray;

        VaultStorageLib.getConnectorsArray().value.pop();

        emit ConnectorRemoved(connector);
    }

    function isConnectorSupported(address connector) internal view returns (bool) {
        return VaultStorageLib.getConnectors().value[connector] != 0;
    }

    function setBalanceFuse(uint256 marketId, address fuse) internal {
        address currentConnector = VaultStorageLib.getMarketBalanceConnectors().value[marketId];

        if (currentConnector == fuse) {
            revert BalanceConnectorAlreadyExists(marketId, fuse);
        }

        VaultStorageLib.getMarketBalanceConnectors().value[marketId] = fuse;

        emit BalanceConnectorAdded(marketId, fuse);
    }

    function removeBalanceConnector(uint256 marketId, address connector) internal {
        address currentConnector = VaultStorageLib.getMarketBalanceConnectors().value[marketId];

        if (currentConnector != connector) {
            revert BalanceConnectorDoesNotExist(marketId, connector);
        }

        VaultStorageLib.getMarketBalanceConnectors().value[marketId] = address(0);

        emit BalanceConnectorRemoved(marketId, connector);
    }

    function isBalanceConnectorSupported(uint256 marketId, address connector) internal view returns (bool) {
        return VaultStorageLib.getMarketBalanceConnectors().value[marketId] == connector;
    }

    function getMarketBalanceConnector(uint256 marketId) internal view returns (address) {
        return VaultStorageLib.getMarketBalanceConnectors().value[marketId];
    }

    function getConnectorsArray() internal view returns (address[] memory) {
        return VaultStorageLib.getConnectorsArray().value;
    }

    function getConnectorArrayIndex(address connector) internal view returns (uint256) {
        return VaultStorageLib.getConnectors().value[connector];
    }
}
