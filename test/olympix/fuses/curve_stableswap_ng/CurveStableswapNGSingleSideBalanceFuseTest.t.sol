// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideBalanceFuse.sol

import {CurveStableswapNGSingleSideBalanceFuse} from "contracts/fuses/curve_stableswap_ng/CurveStableswapNGSingleSideBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
contract CurveStableswapNGSingleSideBalanceFuseTest is OlympixUnitTest("CurveStableswapNGSingleSideBalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_returnsZeroWhenNoSubstrates() public {
            // Deploy fuse with MARKET_ID = 1
            CurveStableswapNGSingleSideBalanceFuse fuse = new CurveStableswapNGSingleSideBalanceFuse(1);
    
            // Ensure there are no substrates configured for MARKET_ID 1
            // (default state of PlasmaVaultConfigLib market substrates is empty)
            bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(1);
            assertEq(substrates.length, 0, "Expected no substrates for market 1");
    
            // When
            uint256 balance = fuse.balanceOf();
    
            // Then: should hit the `len == 0` branch and return 0
            assertEq(balance, 0, "Balance should be zero when no substrates are configured");
        }
}