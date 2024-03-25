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
        connectorsLibMock.addBalanceConnector(marketId, connector);

        //then
        assertTrue(connectorsLibMock.isBalanceConnectorSupported(marketId, connector));
    }

    function testShouldRemoveBalanceConnector() public {
        //given
        address connector = address(0x1);
        uint256 marketId = 1;
        connectorsLibMock.addBalanceConnector(marketId, connector);
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

    function testShouldRemoveBalanceConnectorCheckLastBalanceConnectorId() public {
        //given
        address connectorOne = address(0x1);
        address connectorTwo = address(0x2);
        address connectorThree = address(0x3);
        address connectorFour = address(0x4);

        uint256 marketId = 1;
        connectorsLibMock.addBalanceConnector(marketId, connectorOne);
        connectorsLibMock.addBalanceConnector(marketId, connectorTwo);
        connectorsLibMock.addBalanceConnector(marketId, connectorThree);
        connectorsLibMock.addBalanceConnector(marketId, connectorFour);

        //when
        connectorsLibMock.removeBalanceConnector(marketId, connectorTwo);

        //then
        assertTrue(
            connectorsLibMock.isBalanceConnectorSupported(marketId, connectorTwo) == false,
            "Connector two should be removed"
        );

        bytes32 key = keccak256(abi.encodePacked(marketId, connectorFour));

        /// @dev connector four should be moved to index 1
        assertTrue(connectorsLibMock.getBalanceConnectorsArray()[1] == key, "Connector four should be at index 1");

        /// @dev lastBalanceConnectorId should be 3
        assertTrue(connectorsLibMock.getBalanceConnectorsArray().length == 3);

        /// @dev connector four in mapping should be 2
        assertTrue(
            connectorsLibMock.getBalanceConnectorArrayIndex(marketId, connectorFour) == 2,
            "Connector four should be at index 2"
        );
    }

    function testShouldRemoveFirstBalanceConnector() public {
        //given
        address connectorOne = address(0x1);
        address connectorTwo = address(0x2);
        address connectorThree = address(0x3);
        address connectorFour = address(0x4);

        uint256 marketId = 1;
        connectorsLibMock.addBalanceConnector(marketId, connectorOne);
        connectorsLibMock.addBalanceConnector(marketId, connectorTwo);
        connectorsLibMock.addBalanceConnector(marketId, connectorThree);
        connectorsLibMock.addBalanceConnector(marketId, connectorFour);

        //when
        connectorsLibMock.removeBalanceConnector(marketId, connectorOne);

        //then
        assertTrue(
            connectorsLibMock.isBalanceConnectorSupported(marketId, connectorOne) == false,
            "Connector one should be removed"
        );

        bytes32 key = keccak256(abi.encodePacked(marketId, connectorFour));

        /// @dev connector four should be moved to index 0
        assertTrue(connectorsLibMock.getBalanceConnectorsArray()[0] == key, "Connector four should be at index 0");

        /// @dev lastBalanceConnectorId should be 3
        assertTrue(connectorsLibMock.getBalanceConnectorsArray().length == 3);

        /// @dev connector four in mapping should be 1
        assertTrue(
            connectorsLibMock.getBalanceConnectorArrayIndex(marketId, connectorFour) == 1,
            "Connector four should be at index 1"
        );
    }

    function testShouldRemoveLastConnector() public {
        //given
        address connectorOne = address(0x1);
        address connectorTwo = address(0x2);
        address connectorThree = address(0x3);
        address connectorFour = address(0x4);

        uint256 marketId = 1;

        connectorsLibMock.addBalanceConnector(marketId, connectorOne);
        connectorsLibMock.addBalanceConnector(marketId, connectorTwo);
        connectorsLibMock.addBalanceConnector(marketId, connectorThree);
        connectorsLibMock.addBalanceConnector(marketId, connectorFour);

        //when
        connectorsLibMock.removeBalanceConnector(marketId, connectorFour);

        //then
        assertTrue(
            connectorsLibMock.isBalanceConnectorSupported(marketId, connectorFour) == false,
            "Connector four should be removed"
        );

        bytes32 key = keccak256(abi.encodePacked(marketId, connectorThree));

        /// @dev connector three should be moved to index 3
        assertTrue(connectorsLibMock.getBalanceConnectorsArray()[2] == key, "Connector three should be at index 3");

        /// @dev lastBalanceConnectorId should be 3
        assertTrue(connectorsLibMock.getBalanceConnectorsArray().length == 3);

        /// @dev connector three in mapping should be 3
        assertTrue(
            connectorsLibMock.getBalanceConnectorArrayIndex(marketId, connectorThree) == 3,
            "Connector three should be at index 3"
        );
    }

    function testShouldRemoveAllFourConnectors() public {
        //given
        address connectorOne = address(0x1);
        address connectorTwo = address(0x2);
        address connectorThree = address(0x3);
        address connectorFour = address(0x4);

        uint256 marketId = 1;
        connectorsLibMock.addBalanceConnector(marketId, connectorOne);
        connectorsLibMock.addBalanceConnector(marketId, connectorTwo);
        connectorsLibMock.addBalanceConnector(marketId, connectorThree);
        connectorsLibMock.addBalanceConnector(marketId, connectorFour);

        //when
        connectorsLibMock.removeBalanceConnector(marketId, connectorOne);

        //then
        assertTrue(
            connectorsLibMock.isBalanceConnectorSupported(marketId, connectorOne) == false,
            "Connector one should be removed"
        );

        //when
        connectorsLibMock.removeBalanceConnector(marketId, connectorTwo);

        //then
        assertTrue(
            connectorsLibMock.isBalanceConnectorSupported(marketId, connectorTwo) == false,
            "Connector two should be removed"
        );

        //when
        connectorsLibMock.removeBalanceConnector(marketId, connectorThree);
        //then
        assertTrue(
            connectorsLibMock.isBalanceConnectorSupported(marketId, connectorThree) == false,
            "Connector three should be removed"
        );

        //when
        connectorsLibMock.removeBalanceConnector(marketId, connectorFour);
        //then
        assertTrue(
            connectorsLibMock.isBalanceConnectorSupported(marketId, connectorFour) == false,
            "Connector four should be removed"
        );
    }

    function testShouldAddBalanceConnectorAndLastBalanceConnectorIdCorrect() public {
        //given
        address connector = address(0x1);
        uint256 marketId = 1;
        bytes32 key = keccak256(abi.encodePacked(marketId, connector));

        //when
        connectorsLibMock.addBalanceConnector(marketId, connector);

        //then
        uint256 lastBalanceConnectorId = connectorsLibMock.getBalanceConnectorsArray().length;
        assertTrue(lastBalanceConnectorId == 1);

        bytes32[] memory balanceConnectorsArray = connectorsLibMock.getBalanceConnectorsArray();

        assertTrue(balanceConnectorsArray.length == 1);

        assertTrue(balanceConnectorsArray[0] == key);
    }
}
