// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {StorageLib} from "./StorageLib.sol";
import {IConnectorCommon} from "../vaults/IConnectorCommon.sol";

library ConnectorsLib {
    event ConnectorAdded(address indexed connector);
    event ConnectorRemoved(address indexed connector);
    event BalanceConnectorAdded(uint256 indexed marketId, address indexed connector);
    event BalanceConnectorRemoved(uint256 indexed marketId, address indexed connector);

    error ConnectorAlreadyExists();
    error ConnectorDoesNotExist();
    error BalanceConnectorAlreadyExists(uint256 marketId, address connector);
    error BalanceConnectorDoesNotExist(uint256 marketId, address connector);

    function addConnector(address connector) internal {
        StorageLib.Connectors storage connectors = StorageLib.getConnectors();

        uint256 keyIndexValue = connectors.value[connector];

        if (keyIndexValue != 0) {
            revert ConnectorAlreadyExists();
        }

        uint256 newLastConnectorId = StorageLib.getConnectorsArray().value.length + 1;

        /// @dev for balance connectors, value is a index + 1 in the connectorsArray
        connectors.value[connector] = newLastConnectorId;

        StorageLib.getConnectorsArray().value.push(connector);

        emit ConnectorAdded(connector);
    }

    function removeConnector(address connector) internal {
        StorageLib.Connectors storage connectors = StorageLib.getConnectors();

        uint256 indexToRemove = connectors.value[connector];

        if (indexToRemove == 0) {
            revert ConnectorDoesNotExist();
        }

        address lastKeyInArray = StorageLib.getConnectorsArray().value[
            StorageLib.getConnectorsArray().value.length - 1
        ];

        connectors.value[lastKeyInArray] = indexToRemove;

        connectors.value[connector] = 0;

        /// @dev balanceConnectors mapping contains values as index + 1
        StorageLib.getConnectorsArray().value[indexToRemove - 1] = lastKeyInArray;

        StorageLib.getConnectorsArray().value.pop();

        emit ConnectorRemoved(connector);
    }

    function isConnectorSupported(address connector) internal view returns (bool) {
        return StorageLib.getConnectors().value[connector] != 0;
    }

    function addBalanceConnector(uint256 marketId, address connector) internal {
        StorageLib.BalanceConnectors storage balanceConnectors = StorageLib.getBalanceConnectors();
        bytes32 key = keccak256(abi.encodePacked(marketId, connector));

        uint256 keyIndexValue = balanceConnectors.value[key];

        if (keyIndexValue != 0) {
            revert BalanceConnectorAlreadyExists(marketId, connector);
        }

        uint256 newLastBalanceConnectorId = StorageLib.getBalanceConnectorsArray().value.length + 1;

        /// @dev for balance connectors, value is a index + 1 in the balanceConnectorsArray
        balanceConnectors.value[key] = newLastBalanceConnectorId;

        StorageLib.getBalanceConnectorsArray().value.push(key);

        StorageLib.getMarketBalanceConnectors().value[marketId] = connector;

        emit BalanceConnectorAdded(marketId, connector);
    }

    function removeBalanceConnector(uint256 marketId, address connector) internal {
        StorageLib.BalanceConnectors storage balanceConnectors = StorageLib.getBalanceConnectors();

        bytes32 key = keccak256(abi.encodePacked(marketId, connector));

        uint256 indexToRemove = balanceConnectors.value[key];

        if (indexToRemove == 0) {
            revert BalanceConnectorDoesNotExist(marketId, connector);
        }

        bytes32 lastKeyInArray = StorageLib.getBalanceConnectorsArray().value[
            StorageLib.getBalanceConnectorsArray().value.length - 1
        ];

        balanceConnectors.value[lastKeyInArray] = indexToRemove;

        balanceConnectors.value[key] = 0;

        /// @dev balanceConnectors mapping contains values as index + 1
        StorageLib.getBalanceConnectorsArray().value[indexToRemove - 1] = lastKeyInArray;

        //        StorageLib.getMaketBalanceConnectors().value[marketId] = address(0);

        StorageLib.getBalanceConnectorsArray().value.pop();

        emit BalanceConnectorRemoved(marketId, connector);
    }

    function isBalanceConnectorSupported(uint256 marketId, address connector) internal view returns (bool) {
        bytes32 key = keccak256(abi.encodePacked(marketId, connector));
        return StorageLib.getBalanceConnectors().value[key] != 0;
    }

    function getBalanceConnectorArrayIndex(uint256 marketId, address connector) internal view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(marketId, connector));
        return StorageLib.getBalanceConnectors().value[key];
    }

    function getBalanceConnectorsArray() internal view returns (bytes32[] memory) {
        return StorageLib.getBalanceConnectorsArray().value;
    }

    //    function getMarketBalanceConnectors() internal view returns (address[] memory) {
    //        return StorageLib.getMarketBalanceConnectors().value;
    //    }

    function getConnectorsArray() internal view returns (address[] memory) {
        return StorageLib.getConnectorsArray().value;
    }

    function getConnectorArrayIndex(address connector) internal view returns (uint256) {
        return StorageLib.getConnectors().value[connector];
    }

    function updateBalance(uint256 marketId) internal {
        bytes32[] memory balanceConnectors = getBalanceConnectorsArray();
        for (uint256 i = 0; i < balanceConnectors.length; ++i) {
            //            (uint256 marketIdInArray, address connector) = abi.decode(balanceConnectors[i], (uint256, address));
            //            if (marketIdInArray == marketId) {
            //                IConnectorCommon(connector).updateBalance();
            //            }
        }
    }
}
