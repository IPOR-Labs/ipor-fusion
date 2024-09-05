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
        address fuse = address(0x1);
        uint256 marketId = 1;

        //when
        fusesLibMock.addBalanceFuse(marketId, fuse);

        //then
        assertTrue(fusesLibMock.isBalanceFuseSupported(marketId, fuse));
    }

    function testShouldRemoveBalanceFuse() public {
        //given
        uint256 marketId = 1;
        address fuse = address(new ZeroBalanceFuse(marketId));

        fusesLibMock.addBalanceFuse(marketId, fuse);

        bool fuseBefore = fusesLibMock.isBalanceFuseSupported(marketId, fuse);

        //when
        fusesLibMock.removeBalanceFuse(marketId, fuse);

        //then
        assertFalse(fusesLibMock.isBalanceFuseSupported(marketId, fuse));
        assertTrue(fuseBefore);
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

    function testShouldRemoveSecondFonnector() public {
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

    function testShouldOverrideOldBalanceFuse() public {
        //given
        address fuseOne = address(0x1);
        address fuseTwo = address(0x2);

        uint256 marketId = 1;

        fusesLibMock.addBalanceFuse(marketId, fuseOne);

        assertTrue(fusesLibMock.isBalanceFuseSupported(marketId, fuseOne) == true, "Fuse one should be added");

        //when
        fusesLibMock.addBalanceFuse(marketId, fuseTwo);

        //then
        assertTrue(fusesLibMock.isBalanceFuseSupported(marketId, fuseOne) == false, "Fuse four should be removed");
    }
}
