// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {IporFusionAccessManager} from "../../../../contracts/managers/access/IporFusionAccessManager.sol";

import {InitializationData} from "contracts/managers/access/IporFusionAccessManagerInitializationLib.sol";
import {Roles} from "contracts/libraries/Roles.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {RedemptionDelayLib} from "contracts/managers/access/RedemptionDelayLib.sol";
contract IporFusionAccessManagerTest is OlympixUnitTest("IporFusionAccessManager") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_initialize_roleToFunctionsEmpty_hitsElseBranch() public {
            IporFusionAccessManager manager = new IporFusionAccessManager(address(this), 1 days);
    
            InitializationData memory data;
            // leave roleToFunctions, adminRoles and accountToRoles as their default empty arrays
    
            manager.initialize(data);
    
            assertEq(manager.REDEMPTION_DELAY_IN_SECONDS(), 1 days);
        }

    function test_initialize_AdminRolesEmpty_HitsElseBranch() public {
            // Deploy with some admin so initialize can be called
            IporFusionAccessManager manager = new IporFusionAccessManager(address(this), 1 days);
    
            // Prepare InitializationData with adminRoles length == 0 to hit the else branch at line 153
            InitializationData memory initData;
    
            // roleToFunctions empty => length 0
            // adminRoles empty => length 0 (targets opix-target-branch-153-else)
            // accountToRoles empty => length 0
    
            // Call initialize as ADMIN (this contract is admin via constructor)
            manager.initialize(initData);
    
            // Basic sanity: contract should keep the configured redemption delay
            assertEq(manager.REDEMPTION_DELAY_IN_SECONDS(), 1 days);
        }

    function test_enableTransferShares_restrictedBranchTrue() public {
            // Deploy manager with this contract as initial admin
            IporFusionAccessManager manager = new IporFusionAccessManager(address(this), 1 days);
    
            // Grant some arbitrary role to this contract so that it can be used as TECH_PLASMA_VAULT_ROLE
            // We use roleId = 1 and set its admin to ADMIN_ROLE so current admin (this) can grant it
            uint64 techRoleId = 1;
            manager.setRoleAdmin(techRoleId, manager.ADMIN_ROLE());
    
            // Set that role as the required role for enableTransferShares on the manager itself
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = IporFusionAccessManager.enableTransferShares.selector;
            manager.setTargetFunctionRole(address(manager), selectors, techRoleId);
    
            // Grant the TECH_PLASMA_VAULT_ROLE (roleId = 1) to this contract with zero execution delay
            manager.grantRole(techRoleId, address(this), 0);
    
            // Call enableTransferShares as an authorized caller to enter the `if (true)` branch
            manager.enableTransferShares(address(0x1234));
        }

    function test_getAccountLockTime_hitsTrueBranch() public {
            IporFusionAccessManager manager = new IporFusionAccessManager(address(this), 1 days);
    
            // choose arbitrary account
            address account = address(0x1234);
    
            // we don't need to manipulate internal RedemptionDelayLib storage for branch coverage
            // just ensure the function executes and returns the library value (which will be 0 by default)
            uint256 lockTime = manager.getAccountLockTime(account);
    
            // default lock time should be zero for an untouched account
            assertEq(lockTime, RedemptionDelayLib.getAccountLockTime(account));
        }

    function test_checkCanCall_notImmediate_zeroDelay_revertsAccessManagedUnauthorized() public {
            // Deploy manager with this test contract as initial admin
            IporFusionAccessManager manager = new IporFusionAccessManager(address(this), 1 days);
    
            // Prepare calldata for a function that is NOT restricted by admin logic in AccessManager
            // We choose getMinimalExecutionDelayForRole(uint64 roleId_) which is external and unrestricted
            bytes4 selector = IporFusionAccessManager.getMinimalExecutionDelayForRole.selector;
            uint64 roleId = 1;
            bytes memory data = abi.encodeWithSelector(selector, roleId);
    
            // Prank from an address that has no role in the manager
            address unauthorized = address(0xBEEF);
            vm.startPrank(unauthorized);
    
            // Expect the custom error AccessManagedUnauthorized(address caller)
            vm.expectRevert(
                abi.encodeWithSelector(IporFusionAccessManager.AccessManagedUnauthorized.selector, unauthorized)
            );
    
            // Directly call the internal guard via the public function that uses it in a restricted modifier
            // We do this by calling canCallAndUpdate, which invokes _checkCanCall internally
            manager.canCallAndUpdate(unauthorized, address(manager), selector);
    
            vm.stopPrank();
        }
}