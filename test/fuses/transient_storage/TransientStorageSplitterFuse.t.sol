// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TransientStorageSplitterFuse, TransientStorageSplitterFuseEnterData, TransientStorageSplitterRoute} from "../../../contracts/fuses/transient_storage/TransientStorageSplitterFuse.sol";
import {TransientStorageParamTypes} from "../../../contracts/transient_storage/TransientStorageLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {TransientStorageSplitterFuseMock} from "./TransientStorageSplitterFuseMock.sol";

/// @title TransientStorageSplitterFuseTest
/// @notice Tests for TransientStorageSplitterFuse
/// @author IPOR Labs
contract TransientStorageSplitterFuseTest is Test {
    /// @notice The fuse contract being tested
    TransientStorageSplitterFuse public fuse;

    /// @notice The mock contract for executing fuse
    TransientStorageSplitterFuseMock public mock;

    /// @notice Setup the test environment
    function setUp() public {
        fuse = new TransientStorageSplitterFuse();
        mock = new TransientStorageSplitterFuseMock(address(fuse));
    }

    /// @notice Test MARKET_ID constant value
    function testMarketId() public view {
        assertEq(fuse.MARKET_ID(), IporFusionMarkets.ZERO_BALANCE_MARKET, "MARKET_ID should equal ZERO_BALANCE_MARKET");
    }

    /// @notice Test VERSION returns fuse address
    function testVersion() public view {
        assertEq(fuse.VERSION(), address(fuse), "VERSION should equal fuse address");
    }

    /// @notice Test basic 60/40 split across two routes
    function testSplitTwoRoutes() public {
        address sourceFuse = address(0x1);
        address destFuse1 = address(0x2);
        address destFuse2 = address(0x3);

        // Set source input: total = 1000
        bytes32[] memory sourceInputs = new bytes32[](1);
        sourceInputs[0] = bytes32(uint256(1000));
        mock.setInputs(sourceFuse, sourceInputs);

        // Pre-initialize destination fuse inputs
        bytes32[] memory dest1Inputs = new bytes32[](1);
        mock.setInputs(destFuse1, dest1Inputs);
        bytes32[] memory dest2Inputs = new bytes32[](1);
        mock.setInputs(destFuse2, dest2Inputs);

        // Build routes: 60/40 split
        TransientStorageSplitterRoute[] memory routes = new TransientStorageSplitterRoute[](2);
        routes[0] = TransientStorageSplitterRoute({
            destinationFuse: destFuse1,
            destinationIndex: 0,
            numerator: 60
        });
        routes[1] = TransientStorageSplitterRoute({
            destinationFuse: destFuse2,
            destinationIndex: 0,
            numerator: 40
        });

        TransientStorageSplitterFuseEnterData memory data = TransientStorageSplitterFuseEnterData({
            sourceParamType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            sourceAddress: sourceFuse,
            sourceIndex: 0,
            denominator: 100,
            routes: routes
        });

        mock.enter(data);

        assertEq(uint256(mock.getInput(destFuse1, 0)), 600, "Route 1 should get 600 (60%)");
        assertEq(uint256(mock.getInput(destFuse2, 0)), 400, "Route 2 should get 400 (40%)");
    }

    /// @notice Test 50/30/20 split across three routes
    function testSplitThreeRoutes() public {
        address sourceFuse = address(0x1);
        address destFuse1 = address(0x2);
        address destFuse2 = address(0x3);
        address destFuse3 = address(0x4);

        // Set source input: total = 10000
        bytes32[] memory sourceInputs = new bytes32[](1);
        sourceInputs[0] = bytes32(uint256(10000));
        mock.setInputs(sourceFuse, sourceInputs);

        // Pre-initialize destination fuse inputs
        bytes32[] memory dest1Inputs = new bytes32[](1);
        mock.setInputs(destFuse1, dest1Inputs);
        bytes32[] memory dest2Inputs = new bytes32[](1);
        mock.setInputs(destFuse2, dest2Inputs);
        bytes32[] memory dest3Inputs = new bytes32[](1);
        mock.setInputs(destFuse3, dest3Inputs);

        // Build routes: 50/30/20 split
        TransientStorageSplitterRoute[] memory routes = new TransientStorageSplitterRoute[](3);
        routes[0] = TransientStorageSplitterRoute({
            destinationFuse: destFuse1,
            destinationIndex: 0,
            numerator: 50
        });
        routes[1] = TransientStorageSplitterRoute({
            destinationFuse: destFuse2,
            destinationIndex: 0,
            numerator: 30
        });
        routes[2] = TransientStorageSplitterRoute({
            destinationFuse: destFuse3,
            destinationIndex: 0,
            numerator: 20
        });

        TransientStorageSplitterFuseEnterData memory data = TransientStorageSplitterFuseEnterData({
            sourceParamType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            sourceAddress: sourceFuse,
            sourceIndex: 0,
            denominator: 100,
            routes: routes
        });

        mock.enter(data);

        assertEq(uint256(mock.getInput(destFuse1, 0)), 5000, "Route 1 should get 5000 (50%)");
        assertEq(uint256(mock.getInput(destFuse2, 0)), 3000, "Route 2 should get 3000 (30%)");
        assertEq(uint256(mock.getInput(destFuse3, 0)), 2000, "Route 3 should get 2000 (20%)");
    }

    /// @notice Test that dust from integer division goes to the last route
    function testSplitRemainderGoesToLastRoute() public {
        address sourceFuse = address(0x1);
        address destFuse1 = address(0x2);
        address destFuse2 = address(0x3);
        address destFuse3 = address(0x4);

        // Set source input: total = 1000, split 3 ways evenly => 333 + 333 + 334
        bytes32[] memory sourceInputs = new bytes32[](1);
        sourceInputs[0] = bytes32(uint256(1000));
        mock.setInputs(sourceFuse, sourceInputs);

        // Pre-initialize destination fuse inputs
        bytes32[] memory dest1Inputs = new bytes32[](1);
        mock.setInputs(destFuse1, dest1Inputs);
        bytes32[] memory dest2Inputs = new bytes32[](1);
        mock.setInputs(destFuse2, dest2Inputs);
        bytes32[] memory dest3Inputs = new bytes32[](1);
        mock.setInputs(destFuse3, dest3Inputs);

        // Build routes: equal 1/3 each
        TransientStorageSplitterRoute[] memory routes = new TransientStorageSplitterRoute[](3);
        routes[0] = TransientStorageSplitterRoute({
            destinationFuse: destFuse1,
            destinationIndex: 0,
            numerator: 1
        });
        routes[1] = TransientStorageSplitterRoute({
            destinationFuse: destFuse2,
            destinationIndex: 0,
            numerator: 1
        });
        routes[2] = TransientStorageSplitterRoute({
            destinationFuse: destFuse3,
            destinationIndex: 0,
            numerator: 1
        });

        TransientStorageSplitterFuseEnterData memory data = TransientStorageSplitterFuseEnterData({
            sourceParamType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            sourceAddress: sourceFuse,
            sourceIndex: 0,
            denominator: 3,
            routes: routes
        });

        mock.enter(data);

        // 1000 * 1 / 3 = 333 for first two routes
        assertEq(uint256(mock.getInput(destFuse1, 0)), 333, "Route 1 should get 333");
        assertEq(uint256(mock.getInput(destFuse2, 0)), 333, "Route 2 should get 333");
        // Last route gets remainder: 1000 - 333 - 333 = 334
        assertEq(uint256(mock.getInput(destFuse3, 0)), 334, "Route 3 should get 334 (remainder)");
    }

    /// @notice Test 100% to single route (edge case)
    function testSplitSingleRoute() public {
        address sourceFuse = address(0x1);
        address destFuse1 = address(0x2);

        // Set source input: total = 5000
        bytes32[] memory sourceInputs = new bytes32[](1);
        sourceInputs[0] = bytes32(uint256(5000));
        mock.setInputs(sourceFuse, sourceInputs);

        // Pre-initialize destination fuse inputs
        bytes32[] memory dest1Inputs = new bytes32[](1);
        mock.setInputs(destFuse1, dest1Inputs);

        // Build routes: 100% to one route
        TransientStorageSplitterRoute[] memory routes = new TransientStorageSplitterRoute[](1);
        routes[0] = TransientStorageSplitterRoute({
            destinationFuse: destFuse1,
            destinationIndex: 0,
            numerator: 1
        });

        TransientStorageSplitterFuseEnterData memory data = TransientStorageSplitterFuseEnterData({
            sourceParamType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            sourceAddress: sourceFuse,
            sourceIndex: 0,
            denominator: 1,
            routes: routes
        });

        mock.enter(data);

        // Single route gets entire amount (as remainder since it's the last/only route)
        assertEq(uint256(mock.getInput(destFuse1, 0)), 5000, "Single route should get full amount");
    }

    /// @notice Test revert when denominator is zero
    function testRevertZeroDenominator() public {
        TransientStorageSplitterRoute[] memory routes = new TransientStorageSplitterRoute[](1);
        routes[0] = TransientStorageSplitterRoute({
            destinationFuse: address(0x2),
            destinationIndex: 0,
            numerator: 1
        });

        TransientStorageSplitterFuseEnterData memory data = TransientStorageSplitterFuseEnterData({
            sourceParamType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            sourceAddress: address(0x1),
            sourceIndex: 0,
            denominator: 0,
            routes: routes
        });

        vm.expectRevert(TransientStorageSplitterFuse.TransientStorageSplitterFuseZeroDenominator.selector);
        mock.enter(data);
    }

    /// @notice Test revert when routes array is empty
    function testRevertEmptyRoutes() public {
        TransientStorageSplitterRoute[] memory routes = new TransientStorageSplitterRoute[](0);

        TransientStorageSplitterFuseEnterData memory data = TransientStorageSplitterFuseEnterData({
            sourceParamType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            sourceAddress: address(0x1),
            sourceIndex: 0,
            denominator: 100,
            routes: routes
        });

        vm.expectRevert(TransientStorageSplitterFuse.TransientStorageSplitterFuseEmptyRoutes.selector);
        mock.enter(data);
    }

    /// @notice Test revert when sum of numerators does not equal denominator
    function testRevertNumeratorSumMismatch() public {
        TransientStorageSplitterRoute[] memory routes = new TransientStorageSplitterRoute[](2);
        routes[0] = TransientStorageSplitterRoute({
            destinationFuse: address(0x2),
            destinationIndex: 0,
            numerator: 60
        });
        routes[1] = TransientStorageSplitterRoute({
            destinationFuse: address(0x3),
            destinationIndex: 0,
            numerator: 30
        });

        TransientStorageSplitterFuseEnterData memory data = TransientStorageSplitterFuseEnterData({
            sourceParamType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            sourceAddress: address(0x1),
            sourceIndex: 0,
            denominator: 100,
            routes: routes
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                TransientStorageSplitterFuse.TransientStorageSplitterFuseNumeratorSumMismatch.selector,
                90,
                100
            )
        );
        mock.enter(data);
    }

    /// @notice Test revert when a destination address is zero
    function testRevertZeroDestinationAddress() public {
        TransientStorageSplitterRoute[] memory routes = new TransientStorageSplitterRoute[](2);
        routes[0] = TransientStorageSplitterRoute({
            destinationFuse: address(0), // Invalid
            destinationIndex: 0,
            numerator: 50
        });
        routes[1] = TransientStorageSplitterRoute({
            destinationFuse: address(0x3),
            destinationIndex: 0,
            numerator: 50
        });

        TransientStorageSplitterFuseEnterData memory data = TransientStorageSplitterFuseEnterData({
            sourceParamType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            sourceAddress: address(0x1),
            sourceIndex: 0,
            denominator: 100,
            routes: routes
        });

        vm.expectRevert(TransientStorageSplitterFuse.TransientStorageSplitterFuseZeroDestinationAddress.selector);
        mock.enter(data);
    }

    /// @notice Test splitting from source fuse outputs (not just inputs)
    function testSplitFromOutputs() public {
        address sourceFuse = address(0x1);
        address destFuse1 = address(0x2);
        address destFuse2 = address(0x3);

        // Set source output: total = 2000
        bytes32[] memory sourceOutputs = new bytes32[](1);
        sourceOutputs[0] = bytes32(uint256(2000));
        mock.setOutputs(sourceFuse, sourceOutputs);

        // Pre-initialize destination fuse inputs
        bytes32[] memory dest1Inputs = new bytes32[](1);
        mock.setInputs(destFuse1, dest1Inputs);
        bytes32[] memory dest2Inputs = new bytes32[](1);
        mock.setInputs(destFuse2, dest2Inputs);

        // Build routes: 70/30 split from outputs
        TransientStorageSplitterRoute[] memory routes = new TransientStorageSplitterRoute[](2);
        routes[0] = TransientStorageSplitterRoute({
            destinationFuse: destFuse1,
            destinationIndex: 0,
            numerator: 70
        });
        routes[1] = TransientStorageSplitterRoute({
            destinationFuse: destFuse2,
            destinationIndex: 0,
            numerator: 30
        });

        TransientStorageSplitterFuseEnterData memory data = TransientStorageSplitterFuseEnterData({
            sourceParamType: TransientStorageParamTypes.OUTPUTS_BY_FUSE,
            sourceAddress: sourceFuse,
            sourceIndex: 0,
            denominator: 100,
            routes: routes
        });

        mock.enter(data);

        assertEq(uint256(mock.getInput(destFuse1, 0)), 1400, "Route 1 should get 1400 (70%)");
        assertEq(uint256(mock.getInput(destFuse2, 0)), 600, "Route 2 should get 600 (30%)");
    }

    /// @notice Test with realistic token amounts (18 decimals)
    function testSplitLargeAmount() public {
        address sourceFuse = address(0x1);
        address destFuse1 = address(0x2);
        address destFuse2 = address(0x3);

        // 100 tokens with 18 decimals = 100e18
        uint256 totalAmount = 100 * 1e18;
        bytes32[] memory sourceInputs = new bytes32[](1);
        sourceInputs[0] = bytes32(totalAmount);
        mock.setInputs(sourceFuse, sourceInputs);

        // Pre-initialize destination fuse inputs
        bytes32[] memory dest1Inputs = new bytes32[](1);
        mock.setInputs(destFuse1, dest1Inputs);
        bytes32[] memory dest2Inputs = new bytes32[](1);
        mock.setInputs(destFuse2, dest2Inputs);

        // Build routes: 60/40 split with basis points (10000)
        TransientStorageSplitterRoute[] memory routes = new TransientStorageSplitterRoute[](2);
        routes[0] = TransientStorageSplitterRoute({
            destinationFuse: destFuse1,
            destinationIndex: 0,
            numerator: 6000
        });
        routes[1] = TransientStorageSplitterRoute({
            destinationFuse: destFuse2,
            destinationIndex: 0,
            numerator: 4000
        });

        TransientStorageSplitterFuseEnterData memory data = TransientStorageSplitterFuseEnterData({
            sourceParamType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            sourceAddress: sourceFuse,
            sourceIndex: 0,
            denominator: 10000,
            routes: routes
        });

        mock.enter(data);

        assertEq(uint256(mock.getInput(destFuse1, 0)), 60 * 1e18, "Route 1 should get 60e18 (60%)");
        assertEq(uint256(mock.getInput(destFuse2, 0)), 40 * 1e18, "Route 2 should get 40e18 (40%)");
    }

    /// @notice Test writing to different indices in destination fuses
    function testSplitToDifferentIndices() public {
        address sourceFuse = address(0x1);
        address destFuse1 = address(0x2);

        // Set source input: total = 1000
        bytes32[] memory sourceInputs = new bytes32[](1);
        sourceInputs[0] = bytes32(uint256(1000));
        mock.setInputs(sourceFuse, sourceInputs);

        // Pre-initialize destination fuse with 3 input slots
        bytes32[] memory dest1Inputs = new bytes32[](3);
        dest1Inputs[0] = bytes32(uint256(999)); // existing value
        mock.setInputs(destFuse1, dest1Inputs);

        // Build routes: 50/50 split, writing to indices 1 and 2 of same fuse
        TransientStorageSplitterRoute[] memory routes = new TransientStorageSplitterRoute[](2);
        routes[0] = TransientStorageSplitterRoute({
            destinationFuse: destFuse1,
            destinationIndex: 1,
            numerator: 50
        });
        routes[1] = TransientStorageSplitterRoute({
            destinationFuse: destFuse1,
            destinationIndex: 2,
            numerator: 50
        });

        TransientStorageSplitterFuseEnterData memory data = TransientStorageSplitterFuseEnterData({
            sourceParamType: TransientStorageParamTypes.INPUTS_BY_FUSE,
            sourceAddress: sourceFuse,
            sourceIndex: 0,
            denominator: 100,
            routes: routes
        });

        mock.enter(data);

        // Index 0 should remain unchanged
        assertEq(uint256(mock.getInput(destFuse1, 0)), 999, "Index 0 should remain unchanged");
        assertEq(uint256(mock.getInput(destFuse1, 1)), 500, "Index 1 should get 500 (50%)");
        assertEq(uint256(mock.getInput(destFuse1, 2)), 500, "Index 2 should get 500 (50%)");
    }

    /// @notice Test revert with UNKNOWN param type
    function testRevertUnknownParamType() public {
        address sourceFuse = address(0x1);
        address destFuse1 = address(0x2);

        bytes32[] memory sourceInputs = new bytes32[](1);
        sourceInputs[0] = bytes32(uint256(1000));
        mock.setInputs(sourceFuse, sourceInputs);

        bytes32[] memory dest1Inputs = new bytes32[](1);
        mock.setInputs(destFuse1, dest1Inputs);

        TransientStorageSplitterRoute[] memory routes = new TransientStorageSplitterRoute[](1);
        routes[0] = TransientStorageSplitterRoute({
            destinationFuse: destFuse1,
            destinationIndex: 0,
            numerator: 1
        });

        TransientStorageSplitterFuseEnterData memory data = TransientStorageSplitterFuseEnterData({
            sourceParamType: TransientStorageParamTypes.UNKNOWN,
            sourceAddress: sourceFuse,
            sourceIndex: 0,
            denominator: 1,
            routes: routes
        });

        vm.expectRevert(TransientStorageSplitterFuse.TransientStorageSplitterFuseUnknownParamType.selector);
        mock.enter(data);
    }
}
