// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/curve_gauge/CurveChildLiquidityGaugeBalanceFuse.sol

import {CurveChildLiquidityGaugeBalanceFuse} from "contracts/fuses/curve_gauge/CurveChildLiquidityGaugeBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IChildLiquidityGauge} from "contracts/fuses/curve_gauge/ext/IChildLiquidityGauge.sol";
import {ICurveStableswapNG} from "contracts/fuses/curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
contract CurveChildLiquidityGaugeBalanceFuseTest is OlympixUnitTest("CurveChildLiquidityGaugeBalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_NoSubstrates_returnsZero_andHitsIfTrueBranch() public {
            // Arrange: deploy fuse with some MARKET_ID
            uint256 marketId = 1;
            CurveChildLiquidityGaugeBalanceFuse fuse = new CurveChildLiquidityGaugeBalanceFuse(marketId);
    
            // Sanity: ensure there are no substrates configured for this MARKET_ID
            bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
            assertEq(substrates.length, 0, "Expected no substrates so first if condition is true");
    
            // Also set a dummy price oracle middleware so PlasmaVaultLib.getPriceOracleMiddleware() is valid
            PriceOracleMiddlewareMock oracle = new PriceOracleMiddlewareMock(address(0), 18, address(0));
            PlasmaVaultLib.setPriceOracleMiddleware(address(oracle));
    
            // Act: call balanceOf on the fuse (which will read market substrates via PlasmaVaultConfigLib)
            uint256 balance = fuse.balanceOf();
    
            // Assert: when len == 0, function returns 0, hitting the opix-target-branch-36-True path
            assertEq(balance, 0, "Balance should be zero when there are no substrates configured");
        }
}