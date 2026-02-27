// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../../test/OlympixUnitTest.sol";
import {ValidateAllAssetsPricesPreHook} from "../../../../../contracts/handlers/pre_hooks/pre_hooks/ValidateAllAssetsPricesPreHook.sol";

import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {ValidateAllAssetsPricesPreHook} from "contracts/handlers/pre_hooks/pre_hooks/ValidateAllAssetsPricesPreHook.sol";
contract ValidateAllAssetsPricesPreHookTest is OlympixUnitTest("ValidateAllAssetsPricesPreHook") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_run_revertsWhenPriceOracleMiddlewareManagerNotConfigured() public {
        // PlasmaVaultMock constructor in repo expects two arguments; pass zero addresses
        PlasmaVaultMock vault = new PlasmaVaultMock(address(0), address(0));
    
        ValidateAllAssetsPricesPreHook hook = new ValidateAllAssetsPricesPreHook();
    
        // Execute hook in the context of the vault so PlasmaVaultLib reads its storage
        vm.startPrank(address(vault));
        vm.expectRevert(ValidateAllAssetsPricesPreHook.PriceOracleMiddlewareManagerNotConfigured.selector);
        hook.run(bytes4(0));
        vm.stopPrank();
    }
}