// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FusesLibMock} from "./FusesLibMock.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {DustBalanceFuseMock} from "./DustBalanceFuseMock.sol";

contract FusesLibTest is Test {
    FusesLibMock internal fusesLibMock;

    function setUp() public {
        fusesLibMock = new FusesLibMock();
    }

    function testShouldAddBalanceFuse() public {
        //given
        uint256 marketId = 1;
        address fuse = address(new ZeroBalanceFuse(marketId));

        //when
        fusesLibMock.addBalanceFuse(marketId, fuse);

        //then
        assertTrue(fusesLibMock.isBalanceFuseSupported(marketId, fuse));
        assertEq(fusesLibMock.getBalanceFusesIndexes(marketId), 1, "Index should be 1");
    }

    function testShouldAddThreeBalanceFuses() public {
        //given
        uint256 marketIdOne = 1;
        uint256 marketIdTwo = 2;
        uint256 marketIdThree = 3;
        address fuseOne = address(new ZeroBalanceFuse(marketIdOne));
        address fuseTwo = address(new ZeroBalanceFuse(marketIdTwo));
        address fuseThree = address(new ZeroBalanceFuse(marketIdThree));

        //when
        fusesLibMock.addBalanceFuse(marketIdOne, fuseOne);
        fusesLibMock.addBalanceFuse(marketIdTwo, fuseTwo);
        fusesLibMock.addBalanceFuse(marketIdThree, fuseThree);

        //then
        assertEq(fusesLibMock.getBalanceFusesIndexes(marketIdOne), 1);
        assertEq(fusesLibMock.getBalanceFusesIndexes(marketIdTwo), 2);
        assertEq(fusesLibMock.getBalanceFusesIndexes(marketIdThree), 3);

        assertEq(fusesLibMock.isBalanceFuseSupported(marketIdOne, fuseOne), true);
        assertEq(fusesLibMock.isBalanceFuseSupported(marketIdTwo, fuseTwo), true);
        assertEq(fusesLibMock.isBalanceFuseSupported(marketIdThree, fuseThree), true);
    }

    function testShouldRemoveBalanceFuse() public {
        //given
        uint256 marketId = 1;
        address fuse = address(new ZeroBalanceFuse(marketId));

        fusesLibMock.addBalanceFuse(marketId, fuse);

        bool fuseBefore = fusesLibMock.isBalanceFuseSupported(marketId, fuse);

        assertEq(fusesLibMock.getBalanceFusesIndexes(marketId), 1);

        //when
        fusesLibMock.removeBalanceFuse(marketId, fuse);

        //then
        assertFalse(fusesLibMock.isBalanceFuseSupported(marketId, fuse));
        assertTrue(fuseBefore);
        assertEq(fusesLibMock.getBalanceFusesIndexes(marketId), 0);
    }

    function testShouldNotAddBalanceFuseBecauseOfMarketIdMismatch() public {
        //given
        uint256 marketId = 1;
        address fuse = address(new ZeroBalanceFuse(marketId + 1));

        bytes memory error = abi.encodeWithSignature("BalanceFuseMarketIdMismatch(uint256,address)", marketId, fuse);

        //then
        vm.expectRevert(error);
        //when
        fusesLibMock.addBalanceFuse(marketId, fuse);
    }

    function testShouldNotRemoveBalanceFuseBecauseOfDust() public {
        //given
        uint256 marketId = 1;
        uint256 underlyingDecimals = 18;
        address fuse = address(new DustBalanceFuseMock(marketId, underlyingDecimals));

        fusesLibMock.addBalanceFuse(marketId, fuse);

        bytes memory error = abi.encodeWithSignature(
            "BalanceFuseNotReadyToRemove(uint256,address,uint256)",
            marketId,
            fuse,
            10 ** (underlyingDecimals / 2) + 1
        );

        //when
        vm.expectRevert(error);
        fusesLibMock.removeBalanceFuse(marketId, fuse);
    }

    function testShouldNotRemoveBalanceFuseBecauseOfMarketIdMismatch() public {
        //given
        uint256 marketId = 1;
        address fuse = address(new ZeroBalanceFuse(marketId));

        fusesLibMock.addBalanceFuse(marketId, fuse);

        bytes memory error = abi.encodeWithSignature(
            "BalanceFuseMarketIdMismatch(uint256,address)",
            marketId + 1,
            fuse
        );

        //when
        vm.expectRevert(error);
        fusesLibMock.removeBalanceFuse(marketId + 1, fuse);
    }

    function testShouldCleanUpBalanceFusesStructureWhenFourFusesAreAddedWhenRemovingSecondBalanceFuse() public {
        //given
        uint256 marketIdOne = 11;
        uint256 marketIdTwo = 22;
        uint256 marketIdThree = 33;
        uint256 marketIdFour = 44;
        address fuse1 = address(new ZeroBalanceFuse(marketIdOne));
        address fuse2 = address(new ZeroBalanceFuse(marketIdTwo));
        address fuse3 = address(new ZeroBalanceFuse(marketIdThree));
        address fuse4 = address(new ZeroBalanceFuse(marketIdFour));

        fusesLibMock.addBalanceFuse(marketIdOne, fuse1);
        fusesLibMock.addBalanceFuse(marketIdTwo, fuse2);
        fusesLibMock.addBalanceFuse(marketIdThree, fuse3);
        fusesLibMock.addBalanceFuse(marketIdFour, fuse4);

        //when
        fusesLibMock.removeBalanceFuse(marketIdTwo, fuse2);

        //then
        assertTrue(fusesLibMock.isBalanceFuseSupported(marketIdOne, fuse1), "Fuse1 should still be supported");
        assertFalse(fusesLibMock.isBalanceFuseSupported(marketIdTwo, fuse2), "Fuse2 should be removed");
        assertTrue(fusesLibMock.isBalanceFuseSupported(marketIdThree, fuse3), "Fuse3 should still be supported");
        assertTrue(fusesLibMock.isBalanceFuseSupported(marketIdFour, fuse4), "Fuse4 should still be supported");

        assertEq(fusesLibMock.getBalanceFusesIndexes(marketIdOne), 1, "Index should be 1");
        assertEq(fusesLibMock.getBalanceFusesIndexes(marketIdTwo), 0, "Index should be 0");
        assertEq(fusesLibMock.getBalanceFusesIndexes(marketIdThree), 3, "Index should be 3");
        assertEq(fusesLibMock.getBalanceFusesIndexes(marketIdFour), 2, "Index should be 2");

        uint256[] memory marketIds = fusesLibMock.getBalanceFusesMarketIds();
        assertEq(marketIds.length, 3, "Array length should be 3");
        assertEq(marketIds[0], marketIdOne, "First element should be marketIdOne");
        assertEq(marketIds[1], marketIdFour, "Second element should be marketIdThree");
        assertEq(marketIds[2], marketIdThree, "Third element should be marketIdFour");
    }

    function testShouldCleanUpBalanceFusesStructureWhenFourFusesAreAddedWhenRemovingFirstBalanceFuse() public {
        //given
        uint256 marketIdOne = 11;
        uint256 marketIdTwo = 22;
        uint256 marketIdThree = 33;
        uint256 marketIdFour = 44;
        address fuse1 = address(new ZeroBalanceFuse(marketIdOne));
        address fuse2 = address(new ZeroBalanceFuse(marketIdTwo));
        address fuse3 = address(new ZeroBalanceFuse(marketIdThree));
        address fuse4 = address(new ZeroBalanceFuse(marketIdFour));

        fusesLibMock.addBalanceFuse(marketIdOne, fuse1);
        fusesLibMock.addBalanceFuse(marketIdTwo, fuse2);
        fusesLibMock.addBalanceFuse(marketIdThree, fuse3);
        fusesLibMock.addBalanceFuse(marketIdFour, fuse4);

        //when
        fusesLibMock.removeBalanceFuse(marketIdOne, fuse1);

        //then
        assertFalse(fusesLibMock.isBalanceFuseSupported(marketIdOne, fuse1), "Fuse1 should be removed");
        assertTrue(fusesLibMock.isBalanceFuseSupported(marketIdTwo, fuse2), "Fuse2 should still be supported");
        assertTrue(fusesLibMock.isBalanceFuseSupported(marketIdThree, fuse3), "Fuse3 should still be supported");
        assertTrue(fusesLibMock.isBalanceFuseSupported(marketIdFour, fuse4), "Fuse4 should still be supported");

        assertEq(fusesLibMock.getBalanceFusesIndexes(marketIdOne), 0, "Index should be 0");
        assertEq(fusesLibMock.getBalanceFusesIndexes(marketIdTwo), 2, "Index should be 1");
        assertEq(fusesLibMock.getBalanceFusesIndexes(marketIdThree), 3, "Index should be 2");
        assertEq(fusesLibMock.getBalanceFusesIndexes(marketIdFour), 1, "Index should be 3");

        uint256[] memory marketIds = fusesLibMock.getBalanceFusesMarketIds();
        assertEq(marketIds.length, 3, "Array length should be 3");
        assertEq(marketIds[0], marketIdFour, "First element should be marketIdFour");
        assertEq(marketIds[1], marketIdTwo, "Second element should be marketIdTwo");
        assertEq(marketIds[2], marketIdThree, "Third element should be marketIdThree");
    }

    function testShouldCleanUpBalanceFusesStructureWhenFourFusesAreAddedWhenRemovingLastBalanceFuse() public {
        //given
        uint256 marketIdOne = 11;
        uint256 marketIdTwo = 22;
        uint256 marketIdThree = 33;
        uint256 marketIdFour = 44;
        address fuse1 = address(new ZeroBalanceFuse(marketIdOne));
        address fuse2 = address(new ZeroBalanceFuse(marketIdTwo));
        address fuse3 = address(new ZeroBalanceFuse(marketIdThree));
        address fuse4 = address(new ZeroBalanceFuse(marketIdFour));

        fusesLibMock.addBalanceFuse(marketIdOne, fuse1);
        fusesLibMock.addBalanceFuse(marketIdTwo, fuse2);
        fusesLibMock.addBalanceFuse(marketIdThree, fuse3);
        fusesLibMock.addBalanceFuse(marketIdFour, fuse4);

        //when
        fusesLibMock.removeBalanceFuse(marketIdFour, fuse4);

        //then
        assertTrue(fusesLibMock.isBalanceFuseSupported(marketIdOne, fuse1), "Fuse1 should still be supported");
        assertTrue(fusesLibMock.isBalanceFuseSupported(marketIdTwo, fuse2), "Fuse2 should still be supported");
        assertTrue(fusesLibMock.isBalanceFuseSupported(marketIdThree, fuse3), "Fuse3 should still be supported");
        assertFalse(fusesLibMock.isBalanceFuseSupported(marketIdFour, fuse4), "Fuse4 should be removed");

        assertEq(fusesLibMock.getBalanceFusesIndexes(marketIdOne), 1, "Index should be 1");
        assertEq(fusesLibMock.getBalanceFusesIndexes(marketIdTwo), 2, "Index should be 2");
        assertEq(fusesLibMock.getBalanceFusesIndexes(marketIdThree), 3, "Index should be 3");
        assertEq(fusesLibMock.getBalanceFusesIndexes(marketIdFour), 0, "Index should be 0");

        uint256[] memory marketIds = fusesLibMock.getBalanceFusesMarketIds();
        assertEq(marketIds.length, 3, "Array length should be 3");
        assertEq(marketIds[0], marketIdOne, "First element should be marketIdOne");
        assertEq(marketIds[1], marketIdTwo, "Second element should be marketIdTwo");
        assertEq(marketIds[2], marketIdThree, "Third element should be marketIdThree");
    }

    function testShouldRemoveFuseCheckLastFuseId() public {
        //given
        address fuseOne = address(0x1);
        address fuseTwo = address(0x2);
        address fuseThree = address(0x3);
        address fuseFour = address(0x4);

        fusesLibMock.addFuse(fuseOne);
        fusesLibMock.addFuse(fuseTwo);
        fusesLibMock.addFuse(fuseThree);
        fusesLibMock.addFuse(fuseFour);

        //when
        fusesLibMock.removeFuse(fuseTwo);

        //then
        assertTrue(fusesLibMock.isFuseSupported(fuseTwo) == false, "Fuse two should be removed");

        /// @dev fuse four should be moved to index 1
        assertTrue(fusesLibMock.getFusesArray()[1] == fuseFour, "Fuse four should be at index 1");

        /// @dev lastFuseId should be 3
        assertTrue(fusesLibMock.getFusesArray().length == 3);

        /// @dev fuse four in mapping should be 2
        assertTrue(fusesLibMock.getFuseArrayIndex(fuseFour) == 2, "Fuse four should be at index 2");
    }

    function testShouldRemoveFirstFuse() public {
        //given
        address fuseOne = address(0x1);
        address fuseTwo = address(0x2);
        address fuseThree = address(0x3);
        address fuseFour = address(0x4);

        fusesLibMock.addFuse(fuseOne);
        fusesLibMock.addFuse(fuseTwo);
        fusesLibMock.addFuse(fuseThree);
        fusesLibMock.addFuse(fuseFour);

        //when
        fusesLibMock.removeFuse(fuseOne);

        //then
        assertTrue(fusesLibMock.isFuseSupported(fuseOne) == false, "Fuse one should be removed");

        /// @dev fuse four should be moved to index 0
        assertTrue(fusesLibMock.getFusesArray()[0] == fuseFour, "Fuse four should be at index 0");

        /// @dev lastFuseId should be 3
        assertTrue(fusesLibMock.getFusesArray().length == 3);

        /// @dev fuse four in mapping should be 1
        assertTrue(fusesLibMock.getFuseArrayIndex(fuseFour) == 1, "Fuse four should be at index 1");
    }

    function testShouldRemoveSecondFuse() public {
        //given
        address fuseOne = address(0x1);
        address fuseTwo = address(0x2);
        address fuseThree = address(0x3);
        address fuseFour = address(0x4);

        fusesLibMock.addFuse(fuseOne);
        fusesLibMock.addFuse(fuseTwo);
        fusesLibMock.addFuse(fuseThree);
        fusesLibMock.addFuse(fuseFour);

        //when
        fusesLibMock.removeFuse(fuseTwo);

        //then
        assertTrue(fusesLibMock.isFuseSupported(fuseTwo) == false, "Fuse two should be removed");

        /// @dev fuse four should be moved to index 1
        assertTrue(fusesLibMock.getFusesArray()[1] == fuseFour, "Fuse four should be at index 1");

        /// @dev lastFuseId should be 3
        assertTrue(fusesLibMock.getFusesArray().length == 3);

        /// @dev fuse four in mapping should be 2
        assertTrue(fusesLibMock.getFuseArrayIndex(fuseFour) == 2, "Fuse four should be at index 2");
    }

    function testShouldRemoveSecondFuseAndCheckAllArraysAreUpdated() public {
        //given
        address fuseOne = address(0x1);
        address fuseTwo = address(0x2);
        address fuseThree = address(0x3);
        address fuseFour = address(0x4);

        fusesLibMock.addFuse(fuseOne);
        fusesLibMock.addFuse(fuseTwo);
        fusesLibMock.addFuse(fuseThree);
        fusesLibMock.addFuse(fuseFour);

        //when
        fusesLibMock.removeFuse(fuseTwo);

        //then
        address[] memory fusesArray = fusesLibMock.getFusesArray();
        assertEq(fusesArray.length, 3, "Array length should be 3");
        assertEq(fusesArray[0], fuseOne, "Fuse one should be at index 0");
        assertEq(fusesArray[1], fuseFour, "Fuse four should be at index 1");
        assertEq(fusesArray[2], fuseThree, "Fuse three should be at index 2");

        assertEq(fusesLibMock.getFuseArrayIndex(fuseOne), 1, "Fuse one should be at index 1");
        assertEq(fusesLibMock.getFuseArrayIndex(fuseTwo), 0, "Fuse two should be at index 0");
        assertEq(fusesLibMock.getFuseArrayIndex(fuseThree), 3, "Fuse three should be at index 2");
        assertEq(fusesLibMock.getFuseArrayIndex(fuseFour), 2, "Fuse four should be at index 3");
    }

    function testShouldOverrideOldBalanceFuse() public {
        //given
        uint256 marketId = 1;
        address fuseOne = address(new ZeroBalanceFuse(marketId));
        address fuseTwo = address(new ZeroBalanceFuse(marketId));

        fusesLibMock.addBalanceFuse(marketId, fuseOne);

        assertTrue(fusesLibMock.isBalanceFuseSupported(marketId, fuseOne) == true, "Fuse one should be added");

        //when
        fusesLibMock.addBalanceFuse(marketId, fuseTwo);

        //then
        assertTrue(fusesLibMock.isBalanceFuseSupported(marketId, fuseOne) == false, "Fuse four should be removed");
    }
}
