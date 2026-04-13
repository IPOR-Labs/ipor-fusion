// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/managers/fee/FeeManager.sol

import {FeeManager} from "contracts/managers/fee/FeeManager.sol";
import {FeeManagerInitData} from "contracts/managers/fee/FeeManager.sol";
import {RecipientFee} from "contracts/managers/fee/FeeManagerFactory.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {AccessManagedUpgradeable} from "contracts/managers/access/AccessManagedUpgradeable.sol";
contract FeeManagerTest is OlympixUnitTest("FeeManager") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_harvestManagementFee_NotInitialized_Reverts() public {
            // Deploy FeeManager with dummy data but DO NOT call initialize so _getInitializedVersion() != INITIALIZED_VERSION
            RecipientFee[] memory emptyRecipients;
            FeeManagerInitData memory initData = FeeManagerInitData({
                initialAuthority: address(0x1),
                plasmaVault: address(0x2),
                iporDaoManagementFee: 0,
                iporDaoPerformanceFee: 0,
                iporDaoFeeRecipientAddress: address(0x3),
                recipientManagementFees: emptyRecipients,
                recipientPerformanceFees: emptyRecipients
            });
    
            FeeManager feeManager = new FeeManager(initData);
    
            // Call harvestManagementFee before initialize so the onlyInitialized-style check fails
            vm.expectRevert(FeeManager.NotInitialized.selector);
            feeManager.harvestManagementFee();
        }
}