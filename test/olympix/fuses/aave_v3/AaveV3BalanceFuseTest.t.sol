// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/aave_v3/AaveV3BalanceFuse.sol

import {AaveV3BalanceFuse} from "contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";
contract AaveV3BalanceFuseTest is OlympixUnitTest("AaveV3BalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_returnsZeroWhenNoSubstrates() public {
            // Deploy with valid, non-zero marketId and provider to avoid constructor reverts
            AaveV3BalanceFuse fuse = new AaveV3BalanceFuse(1, address(0x1));
    
            // When there are no substrates configured for MARKET_ID, balanceOf should
            // hit the `len == 0` branch and return 0 without reverting
            uint256 balance = fuse.balanceOf();
    
            assertEq(balance, 0, "Expected zero balance when no substrates configured");
        }
}