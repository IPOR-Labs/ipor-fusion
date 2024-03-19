// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {StorageLib} from "./StorageLib.sol";

library ConnectorsLib {
    event ConnectorAdded(address indexed connector);
    event ConnectorRemoved(address indexed connector);
    event BalanceConnectorAdded(uint256 indexed marketId, address indexed connector);
    event BalanceConnectorRemoved(uint256 indexed marketId, address indexed connector);

    function addConnector(address connector) internal {
        StorageLib.Connectors storage connectors = StorageLib.getConnectors();
        connectors.value[connector] = 1;
        emit ConnectorAdded(connector);
    }

    function removeConnector(address connector) internal {
        StorageLib.Connectors storage connectors = StorageLib.getConnectors();
        connectors.value[connector] = 0;
        emit ConnectorRemoved(connector);
    }

    function isConnectorSupported(address connector) internal view returns (bool) {
        return StorageLib.getConnectors().value[connector] == 1;
    }

    function addBalanceConnector(uint256 marketId, address connector) internal {
        StorageLib.BalanceConnectors storage balanceConnectors = StorageLib.getBalanceConnectors();
        bytes32 key = keccak256(abi.encodePacked(marketId, connector));

        uint256 keyIndexValue = balanceConnectors.value[key];

        require(keyIndexValue == 0, "ConnectorsLib: Connector already exists");

        uint32 newLastBalanceConnectorId = StorageLib.getLastBalanceConnectorId().value + 1;

        /// @dev for balance connectors, value is a index + 1 in the balanceConnectorsArray
        balanceConnectors.value[key] = newLastBalanceConnectorId;

        StorageLib.getLastBalanceConnectorId().value = newLastBalanceConnectorId;
        StorageLib.getBalanceConnectorsArray().value.push(key);

        emit BalanceConnectorAdded(marketId, connector);
    }

    function removeBalanceConnector(uint256 marketId, address connector) internal {
        StorageLib.BalanceConnectors storage balanceConnectors = StorageLib.getBalanceConnectors();

        bytes32 key = keccak256(abi.encodePacked(marketId, connector));

        uint256 indexToRemove = balanceConnectors.value[key];

        require(indexToRemove != 0, "ConnectorsLib: Connector does not exist");

        /// @dev for balance connectors, value is a index + 1 in the balanceConnectorsArray
        bytes32 lastKeyInArray = StorageLib.getBalanceConnectorsArray().value[
            StorageLib.getLastBalanceConnectorId().value - 1
        ];

        balanceConnectors.value[lastKeyInArray] = indexToRemove;

        balanceConnectors.value[key] = 0;

        StorageLib.getBalanceConnectorsArray().value[indexToRemove - 1] = lastKeyInArray;

        StorageLib.getBalanceConnectorsArray().value.pop();

        StorageLib.getLastBalanceConnectorId().value = StorageLib.getLastBalanceConnectorId().value - 1;

        emit BalanceConnectorRemoved(marketId, connector);
    }

    function isBalanceConnectorSupported(uint256 marketId, address connector) internal view returns (bool) {
        bytes32 key = keccak256(abi.encodePacked(marketId, connector));
        return StorageLib.getBalanceConnectors().value[key] != 0;
    }

    function getBalanceConnectorIndex(uint256 marketId, address connector) internal view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(marketId, connector));
        return StorageLib.getBalanceConnectors().value[key];
    }

    function getLastBalanceConnectorId() internal view returns (uint256) {
        return StorageLib.getLastBalanceConnectorId().value;
    }

    function getBalanceConnectorsArray() internal view returns (bytes32[] memory) {
        return StorageLib.getBalanceConnectorsArray().value;
    }
}
