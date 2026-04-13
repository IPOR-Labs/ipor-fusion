// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/morpho/MorphoBalanceFuse.sol

import {MorphoBalanceFuse} from "contracts/fuses/morpho/MorphoBalanceFuse.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";
contract MorphoBalanceFuseTest is OlympixUnitTest("MorphoBalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_ReturnsZeroWhenNoMorphoMarketsConfigured() public {
            // Given: deploy fuse with any valid non-zero marketId and non-zero Morpho address
            MorphoBalanceFuse fuse = new MorphoBalanceFuse(1, address(0x1));
    
            // When: no substrates/markets are configured in PlasmaVaultConfigLib for MARKET_ID,
            // the internal call to PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID) returns an empty array,
            // so len == 0 and the function should return 0 hitting `if (len == 0)` branch.
            uint256 balance = fuse.balanceOf();
    
            // Then: balance is zero and branch opix-target-branch-86-True is covered
            assertEq(balance, 0);
        }
}