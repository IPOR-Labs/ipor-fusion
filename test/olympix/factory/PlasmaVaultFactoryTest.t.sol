// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../test/OlympixUnitTest.sol";
import {PlasmaVaultFactory} from "../../../contracts/factory/PlasmaVaultFactory.sol";

import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
contract PlasmaVaultFactoryTest is OlympixUnitTest("PlasmaVaultFactory") {
    PlasmaVaultFactory public plasmaVaultFactory;


    function setUp() public override {
        plasmaVaultFactory = new PlasmaVaultFactory();
    }

    function test_deployment_doesNotRevert() public view {
        assertTrue(address(plasmaVaultFactory) != address(0), "Contract should be deployed");
    }

    function test_clone_RevertOnZeroBaseAddress() public {
            PlasmaVaultInitData memory initData;
            vm.expectRevert(PlasmaVaultFactory.InvalidBaseAddress.selector);
            plasmaVaultFactory.clone(address(0), 0, initData);
        }
}