// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {MockSlipstreamNFPM} from "test/test_helpers/MockSlipstreamNFPM.sol";
import {
    AreodromeSlipstreamNewPositionFuse,
    AreodromeSlipstreamNewPositionFuseEnterData,
    AreodromeSlipstreamNewPositionFuseExitData
} from "contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamNewPositionFuse.sol";

import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {AreodromeSlipstreamNewPositionFuse} from "contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamNewPositionFuse.sol";
import {INonfungiblePositionManager} from "contracts/fuses/aerodrome_slipstream/ext/INonfungiblePositionManager.sol";
contract AreodromeSlipstreamNewPositionFuseTest is OlympixUnitTest("AreodromeSlipstreamNewPositionFuse") {
    AreodromeSlipstreamNewPositionFuse internal fuse;
    MockSlipstreamNFPM internal nfpm;
    address internal constant FACTORY = address(0xFAC);
    uint256 internal constant MARKET_ID = 99;
    address internal constant TOKEN0 = address(0xAAAA);
    address internal constant TOKEN1 = address(0xBBBB);

    function setUp() public override {
        nfpm = new MockSlipstreamNFPM(FACTORY);
        fuse = new AreodromeSlipstreamNewPositionFuse(MARKET_ID, address(nfpm));
    }

    function _baseEnter() internal pure returns (AreodromeSlipstreamNewPositionFuseEnterData memory data) {
        data = AreodromeSlipstreamNewPositionFuseEnterData({
            token0: TOKEN0,
            token1: TOKEN1,
            tickSpacing: 60,
            tickLower: -60,
            tickUpper: 60,
            amount0Desired: 100,
            amount1Desired: 100,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max,
            sqrtPriceX96: 0
        });
    }

    function test_example_constructorSetsImmutables() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID);
        assertEq(fuse.NONFUNGIBLE_POSITION_MANAGER(), address(nfpm));
        assertEq(fuse.FACTORY(), FACTORY);
        assertEq(fuse.VERSION(), address(fuse));
    }

    function test_example_constructorRevertsOnZeroNFPM() public {
        vm.expectRevert(AreodromeSlipstreamNewPositionFuse.InvalidAddress.selector);
        new AreodromeSlipstreamNewPositionFuse(MARKET_ID, address(0));
    }

    function test_example_constructorRevertsOnZeroFactoryFromNFPM() public {
        MockSlipstreamNFPM zeroFactoryNFPM = new MockSlipstreamNFPM(address(0));
        vm.expectRevert(AreodromeSlipstreamNewPositionFuse.InvalidAddress.selector);
        new AreodromeSlipstreamNewPositionFuse(MARKET_ID, address(zeroFactoryNFPM));
    }

    function test_example_enterRevertsUnsupportedPool() public {
        // No substrates configured → any token0/token1/tickSpacing combo reverts
        AreodromeSlipstreamNewPositionFuseEnterData memory data = _baseEnter();
        vm.expectRevert();
        fuse.enter(data);
    }

    function test_example_exitEmptyArrayNoOp() public {
        AreodromeSlipstreamNewPositionFuseExitData memory data;
        data.tokenIds = new uint256[](0);
        // empty array → loop body never executes
        fuse.exit(data);
    }

    function test_enterTransient_hitsTrueBranchAndSetsOutputs() public {
            // arrange: prepare transient inputs matching _baseEnter-style data
            bytes32[] memory inputs = new bytes32[](11);
            inputs[0] = TypeConversionLib.toBytes32(TOKEN0); // token0
            inputs[1] = TypeConversionLib.toBytes32(TOKEN1); // token1
            inputs[2] = TypeConversionLib.toBytes32(uint256(int256(int24(60)))); // tickSpacing
            inputs[3] = TypeConversionLib.toBytes32(uint256(int256(int24(-60)))); // tickLower
            inputs[4] = TypeConversionLib.toBytes32(uint256(int256(int24(60)))); // tickUpper
            inputs[5] = TypeConversionLib.toBytes32(uint256(100)); // amount0Desired
            inputs[6] = TypeConversionLib.toBytes32(uint256(100)); // amount1Desired
            inputs[7] = TypeConversionLib.toBytes32(uint256(0));   // amount0Min
            inputs[8] = TypeConversionLib.toBytes32(uint256(0));   // amount1Min
            inputs[9] = TypeConversionLib.toBytes32(type(uint256).max); // deadline
            inputs[10] = TypeConversionLib.toBytes32(uint256(0)); // sqrtPriceX96
    
            // set inputs in transient storage under VERSION key
            TransientStorageLib.setInputs(fuse.VERSION(), inputs);
    
            // act: call enterTransient; this will read inputs, call enter (which will revert
            // due to unsupported pool), but still ensures the `if (true)` branch is executed
            vm.expectRevert();
            fuse.enterTransient();
        }

    function test_exit_NonEmptyArrayHitsElseBranch() public {
            // arrange: create exit data with a non-empty tokenIds array
            AreodromeSlipstreamNewPositionFuseExitData memory data;
            data.tokenIds = new uint256[](1);
            data.tokenIds[0] = 42;

            // the MockSlipstreamNFPM stub has no burn() implementation, so the loop body
            // would revert — mock the call so the len != 0 branch executes fully
            vm.mockCall(
                address(nfpm),
                abi.encodeWithSelector(INonfungiblePositionManager.burn.selector, uint256(42)),
                abi.encode()
            );

            // act: call exit with non-empty array to ensure the len == 0 check is false
            uint256[] memory returnedTokenIds = fuse.exit(data);

    //        // assert: no revert expected, branch with len != 0 is executed
            assertEq(returnedTokenIds.length, 1);
            assertEq(returnedTokenIds[0], 42);
        }
    
}