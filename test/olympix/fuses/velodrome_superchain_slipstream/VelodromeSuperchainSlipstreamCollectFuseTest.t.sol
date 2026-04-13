// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/velodrome_superchain_slipstream/VelodromeSuperchainSlipstreamCollectFuse.sol

import {VelodromeSuperchainSlipstreamCollectFuse, VelodromeSuperchainSlipstreamCollectFuseEnterData, VelodromeSuperchainSlipstreamCollectFuseEnterResult} from "contracts/fuses/velodrome_superchain_slipstream/VelodromeSuperchainSlipstreamCollectFuse.sol";
import {VelodromeSuperchainSlipstreamCollectFuse, VelodromeSuperchainSlipstreamCollectFuseEnterData} from "contracts/fuses/velodrome_superchain_slipstream/VelodromeSuperchainSlipstreamCollectFuse.sol";
import {INonfungiblePositionManager} from "contracts/fuses/velodrome_superchain_slipstream/ext/INonfungiblePositionManager.sol";
contract VelodromeSuperchainSlipstreamCollectFuseTest is OlympixUnitTest("VelodromeSuperchainSlipstreamCollectFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_EmptyTokenIds_HitsEarlyReturnBranch() public {
            // Deploy fuse with any non-zero position manager to avoid constructor revert
            VelodromeSuperchainSlipstreamCollectFuse fuse =
                new VelodromeSuperchainSlipstreamCollectFuse(1, address(0x1));
    
            // Prepare empty tokenIds array so len == 0 and early-return branch is taken
            uint256[] memory tokenIds = new uint256[](0);
            VelodromeSuperchainSlipstreamCollectFuseEnterData memory data =
                VelodromeSuperchainSlipstreamCollectFuseEnterData({tokenIds: tokenIds});
    
            // Act: call enter, which should hit the `if (len == 0)` branch and return default-initialized result
            VelodromeSuperchainSlipstreamCollectFuseEnterResult memory result = fuse.enter(data);
    
            // Assert: result fields are zero and no revert occurs
            assertEq(result.totalAmount0, 0, "totalAmount0 should be zero");
            assertEq(result.totalAmount1, 0, "totalAmount1 should be zero");
        }

    function test_enter_WithNonEmptyTokenIds_HitsNonEmptyBranch() public {
            // Arrange
            uint256 marketId = 1;
            // Use address(this) as a dummy NonfungiblePositionManager; we won't actually call it
            address nonfungiblePositionManager = address(this);
    
            VelodromeSuperchainSlipstreamCollectFuse fuse =
                new VelodromeSuperchainSlipstreamCollectFuse(marketId, nonfungiblePositionManager);
    
            uint256[] memory tokenIds = new uint256[](2);
            tokenIds[0] = 123;
            tokenIds[1] = 456;
    
            VelodromeSuperchainSlipstreamCollectFuseEnterData memory data =
                VelodromeSuperchainSlipstreamCollectFuseEnterData({tokenIds: tokenIds});
    
            // Act / Assert: expect revert because address(this) is not a real INonfungiblePositionManager,
            // but we still enter the non-empty branch and perform at least one external call.
            vm.expectRevert();
            fuse.enter(data);
        }
}