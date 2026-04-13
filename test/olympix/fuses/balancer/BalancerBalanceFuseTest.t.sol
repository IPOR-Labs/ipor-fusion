// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/balancer/BalancerBalanceFuse.sol

import {BalancerBalanceFuse} from "contracts/fuses/balancer/BalancerBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {BalancerSubstrate, BalancerSubstrateType, BalancerSubstrateLib} from "contracts/fuses/balancer/BalancerSubstrateLib.sol";
import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
import {IPool} from "contracts/fuses/balancer/ext/IPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
contract BalancerBalanceFuseTest is OlympixUnitTest("BalancerBalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_NoSubstratesReturnsZero() public {
            // Arrange: deploy fuse for a fresh MARKET_ID that has no substrates configured
            uint256 marketId = 9999;
            BalancerBalanceFuse fuse = new BalancerBalanceFuse(marketId);
    
            // Sanity: ensure getMarketSubstrates for this market is empty so the
            // `if (len == 0)` branch is taken
            bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
            assertEq(substrates.length, 0, "Expected no substrates for this marketId");
    
            // Also set a dummy (non‑zero) price oracle middleware so the test only
            // validates the len == 0 branch and returns early before oracle use
            PlasmaVaultLib.setPriceOracleMiddleware(address(0x1));
    
            // Act: call balanceOf on the fuse via this test contract (delegatecall target)
            uint256 balance = fuse.balanceOf();
    
            // Assert: when there are no substrates, balanceOf must return 0
            assertEq(balance, 0, "Expected zero balance when no substrates are configured");
        }
}