// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/ramses/RamsesV2CollectFuse.sol

import {RamsesV2CollectFuse, RamsesV2CollectFuseEnterData} from "contracts/fuses/ramses/RamsesV2CollectFuse.sol";
import {INonfungiblePositionManagerRamses} from "contracts/fuses/ramses/ext/INonfungiblePositionManagerRamses.sol";
contract RamsesV2CollectFuseTest is OlympixUnitTest("RamsesV2CollectFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_WithNonEmptyTokenIds_HitsElseBranchAndCollects() public {
            // deploy a minimal mock NonfungiblePositionManagerRamses inline via address + interface expectation
            // we only need to ensure enter() is invoked with non-empty tokenIds so that
            // `if (len == 0)` is false and the `else { assert(true); }` branch is taken.
    
            // 1. Deploy a simple mock that returns fixed amounts on collect
            // We use address(this) as the NONFUNGIBLE_POSITION_MANAGER because
            // this test contract already has the correct `collect` function signature via the interface.
            // Define expected return values
            uint256 expectedAmount0 = 1e18;
            uint256 expectedAmount1 = 2e18;
    
            // 2. Configure this test contract to behave as the position manager via prank
            // Foundry can't dynamically add functions, so we perform a low-level expectation instead.
            // We know enter() will call NONFUNGIBLE_POSITION_MANAGER.collect with specific params.
    
            // Prepare fuse instance with NONFUNGIBLE_POSITION_MANAGER set to this contract
            RamsesV2CollectFuse fuse = new RamsesV2CollectFuse(1, address(this));
    
            // Prepare tokenIds so len > 0
            uint256[] memory tokenIds = new uint256[](1);
            tokenIds[0] = 123;
            RamsesV2CollectFuseEnterData memory data_ = RamsesV2CollectFuseEnterData({tokenIds: tokenIds});
    
            // Expect a call to this contract as INonfungiblePositionManagerRamses.collect
            INonfungiblePositionManagerRamses.CollectParams memory params = INonfungiblePositionManagerRamses.CollectParams({
                tokenId: tokenIds[0],
                recipient: address(fuse),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
    
            // Set up mock expectation: when `collect` is called with these params, return fixed amounts
            vm.mockCall(
                address(this),
                abi.encodeWithSelector(INonfungiblePositionManagerRamses.collect.selector, params),
                abi.encode(expectedAmount0, expectedAmount1)
            );
    
            // 3. Call enter and verify it returns aggregated totals (and thus hit the else-branch)
            (uint256 totalAmount0, uint256 totalAmount1) = fuse.enter(data_);
    
            assertEq(totalAmount0, expectedAmount0, "totalAmount0 should equal mocked amount0");
            assertEq(totalAmount1, expectedAmount1, "totalAmount1 should equal mocked amount1");
        }
}