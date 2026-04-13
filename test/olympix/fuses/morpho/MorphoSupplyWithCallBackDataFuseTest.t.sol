// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/morpho/MorphoSupplyWithCallBackDataFuse.sol

import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {MorphoSupplyWithCallBackDataFuse, MorphoSupplyFuseExitData} from "contracts/fuses/morpho/MorphoSupplyWithCallBackDataFuse.sol";
contract MorphoSupplyWithCallBackDataFuseTest is OlympixUnitTest("MorphoSupplyWithCallBackDataFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_exit_InternalExitReturnsZeroWhenAmountIsZero() public {
            // Deploy the fuse with an arbitrary MARKET_ID
            MorphoSupplyWithCallBackDataFuse fuse = new MorphoSupplyWithCallBackDataFuse(1);
    
            // Prepare exit data with amount == 0 to hit the opix-target-branch-214-True branch
            MorphoSupplyFuseExitData memory data_ = MorphoSupplyFuseExitData({
                morphoMarketId: bytes32(uint256(0)),
                amount: 0
            });
    
            // Call exit, which internally calls _exit and should early-return zeros
            (address asset, bytes32 market, uint256 amount) = fuse.exit(data_);
    
            assertEq(asset, address(0));
            assertEq(market, bytes32(0));
            assertEq(amount, 0);
        }

    function test_exit_InternalExitElseBranchWhenAmountNonZeroAndUnsupportedMarket() public {
            // Deploy the fuse with an arbitrary MARKET_ID
            MorphoSupplyWithCallBackDataFuse fuse = new MorphoSupplyWithCallBackDataFuse(1);
    
            // Prepare exit data with amount != 0 to hit the opix-target-branch-216-Else branch
            // and use an unsupported morphoMarketId so that the call reverts on the next check
            MorphoSupplyFuseExitData memory data_ = MorphoSupplyFuseExitData({
                morphoMarketId: bytes32(uint256(0)),
                amount: 1
            });
    
            // Expect revert due to unsupported market; this confirms we passed the amount==0 check
            vm.expectRevert();
            fuse.exit(data_);
        }
}