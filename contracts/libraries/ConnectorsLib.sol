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
        uint256 currentValue = balanceConnectors.value[marketId][connector];
        require(currentValue == 0, "ConnectorsLib: Connector already exists");

        uint32 lastBalanceConnectorId = StorageLib.getLastBalanceConnectorId().value + 1;
        StorageLib.getLastBalanceConnectorId().value = lastBalanceConnectorId;

        StorageLib.getBalanceConnectorsArray().value.push(connector);
        emit BalanceConnectorAdded(marketId, connector);
    }

    function removeBalanceConnector(uint256 marketId, address connector) internal {
        StorageLib.BalanceConnectors storage balanceConnectors = StorageLib.getBalanceConnectors();
        balanceConnectors.value[marketId][connector] = 0;
        emit BalanceConnectorRemoved(marketId, connector);
    }

    function isBalanceConnectorSupported(uint256 marketId, address connector) internal view returns (bool) {
        return StorageLib.getBalanceConnectors().value[marketId][connector] == 1;
    }
}
