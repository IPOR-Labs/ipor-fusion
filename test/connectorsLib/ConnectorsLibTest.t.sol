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
        assertTrue(connectorsLibMock.getLastBalanceConnectorId() == 3);

        /// @dev connector four in mapping should be 2
        assertTrue(
            connectorsLibMock.getBalanceConnectorIndex(marketId, connectorFour) == 2,
            "Connector four should be at index 2"
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
        uint256 lastBalanceConnectorId = connectorsLibMock.getLastBalanceConnectorId();
        assertTrue(lastBalanceConnectorId == 1);

        bytes32[] memory balanceConnectorsArray = connectorsLibMock.getBalanceConnectorsArray();

        assertTrue(balanceConnectorsArray.length == 1);

        assertTrue(balanceConnectorsArray[0] == key);
    }
}
