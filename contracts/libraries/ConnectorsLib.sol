// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {StorageLib} from "./StorageLib.sol";

library ConnectorsLib {
    function addConnector(uint256 marketId, address connector) internal {
        StorageLib.Connectors storage connectors = StorageLib.getConnectors();
        connectors.value[marketId][connector] = 1;
    }

    function removeConnector(uint256 marketId, address connector) internal {
        StorageLib.Connectors storage connectors = StorageLib.getConnectors();
        connectors.value[marketId][connector] = 0;
    }

    function isConnectorSupported(uint256 marketId, address connector) internal view returns (bool) {
        return StorageLib.getConnectors().value[marketId][connector] == 1;
    }

    function addBalanceConnector(uint256 marketId, address connector) internal {
        StorageLib.BalanceConnectors storage balanceConnectors = StorageLib.getBalanceConnectors();
        balanceConnectors.value[marketId][connector] = 1;
    }

    function removeBalanceConnector(uint256 marketId, address connector) internal {
        StorageLib.BalanceConnectors storage balanceConnectors = StorageLib.getBalanceConnectors();
        balanceConnectors.value[marketId][connector] = 0;
    }

    function isBalanceConnectorSupported(uint256 marketId, address connector) internal view returns (bool) {
        return StorageLib.getBalanceConnectors().value[marketId][connector] == 1;
    }
}