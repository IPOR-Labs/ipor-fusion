// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

import {EbisuZapperBalanceFuse} from "contracts/fuses/ebisu/EbisuZapperBalanceFuse.sol";

/// @dev Target contract: contracts/fuses/ebisu/EbisuZapperBalanceFuse.sol

import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {FuseStorageLib} from "contracts/libraries/FuseStorageLib.sol";
import {EbisuZapperSubstrateLib, EbisuZapperSubstrate, EbisuZapperSubstrateType} from "contracts/fuses/ebisu/lib/EbisuZapperSubstrateLib.sol";
import {ILeverageZapper} from "contracts/fuses/ebisu/ext/ILeverageZapper.sol";
import {ITroveManager} from "contracts/fuses/ebisu/ext/ITroveManager.sol";
import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
contract EbisuZapperBalanceFuseTest is OlympixUnitTest("EbisuZapperBalanceFuse") {
    EbisuZapperBalanceFuse public ebisuZapperBalanceFuse;


    function setUp() public override {
        ebisuZapperBalanceFuse = new EbisuZapperBalanceFuse(1);
    }

    function test_deployment_doesNotRevert() public view {
        assertTrue(address(ebisuZapperBalanceFuse) != address(0), "Contract should be deployed");
    }

    function test_balanceOf_NoSubstratesReturnsZero() public {
            // Ensure market 1 has no substrates configured
            bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(1);
            assertEq(substrates.length, 0, "Precondition: no substrates for market 1");
    
            // When: calling balanceOf on the fuse
            uint256 balance = ebisuZapperBalanceFuse.balanceOf();
    
            // Then: with zero substrates, function should return 0 and hit the early return branch
            assertEq(balance, 0, "Balance should be zero when no substrates are configured");
        }
}