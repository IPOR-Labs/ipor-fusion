// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {ConnectorsLib} from "../../contracts/libraries/ConnectorsLib.sol";

contract ConnectorsLibMock {
    function addConnector(address connector) external {
        ConnectorsLib.addConnector(connector);
    }

    function removeConnector(address connector) external {
        ConnectorsLib.removeConnector(connector);
    }

    function isConnectorSupported(address connector) external view returns (bool) {
        return ConnectorsLib.isConnectorSupported(connector);
    }

    function addBalanceConnector(uint256 marketId, address connector) external {
        ConnectorsLib.addBalanceConnector(marketId, connector);
    }

    function removeBalanceConnector(uint256 marketId, address connector) external {
        ConnectorsLib.removeBalanceConnector(marketId, connector);
    }

    function isBalanceConnectorSupported(uint256 marketId, address connector) external view returns (bool) {
        return ConnectorsLib.isBalanceConnectorSupported(marketId, connector);
    }

    function getBalanceConnectorArrayIndex(uint256 marketId, address connector) external view returns (uint256) {
        return ConnectorsLib.getBalanceConnectorArrayIndex(marketId, connector);
    }

    function getBalanceConnectorsArray() external view returns (bytes32[] memory) {
        return ConnectorsLib.getBalanceConnectorsArray();
    }

    function getConnectorsArray() external view returns (address[] memory) {
        return ConnectorsLib.getConnectorsArray();
    }

    function getConnectorArrayIndex(address connector) external view returns (uint256) {
        return ConnectorsLib.getConnectorArrayIndex(connector);
    }
}
