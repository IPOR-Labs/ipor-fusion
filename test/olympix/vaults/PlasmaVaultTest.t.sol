// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

import {PlasmaVault} from "contracts/vaults/PlasmaVault.sol";

/// @dev Target contract: contracts/vaults/PlasmaVault.sol
contract PlasmaVaultTest is OlympixUnitTest("PlasmaVault") {
    PlasmaVault public plasmaVault;


    function setUp() public override {
        plasmaVault = new PlasmaVault();
    }

    function test_deployment_doesNotRevert() public view {
        assertTrue(address(plasmaVault) != address(0), "Contract should be deployed");
    }

    function test_maxDeposit_WhenTotalSupplyAtOrAboveCap_ReturnsZero() public view {
            // When totalSupply >= totalSupplyCap, maxDeposit should return 0
            uint256 result = plasmaVault.maxDeposit(address(this));
            assertEq(result, 0, "maxDeposit should be zero when cap reached or exceeded");
        }
}