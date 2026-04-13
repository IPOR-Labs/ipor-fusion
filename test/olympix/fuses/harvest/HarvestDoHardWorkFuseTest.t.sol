// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

import {HarvestDoHardWorkFuse} from "contracts/fuses/harvest/HarvestDoHardWorkFuse.sol";

/// @dev Target contract: contracts/fuses/harvest/HarvestDoHardWorkFuse.sol

import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {IHarvestVault} from "contracts/fuses/harvest/ext/IHarvestVault.sol";
import {IHarvestController} from "contracts/fuses/harvest/ext/IHarvestController.sol";
import {HarvestDoHardWorkFuseEnterData} from "contracts/fuses/harvest/HarvestDoHardWorkFuse.sol";
contract HarvestDoHardWorkFuseTest is OlympixUnitTest("HarvestDoHardWorkFuse") {
    HarvestDoHardWorkFuse public harvestDoHardWorkFuse;


    function setUp() public override {
        harvestDoHardWorkFuse = new HarvestDoHardWorkFuse(1);
    }

    function test_deployment_doesNotRevert() public view {
        assertTrue(address(harvestDoHardWorkFuse) != address(0), "Contract should be deployed");
    }

    function test_enter_revertsWhenVaultNotGrantedAsSubstrate() public {
            // prepare a vault address that is not granted as substrate
            address mockVault = address(0x1001);
    
            address[] memory vaults = new address[](1);
            vaults[0] = mockVault;
    
            HarvestDoHardWorkFuseEnterData memory enterData = HarvestDoHardWorkFuseEnterData({vaults: vaults});
    
            // PlasmaVaultConfigLib.isSubstrateAsAssetGranted will return false in this bare context,
            // so the first `if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(...))` condition
            // evaluates to true and the function must revert with UnsupportedVault, thus
            // hitting the opix-target-branch-91-True branch.
            vm.expectRevert(abi.encodeWithSelector(HarvestDoHardWorkFuse.UnsupportedVault.selector, mockVault));
    
            harvestDoHardWorkFuse.enter(enterData);
        }
}