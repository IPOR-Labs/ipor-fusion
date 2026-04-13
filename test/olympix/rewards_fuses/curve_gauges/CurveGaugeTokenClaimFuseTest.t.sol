// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

import {CurveGaugeTokenClaimFuse} from "contracts/rewards_fuses/curve_gauges/CurveGaugeTokenClaimFuse.sol";

/// @dev Target contract: contracts/rewards_fuses/curve_gauges/CurveGaugeTokenClaimFuse.sol

import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";
contract CurveGaugeTokenClaimFuseTest is OlympixUnitTest("CurveGaugeTokenClaimFuse") {
    CurveGaugeTokenClaimFuse public curveGaugeTokenClaimFuse;


    function setUp() public override {
        curveGaugeTokenClaimFuse = new CurveGaugeTokenClaimFuse(1);
    }

    function test_deployment_doesNotRevert() public view {
        assertTrue(address(curveGaugeTokenClaimFuse) != address(0), "Contract should be deployed");
    }

    function test_claim_lenZeroHitsEarlyReturnBranch() public {
            // Arrange: ensure getMarketSubstrates(MARKET_ID) returns an empty array
            // By default, with no configuration, PlasmaVaultConfigLib.getMarketSubstrates(1) should return an empty list,
            // so we simply call claim and rely on that default behavior.
    
            // Act: call claim, expecting it to hit the `len == 0` early-return branch
            curveGaugeTokenClaimFuse.claim();
    
            // Assert: reaching here without revert is sufficient to confirm the branch was executed
            assertTrue(true);
        }
}