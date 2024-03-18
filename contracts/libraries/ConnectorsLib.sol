// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {StorageLib} from "./StorageLib.sol";

library ConnectorsLib {
    function addConnector(address connector) internal {
        //TODO: events

        StorageLib.Connectors storage connectors = StorageLib.getConnectors();
        connectors.value[connector] = 1;
    }

    function removeConnector(address connector) internal {
        StorageLib.Connectors storage connectors = StorageLib.getConnectors();
        connectors.value[connector] = 0;
    }

    function isConnectorSupported(address connector) internal view returns (bool) {
        return StorageLib.getConnectors().value[connector] == 1;
    }

    function addBalanceConnector(uint256 marketId, address connector) internal {
        StorageLib.BalanceConnectors storage balanceConnectors = StorageLib.getBalanceConnectors();
        balanceConnectors.value[marketId][connector] = 1;
        //TODO: add to array list;
    }

    function removeBalanceConnector(uint256 marketId, address connector) internal {
        StorageLib.BalanceConnectors storage balanceConnectors = StorageLib.getBalanceConnectors();
        balanceConnectors.value[marketId][connector] = 0;
    }

    function isBalanceConnectorSupported(uint256 marketId, address connector) internal view returns (bool) {
        return StorageLib.getBalanceConnectors().value[marketId][connector] == 1;
    }
}