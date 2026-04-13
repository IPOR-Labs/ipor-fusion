// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/gearbox_v3/GearboxV3FarmBalanceFuse.sol

import {GearboxV3FarmBalanceFuse} from "contracts/fuses/gearbox_v3/GearboxV3FarmBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {IFarmingPool} from "contracts/fuses/gearbox_v3/ext/IFarmingPool.sol";
import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
contract GearboxV3FarmBalanceFuseTest is OlympixUnitTest("GearboxV3FarmBalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_ReturnsZeroWhenNoSubstrates() public {
            // Arrange: set up a non-zero marketId and deploy the fuse
            uint256 marketId = 1;
            GearboxV3FarmBalanceFuse fuse = new GearboxV3FarmBalanceFuse(marketId);
    
            // Ensure there are no substrates configured for this market
            bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
            assertEq(substrates.length, 0, "Precondition: substrates should be empty");
    
            // Act: call balanceOf
            uint256 balance = fuse.balanceOf();
    
            // Assert: should hit the `len == 0` branch and return 0
            assertEq(balance, 0, "Balance should be zero when no substrates are configured");
        }
}