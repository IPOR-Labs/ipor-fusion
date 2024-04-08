// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ConnectorsLibMock} from "./ConnectorsLibMock.sol";

contract ConnectorsLibTest is Test {
    ConnectorsLibMock internal connectorsLibMock;

    function setUp() public {
        connectorsLibMock = new ConnectorsLibMock();
    }

    function testShouldAddBalanceConnector() public {
        //given
        address connector = address(0x1);
        uint256 marketId = 1;

        //when
        connectorsLibMock.setBalanceFuse(marketId, connector);

        //then
        assertTrue(connectorsLibMock.isBalanceConnectorSupported(marketId, connector));
    }

    function testShouldRemoveBalanceConnector() public {
        //given
        address connector = address(0x1);
        uint256 marketId = 1;
        connectorsLibMock.setBalanceFuse(marketId, connector);
        bool connectorBefore = connectorsLibMock.isBalanceConnectorSupported(marketId, connector);

        //when
        connectorsLibMock.removeBalanceConnector(marketId, connector);

        //then
        assertFalse(connectorsLibMock.isBalanceConnectorSupported(marketId, connector));
        assertTrue(connectorBefore);
    }

    function testShouldRemoveConnectorCheckLastConnectorId() public {
        //given
        address connectorOne = address(0x1);
        address connectorTwo = address(0x2);
        address connectorThree = address(0x3);
        address connectorFour = address(0x4);

        connectorsLibMock.addConnector(connectorOne);
        connectorsLibMock.addConnector(connectorTwo);
        connectorsLibMock.addConnector(connectorThree);
        connectorsLibMock.addConnector(connectorFour);

        //when
        connectorsLibMock.removeConnector(connectorTwo);

        //then
        assertTrue(connectorsLibMock.isConnectorSupported(connectorTwo) == false, "Connector two should be removed");

        /// @dev connector four should be moved to index 1
        assertTrue(connectorsLibMock.getConnectorsArray()[1] == connectorFour, "Connector four should be at index 1");

        /// @dev lastConnectorId should be 3
        assertTrue(connectorsLibMock.getConnectorsArray().length == 3);

        /// @dev connector four in mapping should be 2
        assertTrue(connectorsLibMock.getConnectorArrayIndex(connectorFour) == 2, "Connector four should be at index 2");
    }

    function testShouldRemoveFirstConnector() public {
        //given
        address connectorOne = address(0x1);
        address connectorTwo = address(0x2);
        address connectorThree = address(0x3);
        address connectorFour = address(0x4);

        connectorsLibMock.addConnector(connectorOne);
        connectorsLibMock.addConnector(connectorTwo);
        connectorsLibMock.addConnector(connectorThree);
        connectorsLibMock.addConnector(connectorFour);

        //when
        connectorsLibMock.removeConnector(connectorOne);

        //then
        assertTrue(connectorsLibMock.isConnectorSupported(connectorOne) == false, "Connector one should be removed");

        /// @dev connector four should be moved to index 0
        assertTrue(connectorsLibMock.getConnectorsArray()[0] == connectorFour, "Connector four should be at index 0");

        /// @dev lastConnectorId should be 3
        assertTrue(connectorsLibMock.getConnectorsArray().length == 3);

        /// @dev connector four in mapping should be 1
        assertTrue(connectorsLibMock.getConnectorArrayIndex(connectorFour) == 1, "Connector four should be at index 1");
    }

    function testShouldRemoveSecondFonnector() public {
        //given
        address connectorOne = address(0x1);
        address connectorTwo = address(0x2);
        address connectorThree = address(0x3);
        address connectorFour = address(0x4);

        connectorsLibMock.addConnector(connectorOne);
        connectorsLibMock.addConnector(connectorTwo);
        connectorsLibMock.addConnector(connectorThree);
        connectorsLibMock.addConnector(connectorFour);

        //when
        connectorsLibMock.removeConnector(connectorTwo);

        //then
        assertTrue(connectorsLibMock.isConnectorSupported(connectorTwo) == false, "Connector two should be removed");

        /// @dev connector four should be moved to index 1
        assertTrue(connectorsLibMock.getConnectorsArray()[1] == connectorFour, "Connector four should be at index 1");

        /// @dev lastConnectorId should be 3
        assertTrue(connectorsLibMock.getConnectorsArray().length == 3);

        /// @dev connector four in mapping should be 2
        assertTrue(connectorsLibMock.getConnectorArrayIndex(connectorFour) == 2, "Connector four should be at index 2");
    }

    function testShouldOverrideOldBalanceConnector() public {
        //given
        address connectorOne = address(0x1);
        address connectorTwo = address(0x2);

        uint256 marketId = 1;

        connectorsLibMock.setBalanceFuse(marketId, connectorOne);

        assertTrue(
            connectorsLibMock.isBalanceConnectorSupported(marketId, connectorOne) == true,
            "Connector one should be added"
        );

        //when
        connectorsLibMock.setBalanceFuse(marketId, connectorTwo);

        //then
        assertTrue(
            connectorsLibMock.isBalanceConnectorSupported(marketId, connectorOne) == false,
            "Connector four should be removed"
        );
    }
}
